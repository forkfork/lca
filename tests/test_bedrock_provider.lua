#!/usr/bin/env lua

local script_dir = arg[0]:match("^(.*)/[^/]+$") or "."
local project_dir = script_dir .. "/.."
package.path = project_dir .. "/lua/?.lua;" .. project_dir .. "/lua/?/init.lua;" .. project_dir .. "/lua/?/?.lua;" .. package.path
pcall(require, "luarocks.loader")

local json = require("agent.util.json")
local providers = require("agent.providers")
local bedrock = require("agent.providers.bedrock")

local passed, failed = 0, 0
local function test(name, fn)
	io.write("  " .. name .. " ")
	local ok, err = pcall(fn)
	if ok then
		passed = passed + 1
		io.write("\27[32mPASS\27[0m\n")
	else
		failed = failed + 1
		io.write("\27[31mFAIL\27[0m (" .. tostring(err):sub(1, 180) .. ")\n")
	end
end
local function assert_eq(actual, expected)
	if actual ~= expected then error("expected " .. tostring(expected) .. ", got " .. tostring(actual)) end
end
local function temp_file(content)
	local path = os.tmpname()
	local file = assert(io.open(path, "w"))
	assert(file:write(content))
	assert(file:close())
	return path
end

io.write("\n\27[2m═══ Bedrock Provider Tests ═══\27[0m\n\n")

test("Bedrock is selected only when explicitly active", function()
	local path = temp_file([[{
		"provider": "bedrock",
		"providers": {
			"codex": { "access": "openai-token", "accountId": "acct" },
			"bedrock": { "apiKey": "bedrock-key", "region": "ap-southeast-2" }
		}
	}]])
	providers._invalidate_cache()
	local _, name = providers.load(path)
	assert_eq(name, "bedrock")
	local credentials = json.decode(providers.credentials_body(path))
	assert_eq(credentials.apiKey, "bedrock-key")
	assert_eq(credentials.provider, "bedrock")
	os.remove(path)
end)

