#!/usr/bin/env lua

local script_dir = arg[0]:match("^(.*)/[^/]+$") or "."
local project_dir = script_dir .. "/.."
package.path = project_dir .. "/lua/?.lua;" .. project_dir .. "/lua/?/init.lua;" .. project_dir .. "/lua/?/?.lua;" .. package.path
pcall(require, "luarocks.loader")

local json = require("agent.util.json")
local providers = require("agent.providers")
local codex = require("agent.providers.codex")

local passed = 0
local failed = 0

local function green(s) return "\27[32m" .. s .. "\27[0m" end
local function red(s) return "\27[31m" .. s .. "\27[0m" end
local function dim(s) return "\27[2m" .. s .. "\27[0m" end

local function test(name, fn)
	io.write("  " .. name .. " ")
	io.flush()
	local ok, err = pcall(fn)
	if ok then
		passed = passed + 1
		io.write(green("PASS") .. "\n")
	else
		failed = failed + 1
		io.write(red("FAIL") .. " (" .. tostring(err):sub(1, 120) .. ")\n")
	end
end

local function assert_eq(actual, expected, msg)
	if actual ~= expected then
		error((msg or "") .. " expected: " .. tostring(expected) .. ", got: " .. tostring(actual))
	end
end

local function temp_file(content)
	local path = os.tmpname()
	local file = assert(io.open(path, "w"))
	file:write(content)
	file:close()
	return path
end

io.write("\n" .. dim("═══ Provider Credential Tests ═══") .. "\n\n")

test("nested credentials always select Codex even when an old provider is marked active", function()
	local path = temp_file([[{
		"provider": "deepseek",
		"providers": {
			"codex": { "provider": "codex", "access": "openai-token", "accountId": "acct" },
			"deepseek": { "apiKey": "deepseek-key", "model": "deepseek-v4-flash" }
		}
	}]])
	providers._invalidate_cache()
	local body = providers.credentials_body(path)
	local tbl = json.decode(body)
	assert_eq(tbl.provider, "codex")
	assert_eq(tbl.access, "openai-token")
	local _, name = providers.load(path)
	assert_eq(name, "codex")
	os.remove(path)
end)

test("credentials without Codex OAuth data are rejected", function()
	local path = temp_file([[{
		"provider": "deepseek",
		"providers": { "deepseek": { "apiKey": "retired" } }
	}]])
	providers._invalidate_cache()
	local ok, err = pcall(providers.credentials_body, path)
	assert_eq(ok, false)
	if not tostring(err):find("no Codex OAuth credentials", 1, true) then error(err) end
	os.remove(path)
end)

test("openai alias selects codex provider", function()
	local path = temp_file([[{
		"provider": "openai",
		"providers": {
			"codex": { "access": "openai-token", "accountId": "acct" }
		}
	}]])
	providers._invalidate_cache()
	local body = providers.credentials_body(path)
	local tbl = json.decode(body)
	assert_eq(tbl.provider, "codex")
	assert_eq(tbl.access, "openai-token")
	local _, name = providers.load(path)
	assert_eq(name, "codex")
	os.remove(path)
end)

test("expired Codex credentials refresh proactively and persist atomically", function()
	local path = temp_file([[{
		"provider": "codex",
		"providers": {
			"codex": {
				"access": "expired-access",
				"refresh": "refresh-one",
				"expires": 0,
				"accountId": "acct"
			}
		}
	}]])
	local refresh_calls = 0
	providers._set_refresh_handler(function(refresh_token)
		refresh_calls = refresh_calls + 1
		assert_eq(refresh_token, "refresh-one")
		return {
			access = "fresh-access",
			refresh = "refresh-two",
			expires_in = 3600,
		}
	end)
	providers._invalidate_cache()

	local body = json.decode(providers.credentials_body(path))
	assert_eq(body.access, "fresh-access")
	assert_eq(body.refresh, "refresh-two")
	assert_eq(refresh_calls, 1)

	local saved_file = assert(io.open(path, "r"))
	local saved = json.decode(saved_file:read("*a"))
	saved_file:close()
	assert_eq(saved.providers.codex.access, "fresh-access")
	assert_eq(saved.providers.codex.refresh, "refresh-two")
	assert(saved.providers.codex.expires > os.time() * 1000, "refreshed expiry was not persisted")
	local stat = assert(require("luv").fs_stat(path))
	assert_eq(stat.mode & tonumber("777", 8), tonumber("600", 8), "credentials mode")

	providers._set_refresh_handler(nil)
	providers._invalidate_cache()
	os.remove(path)
end)

test("401 recovery refreshes only the access token that actually failed", function()
	local future = (os.time() + 3600) * 1000
	local path = temp_file(string.format([[{
		"provider": "codex",
		"providers": {
			"codex": {
				"access": "failed-access",
				"refresh": "refresh-one",
				"expires": %d,
				"accountId": "acct"
			}
		}
	}]], future))
	local refresh_calls = 0
	providers._set_refresh_handler(function(refresh_token)
		refresh_calls = refresh_calls + 1
		assert_eq(refresh_token, "refresh-one")
		return {
			access = "recovered-access",
			refresh = "refresh-two",
			expires_in = 3600,
		}
	end)
	providers._invalidate_cache()

	local refreshed = json.decode(providers.refresh_credentials(path, "failed-access"))
	assert_eq(refreshed.access, "recovered-access")
	assert_eq(refresh_calls, 1)
	local already_rotated = json.decode(providers.refresh_credentials(path, "failed-access"))
	assert_eq(already_rotated.access, "recovered-access")
	assert_eq(refresh_calls, 1, "stale 401 triggered a second refresh")

	providers._set_refresh_handler(nil)
	providers._invalidate_cache()
	os.remove(path)
end)

test("Codex retries a 401 immediately with the rotated access token", function()
	local future = (os.time() + 3600) * 1000
	local path = temp_file(string.format([[{
		"provider": "codex",
		"providers": {
			"codex": {
				"access": "failed-access",
				"refresh": "refresh-one",
				"expires": %d,
				"accountId": "acct"
			}
		}
	}]], future))
	providers._set_refresh_handler(function()
		return { access = "recovered-access", refresh = "refresh-two", expires_in = 3600 }
	end)
	providers._invalidate_cache()
	local request_calls = 0
	codex._set_websocket_enabled(false)
	codex._set_http_request(function(options)
		request_calls = request_calls + 1
		local authorization
		for _, header in ipairs(options.headers or {}) do
			if header[1] == "Authorization" then authorization = header[2] end
		end
		if request_calls == 1 then
			assert_eq(authorization, "Bearer failed-access")
			return {
				status = 401,
				body_tail = '{"error":{"code":"token_expired"}}',
				response_bytes = 0,
				timings = {},
			}
		end
		assert_eq(authorization, "Bearer recovered-access")
		return { status = 200, body_tail = "", response_bytes = 0, timings = {} }
	end)

	local result = codex.complete({
		credentials_path = path,
		native_tool_calling = true,
		max_retries = 1,
		messages = { { role = "user", text = "hello" } },
	})
	assert_eq(result._http_status, 200)
	assert_eq(request_calls, 2)

	codex._set_http_request(nil)
	codex._set_websocket_enabled(true)
	providers._set_refresh_handler(nil)
	providers._invalidate_cache()
	os.remove(path)
end)

io.write("\n" .. dim("─────────────────────────────────────") .. "\n")
io.write(string.format("  %s passed, %s failed\n",
	green(tostring(passed)), failed > 0 and red(tostring(failed)) or tostring(failed)))
io.write("\n")
os.exit(failed > 0 and 1 or 0)
