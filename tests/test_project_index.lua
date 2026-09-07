#!/usr/bin/env lua
local script_dir = arg[0]:match("^(.*)/[^/]+$") or "."
package.path = script_dir .. "/../lua/?.lua;" .. package.path
pcall(require, "luarocks.loader")

local index = require("agent.project_index")
local shell = require("agent.util.shell")
local root = os.tmpname() .. "_lca_index_tests"
local function command(cmd)
	assert(os.execute(cmd))
end
local function write(relative)
	local file = assert(io.open(root .. "/" .. relative, "w"))
	file:write("fixture\n")
	file:close()
end
local function contains(text, value)
	assert(text:find(value, 1, true), "missing " .. value)
end

local ok, err = pcall(function()
	command("mkdir -p " .. shell.quote(root .. "/evals/fixtures/src") .. " " .. shell.quote(root .. "/lua/agent"))
	write("README.md")
	write("lua/agent/tui.lua")
	write("lua/agent/river_divider.lua")
	for i = 1, 210 do write(string.format("evals/fixtures/src/file%03d.lua", i)) end

	-- Exercise both inventory backends, including tracked and untracked files.
	for _, git in ipairs({ false, true }) do
		if git then
			command("git -C " .. shell.quote(root) .. " init -q")
			command("git -C " .. shell.quote(root) .. " add evals README.md")
		end
		local result = index.build(root)
		contains(result, "Root map")
		contains(result, "README.md")
		contains(result, "lua/")
		contains(result, "evals/")
		assert(not result:find("file001.lua", 1, true), "deep fixtures leaked into root map")
		local tree = assert(result:match("```\n(.-)\n```"))
		local count = 0
		for _ in tree:gmatch("[^\n]+") do count = count + 1 end
		assert(count == 3, "expected root file and two directories")
		assert(result == index.build(root), "index is not deterministic")
	end
end)
os.execute("rm -rf " .. shell.quote(root))
assert(ok, err)
print("Project index: git/non-git crowded-tree regression passed")
