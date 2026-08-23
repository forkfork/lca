#!/usr/bin/env lua

local script_dir = arg[0]:match("^(.*)/[^/]+$") or "."
local project_dir = script_dir .. "/.."
package.path = project_dir .. "/lua/?.lua;" .. project_dir .. "/lua/?/init.lua;" .. project_dir .. "/lua/?/?.lua;" .. package.path
pcall(require, "luarocks.loader")

local edit_tool = require("agent.tools.edit")
local lint = require("agent.lint")
local read_tool = require("agent.tools.read")
local shell = require("agent.util.shell")

local passed = 0
local failed = 0

local function green(s) return "\27[32m" .. s .. "\27[0m" end
local function red(s) return "\27[31m" .. s .. "\27[0m" end
local function dim(s) return "\27[2m" .. s .. "\27[0m" end

local function assert_contains(text, needle, message)
	if not text:find(needle, 1, true) then
		error((message or "missing text") .. ": " .. needle)
	end
end

local function assert_not_contains(text, needle, message)
	if text:find(needle, 1, true) then
		error((message or "unexpected text") .. ": " .. needle)
	end
end

local function write_file(path, content)
	local f = assert(io.open(path, "w"))
	f:write(content)
	f:close()
end

local tmp_dir = "/tmp/lca_edit_tests_" .. tostring(os.time()) .. "_" .. tostring(math.random(1000000))
os.execute("rm -rf " .. shell.quote(tmp_dir))
os.execute("mkdir -p " .. shell.quote(tmp_dir))

local function run_test(name, fn)
	io.write(dim("  " .. name .. " "))
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

io.write("\n" .. dim("═══ Edit Tool Tests ═══") .. "\n\n")

run_test("blocked syntax errors use target path and candidate context", function()
	local target = tmp_dir .. "/broken.lua"
	write_file(target, "local function demo()\n\treturn 1\nend\n")
	local lines = read_tool.split_lines(assert(io.open(target)):read("*a"))
	local result = edit_tool.execute({
		path = target,
		start_line = 2,
		start_tag = read_tool.line_tag(2, lines[2]),
		end_line = 2,
		end_tag = read_tool.line_tag(2, lines[2]),
		_raw_content = "\tif true then\n\t\treturn 1",
	}, { cwd = tmp_dir })

	if not result.is_error then
		error("edit should have been blocked")
	end
	assert_contains(result.content, "Requested edit: " .. target .. " lines 2-2")
	assert_contains(result.content, "Candidate context around reported line")
	assert_contains(result.content, ">")
	assert_contains(result.content, target)
	assert_not_contains(result.content, "/tmp/lua_", "temp lint path should be hidden")
end)

run_test("accepts runtime Lua syntax newer than system luac", function()
	local target = tmp_dir .. "/bitwise.lua"
	write_file(target, "local value = 1 ~ 2\nreturn value\n")
	local lines = read_tool.split_lines(assert(io.open(target)):read("*a"))
	local result = edit_tool.execute({
		path = target,
		start_line = 2,
		start_tag = read_tool.line_tag(2, lines[2]),
		end_line = 2,
		end_tag = read_tool.line_tag(2, lines[2]),
		_raw_content = "return value + 1",
	}, { cwd = tmp_dir })

	if result.is_error then
		error(result.content)
	end
end)

run_test("lua lint parses candidate without executing it", function()
	local marker = tmp_dir .. "/lint_executed"
	local target = tmp_dir .. "/side_effect.lua"
	write_file(target, "assert(io.open(" .. string.format("%q", marker) .. ", \"w\")):write(\"ran\")\n")

	local file = assert(io.open(target, "r"))
	local content = file:read("*a")
	file:close()

	local lint_output = lint.check_content(target, content)
	if lint_output then
		error(lint_output)
	end
	local f = io.open(marker, "r")
	if f then
		f:close()
		error("lua syntax checker executed candidate file")
	end
end)

run_test("allows edits that preserve pre-existing syntax error", function()
	local target = tmp_dir .. "/already_broken.lua"
	write_file(target, "local = 1\nreturn 1\n")
	local lines = read_tool.split_lines(assert(io.open(target)):read("*a"))
	local result = edit_tool.execute({
		path = target,
		start_line = 2,
		start_tag = read_tool.line_tag(2, lines[2]),
		end_line = 2,
		end_tag = read_tool.line_tag(2, lines[2]),
		_raw_content = "return 2",
	}, { cwd = tmp_dir })

	if result.is_error then
		error(result.content)
	end
end)

run_test("multi-edit applies non-overlapping hunks atomically", function()
	local target = tmp_dir .. "/multi.lua"
	write_file(target, "local first = 1\nlocal middle = 2\nlocal last = 3\nreturn first + middle + last\n")
	local file = assert(io.open(target, "r"))
	local original = file:read("*a")
	file:close()
	local lines = read_tool.split_lines(original)
	local result = edit_tool.execute({
		path = target,
		edits = {
			{ start_line = 1, start_tag = read_tool.line_tag(1, lines[1]), end_line = 1, end_tag = read_tool.line_tag(1, lines[1]), content = "local first = 10" },
			{ start_line = 3, start_tag = read_tool.line_tag(3, lines[3]), end_line = 3, end_tag = read_tool.line_tag(3, lines[3]), content = "local last = 30" },
		},
	}, { cwd = tmp_dir })
	if result.is_error then error(result.content) end
	assert_contains(result.summary, "2 hunks")
	local updated = assert(io.open(target, "r")):read("*a")
	assert_contains(updated, "local first = 10")
	assert_contains(updated, "local middle = 2")
	assert_contains(updated, "local last = 30")
end)

