#!/usr/bin/env lua
--
-- Deterministic write/edit integration tests.
--
-- These exercise core.run_session, tool-call parsing, write/edit execution,
-- and syntax validation without making live model calls.
--

local script_dir = arg[0]:match("^(.*)/[^/]+$") or "."
local project_dir = script_dir .. "/.."
package.path = project_dir .. "/lua/?.lua;" .. project_dir .. "/lua/?/init.lua;" .. project_dir .. "/lua/?/?.lua;" .. package.path
pcall(require, "luarocks.loader")

local active_responses = nil
local active_call = 0

package.loaded["agent.providers"] = {
	load = function()
		return {
			complete = function()
				active_call = active_call + 1
				if not active_responses then
					error("no fake responses configured")
				end
				return {
					text = active_responses[active_call] or "done",
				}
			end,
		}
	end,
}

local core = require("agent.core")
local session_module = require("agent.session")
local shell = require("agent.util.shell")

local tmp_dir = os.tmpname() .. "_lca_tool_write_tests"
os.execute("rm -rf " .. shell.quote(tmp_dir))
os.execute("mkdir -p " .. shell.quote(tmp_dir))

core.set_transcript("/tmp/lca_test.log")

local passed = 0
local failed = 0
local errors = {}

local function green(s) return "\27[32m" .. s .. "\27[0m" end
local function red(s) return "\27[31m" .. s .. "\27[0m" end
local function dim(s) return "\27[2m" .. s .. "\27[0m" end

