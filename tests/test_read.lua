#!/usr/bin/env lua

local script_dir = arg[0]:match("^(.*)/[^/]+$") or "."
local project_dir = script_dir .. "/.."
package.path = project_dir .. "/lua/?.lua;" .. project_dir .. "/lua/?/init.lua;" .. project_dir .. "/lua/?/?.lua;" .. package.path
pcall(require, "luarocks.loader")

local read_tool = require("agent.tools.read")

local passed = 0
local failed = 0

local function green(s) return "\27[32m" .. s .. "\27[0m" end
local function red(s) return "\27[31m" .. s .. "\27[0m" end
local function dim(s) return "\27[2m" .. s .. "\27[0m" end

local function assert_ne(left, right, message)
	if left == right then
		error(message or "values should differ")
	end
end

local function assert_contains(text, needle, message)
	if not text:find(needle, 1, true) then
		error((message or "missing text") .. ": " .. needle)
	end
end

local function write_file(path, content)
	local f = assert(io.open(path, "w"))
	f:write(content)
	f:close()
end

local tmp_dir = os.tmpname() .. "_lca_read_tests"
os.execute("rm -rf " .. string.format("%q", tmp_dir))
os.execute("mkdir -p " .. string.format("%q", tmp_dir))

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

io.write("\n" .. dim("═══ Read Tool Tests ═══") .. "\n\n")

run_test("line tags include content after byte 64", function()
	local prefix = string.rep("a", 64)
	local tag_a = read_tool.line_tag(1, prefix .. "x")
	local tag_b = read_tool.line_tag(1, prefix .. "y")
	assert_ne(tag_a, tag_b, "tags must change when long-line suffix changes")
end)

run_test("read output uses full-line tags", function()
	local path = tmp_dir .. "/long-line.txt"
	local prefix = string.rep("a", 64)
	write_file(path, prefix .. "x\n" .. prefix .. "y\n")

	local result = read_tool.execute({ path = path }, { cwd = tmp_dir })
	if result.is_error then
		error(result.content)
	end

	local tag_a = read_tool.line_tag(1, prefix .. "x")
	local tag_b = read_tool.line_tag(2, prefix .. "y")
	assert_contains(result.content, "1:" .. tag_a .. ": " .. prefix .. "x")
	assert_contains(result.content, "2:" .. tag_b .. ": " .. prefix .. "y")
end)

os.execute("rm -rf " .. string.format("%q", tmp_dir))

io.write("\n" .. dim("─────────────────────────────────────") .. "\n")
io.write(string.format("  %s passed, %s failed\n\n",
	green(tostring(passed)), failed > 0 and red(tostring(failed)) or tostring(failed)))

os.exit(failed > 0 and 1 or 0)
