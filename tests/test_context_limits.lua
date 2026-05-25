#!/usr/bin/env lua

local script_dir = arg[0]:match("^(.*)/[^/]+$") or "."
local project_dir = script_dir .. "/.."
package.path = project_dir .. "/lua/?.lua;" .. project_dir .. "/lua/?/init.lua;" .. project_dir .. "/lua/?/?.lua;" .. package.path
pcall(require, "luarocks.loader")
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

local function reload()
	package.loaded["agent.context_limits"] = nil
	return require("agent.context_limits")
end

local function child_eval(env, expr)
	local command = env .. " lua -e " .. shell.quote(
		"package.path=" .. string.format("%q", project_dir .. "/lua/?.lua;" .. project_dir .. "/lua/?/init.lua;" .. project_dir .. "/lua/?/?.lua;") .. "..package.path; local l=require('agent.context_limits'); print(" .. expr .. ")"
	)
	local pipe = assert(io.popen(command, "r"))
	local output = pipe:read("*a")
	pipe:close()
	return (output:gsub("%s+$", ""))
end

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

io.write("\n" .. dim("═══ Context Limit Tests ═══") .. "\n\n")

run_test("known model threshold uses context window minus reserve", function()
	local limits = reload()
	assert_eq(limits.context_window("gpt-5.5"), 200000)
	assert_eq(limits.reserve_tokens(), 16384)
	assert_eq(limits.auto_compact_threshold("gpt-5.5"), 183616)
end)

run_test("gpt-5 family defaults to larger context", function()
	local limits = reload()
	assert_eq(limits.context_window("gpt-5-something"), 400000)
end)

run_test("deepseek family uses documented large context", function()
	local limits = reload()
	assert_eq(limits.context_window("deepseek-v4-pro"), 1000000)
	assert_eq(limits.context_window("deepseek-custom"), 1000000)
end)

run_test("explicit auto compact override wins", function()
	assert_eq(child_eval("LCA_AUTO_COMPACT_TOKENS=50000", "l.auto_compact_threshold('gpt-5.5')"), "50000")
	assert_eq(child_eval("LCA_AUTO_COMPACT_TOKENS=0", "l.auto_compact_threshold('gpt-5.5')"), "0")
end)

run_test("context window override affects threshold", function()
	assert_eq(child_eval("LCA_CONTEXT_WINDOW=100000 LCA_CONTEXT_RESERVE_TOKENS=10000", "l.auto_compact_threshold('gpt-5.5')"), "90000")
end)

io.write("\n" .. dim("─────────────────────────────────────") .. "\n")
io.write(string.format("  %s passed, %s failed\n\n",
	green(tostring(passed)), failed > 0 and red(tostring(failed)) or tostring(failed)))

os.exit(failed > 0 and 1 or 0)
