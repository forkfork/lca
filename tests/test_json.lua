#!/usr/bin/env lua

local script_dir = arg[0]:match("^(.*)/[^/]+$") or "."
local project_dir = script_dir .. "/.."
package.path = project_dir .. "/lua/?.lua;" .. project_dir .. "/lua/?/init.lua;" .. project_dir .. "/lua/?/?.lua;" .. package.path
pcall(require, "luarocks.loader")

local cjson = require("cjson")
local json = require("agent.util.json")

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

local function assert_not_contains(text, needle, message)
	if text:find(needle, 1, true) then
		error((message or "unexpected text") .. ": " .. needle)
	end
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

io.write("\n" .. dim("═══ JSON Utility Tests ═══") .. "\n\n")

run_test("string escapes ansi control bytes", function()
	local value = "\27[32mPASS\27[0m"
	local encoded = json.string(value)
	assert_not_contains(encoded, "\27", "encoded JSON string must not contain raw ESC")
	assert_contains(encoded, "\\u001B")
	assert_eq(cjson.decode(encoded), value)
end)

run_test("string escapes json controls and punctuation", function()
	local value = "nul\0bell\7\n\t\"\\"
	local encoded = json.string(value)
	assert_contains(encoded, "\\u0000")
	assert_contains(encoded, "\\u0007")
	assert_contains(encoded, "\\n")
	assert_contains(encoded, "\\t")
	assert_contains(encoded, '\\"')
	assert_contains(encoded, "\\\\")
	assert_eq(cjson.decode(encoded), value)
end)

run_test("provider-style body with colored output decodes", function()
	local output = "\27[2mtest \27[32mPASS\27[0m"
	local body = '{"role":"tool","content":' .. json.string(output) .. '}'
	local decoded = cjson.decode(body)
	assert_eq(decoded.content, output)
end)

io.write("\n" .. dim("─────────────────────────────────────") .. "\n")
io.write(string.format("  %s passed, %s failed\n\n",
	green(tostring(passed)), failed > 0 and red(tostring(failed)) or tostring(failed)))

os.exit(failed > 0 and 1 or 0)
