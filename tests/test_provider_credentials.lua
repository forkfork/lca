#!/usr/bin/env lua

local script_dir = arg[0]:match("^(.*)/[^/]+$") or "."
local project_dir = script_dir .. "/.."
package.path = project_dir .. "/lua/?.lua;" .. project_dir .. "/lua/?/init.lua;" .. project_dir .. "/lua/?/?.lua;" .. package.path
pcall(require, "luarocks.loader")

local json = require("agent.util.json")
local providers = require("agent.providers")

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

test("nested credentials select active provider body", function()
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
	assert_eq(tbl.provider, "deepseek")
	assert_eq(tbl.apiKey, "deepseek-key")
	assert_eq(tbl.model, "deepseek-v4-flash")
	local _, name = providers.load(path)
	assert_eq(name, "deepseek")
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

io.write("\n" .. dim("─────────────────────────────────────") .. "\n")
io.write(string.format("  %s passed, %s failed\n",
	green(tostring(passed)), failed > 0 and red(tostring(failed)) or tostring(failed)))
io.write("\n")
os.exit(failed > 0 and 1 or 0)
