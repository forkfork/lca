#!/usr/bin/env lua
--
-- Integration test: sends tricky write/edit prompts to the model via Bedrock
-- and verifies the resulting files are valid.
--
-- Usage:
--   lua tests/test_tool_writes.lua [--credentials path]
--
-- Each test case:
--   1. Sends a prompt asking the model to write/edit a file
--   2. Runs the full tool loop (core.run_session)
--   3. Checks the resulting file for syntax validity and expected content
--

local script_dir = arg[0]:match("^(.*)/[^/]+$") or "."
local project_dir = script_dir .. "/.."
package.path = project_dir .. "/lua/?.lua;" .. project_dir .. "/lua/?/init.lua;" .. project_dir .. "/lua/?/?.lua;" .. package.path
pcall(require, "luarocks.loader")

local core = require("agent.core")
local registry = require("agent.tool_registry")
local session_module = require("agent.session")
local fs = require("agent.util.fs")
local shell = require("agent.util.shell")
local config = require("agent.config")

-- Parse args
local credentials_path = config.default_credentials_path()
local test_filter = nil
local index = 1
while index <= #arg do
	if arg[index] == "--credentials" then
		credentials_path = arg[index + 1]
		index = index + 2
	elseif arg[index] == "--test" then
		test_filter = tonumber(arg[index + 1])
		index = index + 2
	else
		index = index + 1
	end
end

-- Test infrastructure
local tmp_dir = os.tmpname() .. "_lca_tests"
os.execute("rm -f " .. tmp_dir)
os.execute("mkdir -p " .. tmp_dir)

-- Log to a test-specific file
core.set_transcript("/tmp/lca_test.log")

local passed = 0
local failed = 0
local errors = {}

local function green(s) return "\27[32m" .. s .. "\27[0m" end
local function red(s) return "\27[31m" .. s .. "\27[0m" end
local function dim(s) return "\27[2m" .. s .. "\27[0m" end

local test_number = 0