run_test("multi-edit rolls back every hunk when one tag is stale", function()
	local target = tmp_dir .. "/multi-stale.lua"
	local original = "local first = 1\nlocal last = 2\nreturn first + last\n"
	write_file(target, original)
	local lines = read_tool.split_lines(original)
	local result = edit_tool.execute({
		path = target,
		edits = {
			{ start_line = 1, start_tag = read_tool.line_tag(1, lines[1]), end_line = 1, end_tag = read_tool.line_tag(1, lines[1]), content = "local first = 10" },
			{ start_line = 2, start_tag = "BAD!", end_line = 2, end_tag = read_tool.line_tag(2, lines[2]), content = "local last = 20" },
		},
	}, { cwd = tmp_dir })
	if not result.is_error then error("stale multi-edit should fail") end
	assert_contains(result.content, "hunk #2")
	assert_contains(result.content, "no edits were applied")
	local file = assert(io.open(target, "r"))
	local actual = file:read("*a")
	file:close()
	if actual ~= original then error("stale multi-edit partially modified the file") end
end)

run_test("multi-edit rejects overlaps without writing", function()
	local target = tmp_dir .. "/multi-overlap.lua"
	local original = "local a = 1\nlocal b = 2\nreturn a + b\n"
	write_file(target, original)
	local lines = read_tool.split_lines(original)
	local result = edit_tool.execute({
		path = target,
		edits = {
			{ start_line = 1, start_tag = read_tool.line_tag(1, lines[1]), end_line = 2, end_tag = read_tool.line_tag(2, lines[2]), content = "local a, b = 1, 2" },
			{ start_line = 2, start_tag = read_tool.line_tag(2, lines[2]), end_line = 2, end_tag = read_tool.line_tag(2, lines[2]), content = "local b = 20" },
		},
	}, { cwd = tmp_dir })
	if not result.is_error then error("overlapping multi-edit should fail") end
	if result.summary ~= "overlapping hunks" then error(result.summary) end
	local file = assert(io.open(target, "r"))
	local actual = file:read("*a")
	file:close()
	if actual ~= original then error("overlapping multi-edit modified the file") end
end)

run_test("multi-edit syntax failure leaves the original file intact", function()
	local target = tmp_dir .. "/multi-syntax.lua"
	local original = "local first = 1\nlocal last = 2\nreturn first + last\n"
	write_file(target, original)
	local lines = read_tool.split_lines(original)
	local result = edit_tool.execute({
		path = target,
		edits = {
			{ start_line = 1, start_tag = read_tool.line_tag(1, lines[1]), end_line = 1, end_tag = read_tool.line_tag(1, lines[1]), content = "local first =" },
			{ start_line = 2, start_tag = read_tool.line_tag(2, lines[2]), end_line = 2, end_tag = read_tool.line_tag(2, lines[2]), content = "local last = 20" },
		},
	}, { cwd = tmp_dir })
	if not result.is_error then error("invalid multi-edit should fail") end
	if result.summary ~= "syntax error — not written" then error(result.summary) end
	local file = assert(io.open(target, "r"))
	local actual = file:read("*a")
	file:close()
	if actual ~= original then error("invalid multi-edit modified the file") end
end)

run_test("tagged edit safely relocates an unchanged range after line insertion", function()
	local target = tmp_dir .. "/relocated.lua"
	local before = "local first = 1\nlocal middle = 2\nlocal target = 3\nreturn first + middle + target\n"
	local original_lines = read_tool.split_lines(before)
	write_file(target, "local inserted = 0\n" .. before)
	local result = edit_tool.execute({
		path = target,
		start_line = 3,
		start_tag = read_tool.line_tag(3, original_lines[3]),
		end_line = 3,
		end_tag = read_tool.line_tag(3, original_lines[3]),
		_raw_content = "local target = 30",
	}, { cwd = tmp_dir })
	if result.is_error then error(result.content) end
	assert_contains(result.summary, "relocated +1")
	local file = assert(io.open(target, "r"))
	local actual = file:read("*a")
	file:close()
	assert_contains(actual, "local inserted = 0")
	assert_contains(actual, "local target = 30")
end)

run_test("tagged edit rejects ambiguous relocation candidates", function()
	local target = tmp_dir .. "/ambiguous-relocation.txt"
	local original = "header\nrepeat me\ntail\n"
	local original_lines = read_tool.split_lines(original)
	write_file(target, "inserted\nheader\nrepeat me\nrepeat me\ntail\n")
	local result = edit_tool.execute({
		path = target,
		start_line = 2,
		start_tag = read_tool.line_tag(2, original_lines[2]),
		end_line = 2,
		end_tag = read_tool.line_tag(2, original_lines[2]),
		_raw_content = "changed",
	}, { cwd = tmp_dir })
	if not result.is_error then error("ambiguous relocated edit should fail") end
	if result.summary ~= "stale tag" then error(result.summary) end
end)

os.execute("rm -rf " .. shell.quote(tmp_dir))

io.write("\n" .. dim("─────────────────────────────────────") .. "\n")
io.write(string.format("  %s passed, %s failed\n\n",
	green(tostring(passed)), failed > 0 and red(tostring(failed)) or tostring(failed)))

os.exit(failed > 0 and 1 or 0)
