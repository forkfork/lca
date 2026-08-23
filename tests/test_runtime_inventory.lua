#!/usr/bin/env lua

local script_dir = arg[0]:match("^(.*)/[^/]+$") or "."
local project_dir = script_dir .. "/.."
package.path = project_dir .. "/lua/?.lua;" .. project_dir .. "/lua/?/init.lua;" .. project_dir .. "/lua/?/?.lua;" .. package.path
pcall(require, "luarocks.loader")

local inventory = require("agent.runtime_inventory")
local shell = require("agent.util.shell")
local uv = require("luv")

local passed, failed = 0, 0
local function test(name, fn)
	local ok, err = pcall(fn)
	if ok then
		passed = passed + 1
		print("  " .. name .. " PASS")
	else
		failed = failed + 1
		print("  " .. name .. " FAIL: " .. tostring(err))
	end
end

local root = os.tmpname() .. "_lca_runtime_inventory"
os.execute("rm -rf " .. shell.quote(root))
assert(uv.fs_mkdir(root, tonumber("700", 8)))

local function write(name, mode)
	local path = root .. "/" .. name
	local file = assert(io.open(path, "w"))
	file:write("#!/bin/sh\nexit 0\n")
	file:close()
	assert(uv.fs_chmod(path, tonumber(mode, 8)))
	return path
end

local python3 = write("python3", "700")
write("python", "600")
local lua = write("lua", "700")

test("scan distinguishes executable aliases without launching them", function()
	local result = inventory.scan(root)
	assert(result.executables.python == nil, "non-executable python should be missing")
	assert(result.executables.python3 == python3, "python3 path was not resolved")
	assert(result.executables.lua == lua, "lua path was not resolved")
end)

test("section exposes available and missing aliases compactly", function()
	local section = inventory.section(root)
	assert(section:find("python=missing", 1, true), section)
	assert(section:find("python3=" .. python3, 1, true), section)
	assert(section:find("lua=" .. lua, 1, true), section)
	assert(not section:find("ruby=", 1, true), section)
	assert(not section:find("java=", 1, true), section)
	assert(not section:find("bun=", 1, true), section)
end)

test("resolver supports tools outside the advertised inventory", function()
	local bx = write("bx", "700")
	assert(inventory.resolve("bx", root) == bx)
end)

os.execute("rm -rf " .. shell.quote(root))

print(string.format("\n%d test(s) passed", passed))
if failed > 0 then os.exit(1) end