local function run_test(name, prompt, checks)
	test_number = test_number + 1
	if test_filter and test_filter ~= test_number then
		return
	end

	io.write(dim(string.format("  [%d] ", test_number)) .. name .. " ")
	io.flush()

	local session = session_module.create({
		credentials_path = credentials_path,
		model = nil,
	})
	session.cwd = tmp_dir

	session:add_user(prompt)

	-- Timeout watchdog — kill after 90s to prevent hanging
	local uv = require("luv")
	local watchdog = uv.new_timer()
	local timed_out = false
	watchdog:start(90000, 0, function()
		timed_out = true
		watchdog:stop()
		watchdog:close()
	end)

	local ok, result = pcall(function()
		return core.run_session(session, nil, nil, nil)
	end)

	if not watchdog:is_closing() then
		watchdog:stop()
		watchdog:close()
	end

	if timed_out then
		failed = failed + 1
		io.write(red("FAIL") .. " (timed out after 90s)\n")
		errors[#errors + 1] = { name = name, err = "timed out" }
		return
	end

	if not ok then
		failed = failed + 1
		io.write(red("FAIL") .. " (error: " .. tostring(result):sub(1, 80) .. ")\n")
		errors[#errors + 1] = { name = name, err = tostring(result) }
		return
	end

	-- Run checks
	local check_ok, check_err = pcall(checks)
	if check_ok then
		passed = passed + 1
		io.write(green("PASS") .. "\n")
	else
		failed = failed + 1
		io.write(red("FAIL") .. " (" .. tostring(check_err):sub(1, 100) .. ")\n")
		errors[#errors + 1] = { name = name, err = tostring(check_err) }
	end
end

local function assert_file_exists(path)
	local full = tmp_dir .. "/" .. path
	local f = io.open(full, "r")
	if not f then
		error("file not created: " .. path)
	end
	f:close()
end

local function read_file(path)
	local full = tmp_dir .. "/" .. path
	local f = io.open(full, "r")
	if not f then error("file not found: " .. path) end
	local content = f:read("*a")
	f:close()
	return content
end

local function assert_syntax_valid(path)
	local full = tmp_dir .. "/" .. path
	local ext = path:match("%.([^%.]+)$")
	local cmd
	if ext == "lua" then
		cmd = "luac -p"
	elseif ext == "py" then
		cmd = "python3 -m py_compile"
	elseif ext == "js" then
		cmd = "node --check"
	else
		return -- no checker available
	end
	local handle = io.popen(cmd .. " " .. shell.quote(full) .. " 2>&1", "r")
	local output = handle:read("*a")
	local _, _, code = handle:close()
	if code ~= 0 then
		error("syntax error in " .. path .. ": " .. output:sub(1, 200))
	end
end

local function assert_contains(path, pattern)
	local content = read_file(path)
	if not content:find(pattern, 1, true) then
		error(path .. " does not contain: " .. pattern:sub(1, 60))
	end
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- TEST CASES
-- ═══════════════════════════════════════════════════════════════════════════════

io.write("\n" .. dim("═══ Moonclaw Tool Write Tests ═══") .. "\n\n")

-- Test 1: Write a Lua file with nested quotes and escapes
run_test("write lua with nested quotes", [==[
Write a file called "tricky_quotes.lua" that contains:
- A function that returns a string with double quotes inside it (use escaped quotes)
- A multi-line string using [[ ]] syntax containing backslashes
- A pattern match using %d+ and string.format with %s
- The function should be called generate_sql and return an SQL query like: SELECT * FROM "users" WHERE name = 'O\'Brien'
Just write the file, don't explain.
]==], function()
	assert_file_exists("tricky_quotes.lua")
	assert_syntax_valid("tricky_quotes.lua")
	assert_contains("tricky_quotes.lua", "function")
end)

-- Test 2: Write a Lua file with complex nested tables and string interpolation
run_test("write lua with nested tables", [==[
Write a file called "nested_tables.lua" with:
- A module that exports a config table
- The config has nested tables 3 levels deep
- Include string values with newlines (\n), tabs (\t), and null bytes (\0)
- Include a function that builds a JSON string manually using concatenation (not a library)
- The JSON output should look like: {"name":"test","values":[1,2,3],"nested":{"key":"value"}}
Just write the file directly.
]==], function()
	assert_file_exists("nested_tables.lua")
	assert_syntax_valid("nested_tables.lua")
	assert_contains("nested_tables.lua", "return")
end)

-- Test 3: Write Python with triple quotes, f-strings, regex
run_test("write python with complex strings", [==[
Write "regex_parser.py" containing:
- A function that uses re.compile with a pattern containing backslashes: r'(\d+)\s*"([^"\\]*(?:\\.[^"\\]*)*)"'
- An f-string that interpolates a dict value: f"Result: {data['key']}\n"
- A triple-quoted docstring with example code that itself contains quotes
- A raw string path: r"C:\Users\test\path"
Just write the file.
]==], function()
	assert_file_exists("regex_parser.py")
	assert_syntax_valid("regex_parser.py")
	assert_contains("regex_parser.py", "re.compile")
end)

-- Test 4: Edit - replace middle of a file
run_test("edit middle section of file", [==[
First write a file "edit_target.lua" with this exact content:

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

Then edit ONLY the beta function to return "BETA_MODIFIED" instead of "bbb". Don't change anything else.
]==], function()
	assert_file_exists("edit_target.lua")
	assert_syntax_valid("edit_target.lua")
	assert_contains("edit_target.lua", "BETA_MODIFIED")
	assert_contains("edit_target.lua", '"aaa"')
	assert_contains("edit_target.lua", '"ccc"')
end)

-- Test 5: Write JavaScript with template literals, regex, JSON
run_test("write js with template literals", [==[
Write "server.js" with:
- A template literal containing backticks (escaped) and ${expressions}
- A regex: /https?:\/\/[^\s"'<>]+/g
- JSON.stringify output with special chars
- An async function with try/catch
- A string that contains </script> (which looks like HTML but is in JS)
Just write the file.
]==], function()
	assert_file_exists("server.js")
	assert_syntax_valid("server.js")
	assert_contains("server.js", "async")
end)

-- Test 6: Write a Lua file with the EXACT patterns that broke before (JSON array)
run_test("write lua that looks like JSON", [==[
Write "not_json.lua" - a Lua module that:
- Has a function that parses JSON manually (without cjson)
- The function handles arrays like ["item1","item2"]
- It handles objects like {"key":"value"}
- It handles escaped quotes inside strings: "he said \"hello\""
- It handles unicode escapes: "A" should become "A"
- Include test cases as local variables with these exact JSON strings embedded
Just write valid Lua code.
]==], function()
	assert_file_exists("not_json.lua")
	assert_syntax_valid("not_json.lua")
	assert_contains("not_json.lua", "function")
end)

-- Test 7: Edit - insert new function between existing ones
run_test("edit insert between functions", [==[
First write "insert_test.lua":

local M = {}

function M.first()
  return 1
end

function M.last()
  return 99
end

return M

Then edit the file to INSERT a new function M.middle() between first() and last() that returns 50. Keep both existing functions intact.
]==], function()
	assert_file_exists("insert_test.lua")
	assert_syntax_valid("insert_test.lua")
	assert_contains("insert_test.lua", "M.middle")
	assert_contains("insert_test.lua", "return 50")
	assert_contains("insert_test.lua", "M.first")
	assert_contains("insert_test.lua", "M.last")
end)

-- Test 8: Write a file with heredoc-like patterns
run_test("write lua with long strings containing code", [==[
Write "template_engine.lua" that:
- Contains a long string (using [[ ]]) that holds an HTML template
- The HTML has <script> tags with JavaScript code inside
- The JavaScript inside contains template literals with ${vars}
- Also has a CSS block with content: "\2014" (em dash unicode)
- The module has a function render(data) that does gsub substitutions on the template
Write it as valid Lua.
]==], function()
	assert_file_exists("template_engine.lua")
	assert_syntax_valid("template_engine.lua")
	assert_contains("template_engine.lua", "<script")
	assert_contains("template_engine.lua", "function")
end)

-- Test 9: Write a Lua file with SIGINT/signal handling and escape sequences
-- (Reproduces the exact failure pattern from lca.log where editing repl.lua
-- with escape sequences in string literals caused "unfinished string" errors)
run_test("write lua with signal handling and stream parsing", [==[
Write "stream_handler.lua" - a Lua module that:
- Has a variable `cancelled = false` at module level
- Has a function `parse_stream(text)` that looks for XML-like tags in the text
- Inside parse_stream, use string.find with patterns like `<tool_call` and `</tool_call>`
- Has a function `filter_output(stream_buf)` that:
  - Checks for `\n` (newline) and `\t` (tab) characters in the buffer
  - Uses string.gsub to replace `\r\n` with `\n`
  - Returns the cleaned buffer
- Has a function `on_signal()` that sets cancelled = true
- Uses string.format with escape sequences like "%s\n" for formatting output
Write it as valid Lua.
]==], function()
	assert_file_exists("stream_handler.lua")
	assert_syntax_valid("stream_handler.lua")
	assert_contains("stream_handler.lua", "cancelled")
	assert_contains("stream_handler.lua", "function")
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- Summary
-- ═══════════════════════════════════════════════════════════════════════════════

io.write("\n" .. dim("─────────────────────────────────────") .. "\n")
io.write(string.format("  %s passed, %s failed\n",
	green(tostring(passed)), failed > 0 and red(tostring(failed)) or tostring(failed)))

if #errors > 0 then
	io.write("\n" .. red("Failures:") .. "\n")
	for _, e in ipairs(errors) do
		io.write("  " .. e.name .. ": " .. e.err:sub(1, 120) .. "\n")
	end
end

-- Cleanup
os.execute("rm -rf " .. shell.quote(tmp_dir))

io.write("\n")
os.exit(failed > 0 and 1 or 0)
