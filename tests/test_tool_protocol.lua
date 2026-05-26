#!/usr/bin/env lua
--
-- Unit tests for tool_protocol.lua.
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

local function assert_invalid(calls, expected)
	local ok, err = protocol.validate_tool_calls(calls)
	if ok then
		error("expected invalid tool calls")
	end
	if expected and not tostring(err):find(expected, 1, true) then
		error("expected error containing: " .. expected .. ", got: " .. tostring(err))
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

test("read tool result records requested range", function()
	local message = protocol.tool_result_message("read", {
		is_error = false,
		content = "1:abcd: hello",
	}, {
		path = "app.lua",
		offset = 10,
		limit = 20,
	})
	assert(message:find('path="app.lua"', 1, true), "missing path attr")
	assert(message:find('offset="10"', 1, true), "missing offset attr")
	assert(message:find('limit="20"', 1, true), "missing limit attr")
end)

test("rejects raw content with </tool_call> literal", function()
	local text = '<tool_call name="write">\n{"path":"test.lua"}\nlocal close = text:find("</tool_call>")\n</tool_call>'
	local calls = protocol.extract_all_tool_calls(text)
	assert_eq(#calls, 1)
	assert_invalid(calls, "literal <tool_call> markup")
end)

test("rejects raw content with two </tool_call> literals", function()
	local content = 'local a = text:find("</tool_call>")\nlocal b = text:find("</tool_call>", a + 1)'
	local text = '<tool_call name="write">\n{"path":"test.lua"}\n' .. content .. '\n</tool_call>'
	local calls = protocol.extract_all_tool_calls(text)
	assert_eq(#calls, 1)
	assert_invalid(calls, "literal <tool_call> markup")
end)

test("rejects raw content with three </tool_call> literals", function()
	local content = table.concat({
		'local TAG = "</tool_call>"',
		'local pos1 = text:find("</tool_call>")',
		'local pos2 = text:find("</tool_call>", pos1 + 1)',
	}, "\n")
	local text = '<tool_call name="write">\n{"path":"test.lua"}\n' .. content .. '\n</tool_call>'
	local calls = protocol.extract_all_tool_calls(text)
	assert_eq(#calls, 1)
	assert_invalid(calls, "literal <tool_call> markup")
end)

test("rejects batch when raw content contains </tool_call> literal", function()
	local text = '<tool_call name="write">\n{"path":"a.lua"}\nlocal x = s:find("</tool_call>")\n</tool_call>\n<tool_call name="read">\n{"path":"b.lua"}\n</tool_call>'
	local calls = protocol.extract_all_tool_calls(text)
	assert_eq(#calls, 2)
	assert_eq(calls[1].name, "write")
	assert_eq(calls[2].name, "read")
	assert_invalid(calls, "literal <tool_call> markup")
end)

test("embedded tool examples inside edit body are one invalid call", function()
	local content = table.concat({
		'local base = [[',
		'<tool_call name="ls">',
		'{"path":"."}',
		'</tool_call>',
		'<tool_call name="run">',
		'{"command":"lua /tmp/hello.lua"}',
		'</tool_call>',
		']]',
	}, "\n")
	local text = '<tool_call name="edit">\n{"path":"tool_registry.lua","start_line":1,"end_line":2}\n' .. content .. '\n</tool_call>'
	local calls = protocol.extract_all_tool_calls(text)
	assert_eq(#calls, 1)
	assert_eq(calls[1].name, "edit")
	assert_invalid(calls, "literal <tool_call> markup")
end)

test("non-raw tools ignore text after JSON", function()
	local text = '<tool_call name="run">\n{"command":"true"}\nextra text\n</tool_call>'
	local calls = protocol.extract_all_tool_calls(text)
	assert_eq(#calls, 1)
	local ok, err = protocol.validate_tool_calls(calls)
	if not ok then
		error("non-raw tools should ignore content after JSON: " .. tostring(err))
	end
	assert_eq(calls[1].args._raw_content, nil)
end)

test("extra close tag after non-raw tool does not create raw content", function()
	local text = table.concat({
		'<tool_call name="read">',
		'{"path":"lua/agent/core.lua"}',
		'</tool_call>',
		'</tool_call>I will inspect this before answering.',
	}, "\n")
	local calls = protocol.extract_all_tool_calls(text)
	assert_eq(#calls, 1)
	assert_eq(calls[1].name, "read")
	assert_eq(calls[1].args._raw_content, nil)
	local ok, err = protocol.validate_tool_calls(calls)
	if not ok then
		error("expected valid read call, got: " .. tostring(err))
	end
end)

test("extra close tags after raw edit are ignored", function()
	local text = table.concat({
		'<tool_call name="edit">',
		'{"path":"fake_tmux.py","start_line":1,"start_tag":"aaaa","end_line":2,"end_tag":"bbbb"}',
		'line one',
		'line two',
		'</tool_call>',
		'</tool_call>',
		'',
	}, "\n")
	local calls = protocol.extract_all_tool_calls(text)
	assert_eq(#calls, 1)
	assert_eq(calls[1].name, "edit")
	assert_eq(calls[1].args._raw_content, "line one\nline two")
	local ok, err = protocol.validate_tool_calls(calls)
	if not ok then
		error("expected extra trailing close tag to be ignored, got: " .. tostring(err))
	end
end)

test("extra close tags and trailing prose after raw edit are ignored", function()
	local text = table.concat({
		'<tool_call name="edit">',
		'{"path":"fake_tmux.py","start_line":1,"start_tag":"aaaa","end_line":2,"end_tag":"bbbb"}',
		'line one',
		'line two',
		'</tool_call>',
		'</tool_call>',
		'Tool call failed before execution because the message contained malformed tool markup.',
	}, "\n")
	local calls = protocol.extract_all_tool_calls(text)
	assert_eq(#calls, 1)
	assert_eq(calls[1].name, "edit")
	assert_eq(calls[1].args._raw_content, "line one\nline two")
	local ok, err = protocol.validate_tool_calls(calls)
	if not ok then
		error("expected extra trailing close tag and prose to be ignored, got: " .. tostring(err))
	end
end)

test("malformed prose after raw write does not poison raw content", function()
	local text = table.concat({
		'<tool_call name="write">',
		'{"path":"log.sh"}',
		'#!/usr/bin/env bash',
		'echo ok',
		'</tool_call>',
		'</tool_call>... Wait accidental extra close? I included another <tool_call name="write"> marker in prose.',
	}, "\n")
	local calls = protocol.extract_all_tool_calls(text)
	assert_eq(#calls, 1)
	assert_eq(calls[1].name, "write")
	assert_eq(calls[1].args._raw_content, "#!/usr/bin/env bash\necho ok")
	local ok, err = protocol.validate_tool_calls(calls)
	if not ok then
		error("expected malformed trailing prose to be ignored, got: " .. tostring(err))
	end
end)

-- Test: strip_tool_calls with </tool_call> in content
test("strip_tool_calls preserves text around calls with literals", function()
	local text = 'Before\n<tool_call name="write">\n{"path":"a.lua"}\nlocal x = s:find("</tool_call>")\n</tool_call>\nAfter'
	local stripped = protocol.strip_tool_calls(text)
	assert(stripped:find("Before"), "should keep Before")
	assert(stripped:find("After"), "should keep After")
	assert(not stripped:find("tool_call"), "should strip the tool call")
end)

test("ignores tool call examples inside fenced code", function()
	local text = table.concat({
		"Example:",
		"```xml",
		'<tool_call name="read">',
		'{"path":"README.md"}',
		"</tool_call>",
		"```",
		"Done.",
	}, "\n")
	local calls = protocol.extract_all_tool_calls(text)
	assert_eq(#calls, 0)
	assert_eq(protocol.count_tool_calls(text), 0)
	local stripped = protocol.strip_tool_calls(text)
	assert(stripped:find('<tool_call name="read">', 1, true), "fenced example should remain visible")
end)

io.write("\n" .. dim("─────────────────────────────────────") .. "\n")
io.write(string.format("  %s passed, %s failed\n",
	green(tostring(passed)), failed > 0 and red(tostring(failed)) or tostring(failed)))
io.write("\n")
os.exit(failed > 0 and 1 or 0)
