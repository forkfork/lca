#!/usr/bin/env lua

local script_dir = arg[0]:match("^(.*)/[^/]+$") or "."
local project_dir = script_dir .. "/.."
package.path = project_dir .. "/lua/?.lua;" .. project_dir .. "/lua/?/init.lua;" .. project_dir .. "/lua/?/?.lua;" .. package.path
pcall(require, "luarocks.loader")

local edit_tool = require("agent.tools.edit")
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

os.execute("rm -rf " .. shell.quote(tmp_dir))

io.write("\n" .. dim("─────────────────────────────────────") .. "\n")
io.write(string.format("  %s passed, %s failed\n\n",
	green(tostring(passed)), failed > 0 and red(tostring(failed)) or tostring(failed)))

os.exit(failed > 0 and 1 or 0)
