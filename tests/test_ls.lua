#!/usr/bin/env lua

local script_dir = arg[0]:match("^(.*)/[^/]+$") or "."
local project_dir = script_dir .. "/.."
package.path = project_dir .. "/lua/?.lua;" .. project_dir .. "/lua/?/init.lua;" .. project_dir .. "/lua/?/?.lua;" .. package.path
pcall(require, "luarocks.loader")

local ls = require("agent.tools.ls")

local passed = 0
local failed = 0

local function test(name, fn)
	io.write("  " .. name .. " ")
	io.flush()
	local ok, err = pcall(fn)
	if ok then
		passed = passed + 1
		io.write("PASS\n")
	else
		failed = failed + 1
		io.write("FAIL (" .. tostring(err) .. ")\n")
	end
end

local function assert_eq(actual, expected, msg)
	if actual ~= expected then
		error((msg or "") .. " expected: " .. tostring(expected) .. ", got: " .. tostring(actual))
	end
end

test("missing path is non-error context", function()
	local result = ls.execute({ path = "/tmp/lca-definitely-missing-path" }, { cwd = "." })
	assert_eq(result.is_error, false)
	assert_eq(result.summary, "missing")
end)

if failed > 0 then
	error(tostring(failed) .. " test(s) failed")
end

io.write("\n" .. tostring(passed) .. " test(s) passed\n")