local function tool_call(name, json_args, raw)
	local parts = {
		'<tool_call name="' .. name .. '">',
		json_args,
	}
	if raw then
		parts[#parts + 1] = raw
	end
	parts[#parts + 1] = "</tool_call>"
	return table.concat(parts, "\n")
end

local function write_call(path, content)
	return tool_call("write", '{"path":"' .. path .. '"}', content)
end

local function edit_call(path, old_text, new_text)
	return tool_call(
		"edit",
		'{"path":"' .. path .. '","oldText":' .. require("agent.util.json").string(old_text) .. ',"newText":' .. require("agent.util.json").string(new_text) .. "}"
	)
end

local function run_test(name, responses, checks)
	io.write(dim("  " .. name .. " "))
	io.flush()

	active_responses = responses
	active_call = 0

	local session = session_module.create({})
	session.cwd = tmp_dir
	session:add_user("trigger " .. name)

	local ok, result = pcall(function()
		return core.run_session(session, nil, nil, nil)
	end)

	if not ok then
		failed = failed + 1
		io.write(red("FAIL") .. " (" .. tostring(result):sub(1, 120) .. ")\n")
		errors[#errors + 1] = { name = name, err = tostring(result) }
		return
	end

	local check_ok, check_err = pcall(checks, result)
	if check_ok then
		passed = passed + 1
		io.write(green("PASS") .. "\n")
	else
		failed = failed + 1
		io.write(red("FAIL") .. " (" .. tostring(check_err):sub(1, 120) .. ")\n")
		errors[#errors + 1] = { name = name, err = tostring(check_err) }
	end
end

local function read_file(path)
	local full = tmp_dir .. "/" .. path
	local f = io.open(full, "r")
	if not f then error("file not found: " .. path) end
	local content = f:read("*a")
	f:close()
	return content
end

local function assert_file_exists(path)
	local f = io.open(tmp_dir .. "/" .. path, "r")
	if not f then error("file not created: " .. path) end
	f:close()
end

local function assert_contains(path, needle)
	local content = read_file(path)
	if not content:find(needle, 1, true) then
		error(path .. " does not contain: " .. needle)
	end
end

local function assert_not_exists(path)
	local f = io.open(tmp_dir .. "/" .. path, "r")
	if f then
		f:close()
		error("file should not exist: " .. path)
	end
end

local function assert_syntax_valid(path)
	local full = tmp_dir .. "/" .. path
	local ext = path:match("%.([^%.]+)$")
	local cmd
	if ext == "lua" then
		cmd = shell.quote(arg[-1] or "lua") .. " -e " .. shell.quote("assert(loadfile(arg[1]))")
	elseif ext == "py" then
		cmd = "python3 -m py_compile"
	elseif ext == "js" then
		cmd = "node --check"
	else
		return
	end
	local handle = io.popen(cmd .. " " .. shell.quote(full) .. " 2>&1", "r")
	local output = handle:read("*a")
	local _, _, code = handle:close()
	if code ~= 0 then
		error("syntax error in " .. path .. ": " .. output:sub(1, 200))
	end
end

io.write("\n" .. dim("═══ Tool Write Tests ═══") .. "\n\n")

run_test("write lua with nested quotes", {
	write_call("tricky_quotes.lua", [=[
local function generate_sql()
  local path_example = [[C:\Users\example\backups]]
  local digits = string.match("user123", "%d+")
  local query = string.format("%s", "SELECT * FROM \"users\" WHERE name = 'O\\'Brien'")
  return query, path_example, digits
end

return generate_sql
]=]),
	"done",
}, function()
	assert_file_exists("tricky_quotes.lua")
	assert_syntax_valid("tricky_quotes.lua")
	assert_contains("tricky_quotes.lua", "generate_sql")
end)

run_test("write lua with nested tables", {
	write_call("nested_tables.lua", [[
local config = {
  level1 = {
    level2 = {
      level3 = {
        text = "line\nnext\t tab",
      },
    },
  },
}

function config.to_json()
  return "{\"name\":\"test\",\"values\":[1,2,3],\"nested\":{\"key\":\"value\"}}"
end

return config
]]),
	"done",
}, function()
	assert_file_exists("nested_tables.lua")
	assert_syntax_valid("nested_tables.lua")
	assert_contains("nested_tables.lua", "level3")
end)

run_test("write python with complex strings", {
	write_call("regex_parser.py", [=[
"""Parser examples with quotes."""
import re

PATTERN = re.compile(r'(\d+)\s*"([^"\\]*(?:\\.[^"\\]*)*)"')
PATH = r"C:\Users\test\path"

def describe(data):
    return f"Result: {data['key']}\n"
]=]),
	"done",
}, function()
	assert_file_exists("regex_parser.py")
	assert_syntax_valid("regex_parser.py")
	assert_contains("regex_parser.py", "re.compile")
end)

run_test("edit middle section", {
	write_call("edit_target.lua", [[
local M = {}

function M.alpha()
  return "aaa"
end

function M.beta()
  return "bbb"
end

function M.gamma()
  return "ccc"
end

return M
]]),
	edit_call("edit_target.lua", 'return "bbb"', 'return "BETA_MODIFIED"'),
	"done",
}, function()
	assert_file_exists("edit_target.lua")
	assert_syntax_valid("edit_target.lua")
	assert_contains("edit_target.lua", "BETA_MODIFIED")
	assert_contains("edit_target.lua", '"aaa"')
	assert_contains("edit_target.lua", '"ccc"')
end)

run_test("write js with template literals", {
	write_call("server.js", [=[
async function fetchUrl(url) {
  try {
    const pattern = /https?:\/\/[^\s"'<>]+/g;
    const message = `url=${url} literal=\${notExpanded}`;
    const html = "</script>";
    return JSON.stringify({ message, html, ok: pattern.test(url) });
  } catch (err) {
    return JSON.stringify({ error: String(err) });
  }
}

module.exports = { fetchUrl };
]=]),
	"done",
}, function()
	assert_file_exists("server.js")
	assert_syntax_valid("server.js")
	assert_contains("server.js", "async")
end)

run_test("write lua that looks like JSON", {
	write_call("not_json.lua", [[
local M = {}

local samples = {
  "[\"item1\",\"item2\"]",
  "{\"key\":\"value\"}",
  "\"he said \\\"hello\\\"\"",
}

function M.samples()
  return samples
end

return M
]]),
	"done",
}, function()
	assert_file_exists("not_json.lua")
	assert_syntax_valid("not_json.lua")
	assert_contains("not_json.lua", "samples")
end)

run_test("edit insert between functions", {
	write_call("insert_test.lua", [[
local M = {}

function M.first()
  return 1
end

function M.last()
  return 99
end

return M
]]),
	edit_call("insert_test.lua", "function M.last()\n  return 99\nend", "function M.middle()\n  return 50\nend\n\nfunction M.last()\n  return 99\nend"),
	"done",
}, function()
	assert_file_exists("insert_test.lua")
	assert_syntax_valid("insert_test.lua")
	assert_contains("insert_test.lua", "M.middle")
	assert_contains("insert_test.lua", "return 50")
end)

run_test("write lua with long strings containing code", {
	write_call("template_engine.lua", [=[
local M = {}

local template = [[
<html>
<style>.icon:before { content: "\2014"; }</style>
<script>
const text = `hello ${name}`;
</script>
</html>
]]

function M.render(data)
  return (template:gsub("%${name}", data.name or ""))
end

return M
]=]),
	"done",
}, function()
	assert_file_exists("template_engine.lua")
	assert_syntax_valid("template_engine.lua")
	assert_contains("template_engine.lua", "<script")
end)

run_test("write lua with split tool markers", {
	write_call("stream_handler.lua", [[
local M = {}
local cancelled = false

function M.parse_stream(text)
  local open = text:find("<" .. "tool_call")
  local close = text:find("</" .. "tool_call>")
  return open, close
end

function M.filter_output(stream_buf)
  local cleaned = stream_buf:gsub("\r\n", "\n")
  if cleaned:find("\n") or cleaned:find("\t") then
    return string.format("%s\n", cleaned)
  end
  return cleaned
end

function M.on_signal()
  cancelled = true
end

return M
]]),
	"done",
}, function()
	assert_file_exists("stream_handler.lua")
	assert_syntax_valid("stream_handler.lua")
	assert_contains("stream_handler.lua", "cancelled")
	assert_contains("stream_handler.lua", [["</" .. "tool_call>"]])
end)

run_test("blocks invalid syntax writes", {
	write_call("broken.lua", [[
local function broken()
  if true then
    return 1
]]),
	"done",
}, function(result)
	assert_not_exists("broken.lua")
	if not result.text:find("done", 1, true) then
		error("core did not continue after blocked write")
	end
end)

os.execute("rm -rf " .. shell.quote(tmp_dir))

io.write("\n" .. dim("─────────────────────────────────────") .. "\n")
io.write(string.format("  %s passed, %s failed\n",
	green(tostring(passed)), failed > 0 and red(tostring(failed)) or tostring(failed)))

if #errors > 0 then
	io.write("\n" .. red("Failures:") .. "\n")
	for _, e in ipairs(errors) do
		io.write("  " .. e.name .. ": " .. e.err:sub(1, 120) .. "\n")
	end
end

io.write("\n")
os.exit(failed > 0 and 1 or 0)