test("Bedrock request uses its Sol default and local native tools", function()
	local body
	local path = temp_file([[{
		"provider": "bedrock",
		"providers": { "bedrock": { "apiKey": "bedrock-key", "region": "us-east-1" } }
	}]])
	providers._invalidate_cache()
	bedrock._set_http_request(function(options)
		body = options.body
		options.on_body_chunk('data: {"type":"response.output_text.delta","delta":"hello"}\n')
		options.on_body_chunk('data: {"type":"response.output_item.done","item":{"type":"message","id":"msg_1","content":[]}}\n')
		options.on_body_chunk('data: {"type":"response.completed","response":{"usage":{"input_tokens":12,"output_tokens":1,"total_tokens":13}}}\n')
		return {
			status = 200,
			body_tail = "",
			response_bytes = 10,
			timings = {},
		}
	end)
	local streamed = {}
	local result = bedrock.complete({
		credentials_path = path,
		system_prompt = "system",
		messages = { { role = "user", text = "hi" } },
		native_tool_calling = true,
		tool_scope = "local_only",
		max_retries = 0,
	}, function(delta) streamed[#streamed + 1] = delta end)
	local decoded = json.decode(body)
	assert_eq(decoded.model, "global.openai.gpt-5.6-sol")
	assert(type(decoded.tools) == "table" and #decoded.tools > 0, "local tools missing")
	assert_eq(result.text, "hello")
	assert_eq(table.concat(streamed), "hello")
	assert_eq(result._usage.prompt_tokens, 12)
	bedrock._set_http_request(nil)
	os.remove(path)
end)

test("Bedrock rejects explicit or configured Astra before transport", function()
	local path = temp_file([[{"provider":"bedrock","providers":{"bedrock":{"apiKey":"test"}}}]])
	providers._invalidate_cache()
	local calls = 0
	bedrock._set_http_request(function() calls = calls + 1; error("unexpected transport") end)
	local ok, err = pcall(bedrock.complete, {
		credentials_path = path, model = "gpt-6-astra", messages = {}, max_retries = 0,
	})
	bedrock._set_http_request(nil)
	os.remove(path)
	assert_eq(ok, false)
	assert_eq(calls, 0)
	assert(tostring(err):find("Astra is not supported by Bedrock", 1, true), tostring(err))
	for _, model in ipairs({ "gpt-6-astra", "global.openai.gpt-6-astra" }) do
		ok, err = pcall(bedrock._request_body, { messages = {}, tool_scope = "none" }, { model = model })
		assert_eq(ok, false)
		assert(tostring(err):find("Astra is not supported by Bedrock", 1, true), tostring(err))
	end
	local body = json.decode(bedrock._request_body({ model = "gpt-5.6-sol", messages = {}, tool_scope = "none" }, { model = "other-configured-model" }))
	assert_eq(body.model, "global.openai.gpt-5.6-sol")
end)

test("Bedrock rejects server-side web-only mode before transport", function()
	local path = temp_file([[{
		"provider": "bedrock",
		"providers": { "bedrock": { "apiKey": "bedrock-key" } }
	}]])
	providers._invalidate_cache()
	local ok, err = pcall(bedrock.complete, {
		credentials_path = path,
		messages = {},
		tool_scope = "web_only",
		max_retries = 0,
	})
	assert_eq(ok, false)
	assert(tostring(err):find("server-side web search", 1, true), tostring(err))
	os.remove(path)
end)

test("Bedrock signs temporary AWS credentials without an SDK", function()
	local shell = require("agent.util.shell")
	local old_capture = shell.capture
	shell.capture = function() error("signing must not launch a subprocess") end
	local ok, headers, signing = pcall(bedrock._signed_headers,
		"bedrock-runtime.us-east-1.amazonaws.com",
		"/openai/v1/responses",
		'{"model":"global.openai.gpt-5.6-sol"}',
		{
			access_key = "AKIDEXAMPLE",
			secret_key = "secret",
			session_token = "session",
			region = "us-east-1",
		},
		"20260908T120000Z"
	)
	shell.capture = old_capture
	assert(ok, headers)
	local by_name = {}
	for _, header in ipairs(headers) do by_name[header[1]] = header[2] end
	assert(by_name.Authorization:find("AWS4%-HMAC%-SHA256 Credential=AKIDEXAMPLE/20260908/us%-east%-1/bedrock/aws4_request"))
	assert(by_name.Authorization:find("x%-amz%-security%-token"))
	assert_eq(by_name["X-Amz-Date"], "20260908T120000Z")
	assert_eq(by_name["X-Amz-Security-Token"], "session")
	assert_eq(signing.canonical_hash, "ee56e3977e889434eb7a0badc966c827c85632661efca131f4d8eff320b4b717")
	assert_eq(signing.signature, "8b82248e2e6db9650fc0520157601fbbbac183970e582bc911f09c6dbaea3b9d")
end)

test("Bedrock falls back through AWS credentials to configured Isengard", function()
	local path = temp_file([[{
		"provider": "bedrock",
		"providers": {
			"bedrock": {
				"isengardAccount": "example-account",
				"isengardRole": "admin",
				"region": "us-east-1"
			}
		}
	}]])
	providers._invalidate_cache()
	bedrock._set_getenv(function() return nil end)
	local commands = {}
	bedrock._set_command_capture(function(command)
		commands[#commands + 1] = command
		if command:find("^aws configure", 1) then error("no default AWS credentials") end
		return [[
{"Version":1,"AccessKeyId":"ASIAEXAMPLE","SecretAccessKey":"secret","SessionToken":"session","Expiration":"2099-01-01T00:00:00+00:00"}
Type "exit" to unassume
]]
	end)
	local credentials = bedrock._load_credentials(path)
	assert_eq(credentials.access_key, "ASIAEXAMPLE")
	assert_eq(#commands, 2)
	assert(commands[2]:find("isengardcli assume", 1, true), commands[2])
	assert(commands[2]:find("example-account", 1, true), commands[2])
	providers._invalidate_cache()
	local saved = json.decode(assert(io.open(path, "r")):read("*a"))
	assert_eq(saved.providers.bedrock.accessKeyId, "ASIAEXAMPLE")
	assert_eq(saved.providers.bedrock.isengardAccount, "example-account")
	bedrock._set_command_capture(nil)
	bedrock._set_getenv(nil)
	os.remove(path)
end)

bedrock._set_http_request(nil)
bedrock._set_command_capture(nil)
bedrock._set_getenv(nil)
providers._invalidate_cache()

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
