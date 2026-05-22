#!/usr/bin/env lua
--
-- Unit tests for tool_protocol.lua — specifically the parser's handling
-- of </tool_call> literals inside raw content.
--

local script_dir = arg[0]:match("^(.*)/[^/]+$") or "."
local project_dir = script_dir .. "/.."
package.path = project_dir .. "/lua/?.lua;" .. project_dir .. "/lua/?/init.lua;" .. project_dir .. "/lua/?/?.lua;" .. package.path
pcall(require, "luarocks.loader")

local protocol = require("agent.tool_protocol")

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
		io.write(red("FAIL") .. " (" .. tostring(err):sub(1, 100) .. ")\n")
	end
end

local function assert_eq(actual, expected, msg)
	if actual ~= expected then
		error((msg or "") .. " expected: " .. tostring(expected) .. ", got: " .. tostring(actual))
	end
end

io.write("\n" .. dim("═══ Tool Protocol Parser Tests ═══") .. "\n\n")

-- Test: basic raw content extraction
test("basic write with raw content", function()
	local text = '<tool_call name="write">\n{"path":"test.lua"}\nlocal x = 1\n</tool_call>'
	local calls = protocol.extract_all_tool_calls(text)
	assert_eq(#calls, 1)
	assert_eq(calls[1].name, "write")
	assert_eq(calls[1].args.path, "test.lua")
	assert_eq(calls[1].args._raw_content, "local x = 1")
end)

-- Test: raw content with ONE </tool_call> literal
test("raw content with one </tool_call> literal", function()
	local text = '<tool_call name="write">\n{"path":"test.lua"}\nlocal close = text:find("</tool_call>")\n</tool_call>'
	local calls = protocol.extract_all_tool_calls(text)
	assert_eq(#calls, 1)
	assert_eq(calls[1].name, "write")
	assert(calls[1].args._raw_content:find('find'), "should contain find")
	assert(calls[1].args._raw_content:find('tool_call'), "should contain tool_call literal")
end)

-- Test: raw content with TWO </tool_call> literals (the bug that broke repl.lua editing)
test("raw content with two </tool_call> literals", function()
	local content = 'local a = text:find("</tool_call>")\nlocal b = text:find("</tool_call>", a + 1)'
	local text = '<tool_call name="write">\n{"path":"test.lua"}\n' .. content .. '\n</tool_call>'
	local calls = protocol.extract_all_tool_calls(text)
	assert_eq(#calls, 1)
	assert_eq(calls[1].name, "write")
	assert(calls[1].args._raw_content:find("a + 1", 1, true), "should contain full content including second occurrence")
end)

-- Test: raw content with THREE </tool_call> literals
test("raw content with three </tool_call> literals", function()
	local content = table.concat({
		'local TAG = "</tool_call>"',
		'local pos1 = text:find("</tool_call>")',
		'local pos2 = text:find("</tool_call>", pos1 + 1)',
	}, "\n")
	local text = '<tool_call name="write">\n{"path":"test.lua"}\n' .. content .. '\n</tool_call>'
	local calls = protocol.extract_all_tool_calls(text)
	assert_eq(#calls, 1)
	assert(calls[1].args._raw_content:find("pos1 + 1", 1, true), "should preserve all content")
end)

-- Test: multiple tool calls where first has </tool_call> in content
test("two tool calls, first contains </tool_call> literal", function()
	local text = '<tool_call name="write">\n{"path":"a.lua"}\nlocal x = s:find("</tool_call>")\n</tool_call>\n<tool_call name="read">\n{"path":"b.lua"}\n</tool_call>'
	local calls = protocol.extract_all_tool_calls(text)
	assert_eq(#calls, 2)
	assert_eq(calls[1].name, "write")
	assert_eq(calls[2].name, "read")
	assert(calls[1].args._raw_content:find("tool_call"), "first call should have content with literal")
end)

-- Test: strip_tool_calls with </tool_call> in content
test("strip_tool_calls preserves text around calls with literals", function()
	local text = 'Before\n<tool_call name="write">\n{"path":"a.lua"}\nlocal x = s:find("</tool_call>")\n</tool_call>\nAfter'
	local stripped = protocol.strip_tool_calls(text)
	assert(stripped:find("Before"), "should keep Before")
	assert(stripped:find("After"), "should keep After")
	assert(not stripped:find("tool_call"), "should strip the tool call")
end)

io.write("\n" .. dim("─────────────────────────────────────") .. "\n")
io.write(string.format("  %s passed, %s failed\n",
	green(tostring(passed)), failed > 0 and red(tostring(failed)) or tostring(failed)))
io.write("\n")
os.exit(failed > 0 and 1 or 0)
