#!/usr/bin/env lua
local script_dir = arg[0]:match("^(.*)/[^/]+$") or "."
local root = script_dir .. "/.."
package.path = root .. "/lua/?.lua;" .. package.path
local shell = require("agent.util.shell")
local rockspec = setmetatable({}, { __index = _G })
assert(loadfile(root .. "/lca-dev-1.rockspec", "t", rockspec))()
local files = assert(io.popen("find " .. shell.quote(root .. "/lua") .. " -type f -name '*.lua'"))
for file in files:lines() do
	local relative = file:sub(#root + 2)
	local module = relative:gsub("^lua/", ""):gsub("%.lua$", ""):gsub("/init$", ""):gsub("/", ".")
	assert(rockspec.build.modules[module] == relative, "missing or incorrect packaged module: " .. module)
end
assert(files:close())
for module, file in pairs(rockspec.build.modules) do
	local handle = assert(io.open(root .. "/" .. file, "r"), "missing packaged file: " .. module)
	handle:close()
end
print("Packaging module inventory PASS")
