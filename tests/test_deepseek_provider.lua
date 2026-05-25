#!/usr/bin/env lua

local script_dir = arg[0]:match("^(.*)/[^/]+$") or "."
local project_dir = script_dir .. "/.."
package.path = project_dir .. "/lua/?.lua;" .. project_dir .. "/lua/?/init.lua;" .. project_dir .. "/lua/?/?.lua;" .. package.path
pcall(require, "luarocks.loader")

local json = require("agent.util.json")
local deepseek = require("agent.providers.deepseek")

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

io.write("\n" .. dim("═══ DeepSeek Provider Tests ═══") .. "\n\n")

test("request body uses OpenAI-compatible chat completions shape", function()
	local body = deepseek._request_body({
		system_prompt = "system text",
		model = "deepseek-v4-flash",
		messages = {
			{ role = "user", text = "hello" },
			{ role = "assistant", text = "hi" },
		},
	}, {})
	local tbl = json.decode(body)
	assert_eq(tbl.model, "deepseek-v4-flash")
	assert_eq(tbl.stream, true)
	assert_eq(tbl.messages[1].role, "system")
	if not tbl.messages[1].content:find("^system text", 1, false) then
		error("system prompt should be preserved at the start")
	end
	if not tbl.messages[1].content:find("DeepSeek tool protocol reminder", 1, true) then
		error("missing DeepSeek tool reminder in system prompt")
	end
	assert_eq(tbl.messages[2].role, "user")
	assert_eq(tbl.messages[2].content, "hello")
	assert_eq(tbl.messages[3].role, "assistant")
	assert_eq(tbl.messages[3].content, "hi")
end)

test("request body maps LCA reasoning effort to DeepSeek thinking mode", function()
	local body = deepseek._request_body({
		reasoning_effort = "xhigh",
		messages = {},
	}, { model = "deepseek-v4-pro" })
	local tbl = json.decode(body)
	assert_eq(tbl.thinking.type, "enabled")
	assert_eq(tbl.reasoning_effort, "max")

	body = deepseek._request_body({
		reasoning_effort = "none",
		messages = {},
	}, { model = "deepseek-v4-pro" })
	tbl = json.decode(body)
	assert_eq(tbl.thinking.type, "disabled")
	assert_eq(tbl.reasoning_effort, nil)
end)

test("base url appends chat completions path", function()
	local host, path = deepseek._parse_base_url("https://api.deepseek.com")
	assert_eq(host, "api.deepseek.com")
	assert_eq(path, "/chat/completions")

	host, path = deepseek._parse_base_url("https://api.deepseek.com/beta")
	assert_eq(host, "api.deepseek.com")
	assert_eq(path, "/beta/chat/completions")
end)

test("SSE parser extracts content, reasoning, and usage", function()
	local content = {}
	local reasoning = {}
	local usage
	local parser = deepseek._sse_parser(function(delta)
		content[#content + 1] = delta
	end, function(delta)
		reasoning[#reasoning + 1] = delta
	end, function(next_usage)
		usage = next_usage
	end)
	parser('data: {"choices":[{"delta":{"reasoning_content":"think "}}]}\n')
	parser('data: {"choices":[{"delta":{"content":"hello"}}],"usage":{"prompt_tokens":10,"completion_tokens":3,"total_tokens":13,"prompt_tokens_details":{"cached_tokens":4}}}\n')
	parser("data: [DONE]\n")
	assert_eq(table.concat(reasoning), "think ")
	assert_eq(table.concat(content), "hello")
	assert_eq(usage.prompt_tokens, 10)
	assert_eq(usage.cached_tokens, 4)
	assert_eq(usage.output_tokens, 3)
	assert_eq(usage.total_tokens, 13)
end)

test("SSE parser ignores null delta fields", function()
	local content = {}
	local reasoning = {}
	local parser = deepseek._sse_parser(function(delta)
		content[#content + 1] = delta
	end, function(delta)
		reasoning[#reasoning + 1] = delta
	end)
	parser('data: {"choices":[{"delta":{"reasoning_content":null,"content":null}}]}\n')
	parser('data: {"choices":[{"delta":{"content":"ok"}}]}\n')
	assert_eq(table.concat(reasoning), "")
	assert_eq(table.concat(content), "ok")
end)

io.write("\n" .. dim("─────────────────────────────────────") .. "\n")
io.write(string.format("  %s passed, %s failed\n",
	green(tostring(passed)), failed > 0 and red(tostring(failed)) or tostring(failed)))
io.write("\n")
os.exit(failed > 0 and 1 or 0)
