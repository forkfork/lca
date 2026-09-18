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
	local sources = type(file) == "table" and file.sources or { file }
	for _, source in ipairs(sources) do
		local handle = assert(io.open(root .. "/" .. source, "r"), "missing packaged file: " .. module)
		handle:close()
	end
end
print("Packaging module inventory PASS")

-- Exercise installed modules without Python from outside the checkout. Run make local
-- before this suite; source-only tests cannot detect missing installed assets.
local uv = require('luv')
local checkout = assert(uv.fs_realpath(root))
local directory = os.tmpname(); os.remove(directory); assert(uv.fs_mkdir(directory, 448))
assert(uv.fs_symlink('/bin/sh', directory .. '/sh'))
assert(uv.fs_symlink('/bin/mkdir', directory .. '/mkdir'))
local program = [[
pcall(require, 'luarocks.loader')
local source = assert(package.searchpath('agent.tools.apply_patch', package.path))
assert(not source:find(CHECKOUT, 1, true), 'packaging smoke loaded checkout modules')
local registry = require('agent.tool_registry')
assert(registry.get('apply_patch') and not registry.get('edit'))
local fs = require('agent.util.fs')
local cwd = require('luv').cwd()
local function apply(kind, diff)
 local result = registry.execute('apply_patch', {type=kind, path='installed.txt', diff=diff}, {cwd=cwd})
 assert(not result.is_error, result.content)
end
apply('create_file', '+one\n+two')
apply('update_file', '@@\n-one\n+ONE\n two')
assert(fs.read_file(cwd .. '/installed.txt') == 'ONE\ntwo\n')
apply('delete_file')
assert(not require('luv').fs_lstat(cwd .. '/installed.txt'))
]]
program = 'local CHECKOUT = ' .. string.format('%q', checkout) .. '\n' .. program
local result = shell:run('PATH=' .. shell.quote(directory) .. ' ' .. shell.quote(uv.exepath()) .. ' -e ' .. shell.quote(program), {cwd=directory, timeout=10000})
os.remove(directory .. '/installed.txt')
os.remove(directory .. '/sh')
os.remove(directory .. '/mkdir')
assert(uv.fs_rmdir(directory))
assert(result.code == 0, result.output)
print('Installed-only patch smoke without Python PASS')
