#!/usr/bin/env lua

local script_dir = arg[0]:match("^(.*)/[^/]+$") or "."
local project_dir = script_dir .. "/.."
package.path = project_dir .. "/lua/?.lua;" .. project_dir .. "/lua/?/init.lua;" .. project_dir .. "/lua/?/?.lua;" .. package.path
pcall(require, "luarocks.loader")

local grep_tool = require("agent.tools.grep")
local shell = require("agent.util.shell")

local passed = 0
local failed = 0

local function green(s) return "\27[32m" .. s .. "\27[0m" end
local function red(s) return "\27[31m" .. s .. "\27[0m" end
local function dim(s) return "\27[2m" .. s .. "\27[0m" end

local function assert_eq(actual, expected, message)
	if actual ~= expected then
		error((message or "values differ") .. "\nexpected: " .. tostring(expected) .. "\nactual: " .. tostring(actual))
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

local tmp_dir = os.tmpname() .. "_lca_grep_tests"
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

io.write("\n" .. dim("═══ Grep Tool Tests ═══") .. "\n\n")

run_test("finds matches", function()
	write_file(tmp_dir .. "/one.txt", "alpha\nneedle\n")
	local result = grep_tool.execute({ path = tmp_dir, pattern = "needle" }, { cwd = tmp_dir })
	assert_eq(result.is_error, false)
	assert_contains(result.content, "one.txt")
	assert_contains(result.content, "needle")
end)

run_test("dash-prefixed patterns are search text with and without glob", function()
	write_file(tmp_dir .. "/flags.txt", "Use --token-ttl-seconds to configure expiry.\n")
	for _, args in ipairs({
		{ path = tmp_dir, pattern = "--token-ttl-seconds" },
		{ path = tmp_dir, pattern = "--token-ttl-seconds", glob = "*.txt" },
	}) do
		local result = grep_tool.execute(args, { cwd = tmp_dir, session = { grep_evidence = true } })
		assert_eq(result.is_error, false)
		assert_contains(result.content, "flags.txt")
		assert_contains(result.content, "--token-ttl-seconds")
	end
end)

run_test("honors glob", function()
	write_file(tmp_dir .. "/two.txt", "needle\n")
	write_file(tmp_dir .. "/three.lua", "needle\n")
	local result = grep_tool.execute({ path = tmp_dir, pattern = "needle", glob = "*.lua" }, { cwd = tmp_dir })
	assert_eq(result.is_error, false)
	assert_contains(result.content, "three.lua")
	if result.content:find("two.txt", 1, true) then
		error("glob matched excluded file")
	end
end)

run_test("evidence mode returns editable tagged context", function()
	write_file(tmp_dir .. "/evidence.lua", "local before = 1\nlocal needle = before + 1\nreturn needle\n")
	local result = grep_tool.execute({ path = "evidence.lua", pattern = "needle" }, {
		cwd = tmp_dir,
		session = { grep_evidence = true },
	})
	assert_eq(result.is_error, false)
	assert_eq(result.summary, "2 matches")
	assert_contains(result.content, "[evidence.lua snapshot=")
	assert_contains(result.content, "2:")
	assert_contains(result.content, ": local needle = before + 1")
end)


os.execute("rm -rf " .. shell.quote(tmp_dir))

io.write("\n" .. dim("─────────────────────────────────────") .. "\n")
io.write(string.format("  %s passed, %s failed\n\n",
	green(tostring(passed)), failed > 0 and red(tostring(failed)) or tostring(failed)))

os.exit(failed > 0 and 1 or 0)
