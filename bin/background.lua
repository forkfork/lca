#!/usr/bin/env lua
-- Installed launcher for the optional host-side MicroVM client.
local quote=function(s) return "'"..tostring(s):gsub("'", "'\\''").."'" end
local dir=arg[0]:match('^(.*)/[^/]+$') or '.'
local client=dir..'/../microvm/handoff.py'
if arg[1]=='gc' then client=dir..'/../microvm/image_gc.py' end
local file=io.open(client)
if not file then io.stderr:write('MicroVM client is missing; reinstall LCA with make local\n');os.exit(1) end
file:close()
-- Preserve the launcher's resolved LuaRocks paths for the local remote TUI.
local parts={'env','LUA_PATH='..quote(package.path),'LUA_CPATH='..quote(package.cpath),'python3',quote(client)}
for _,value in ipairs(arg) do parts[#parts+1]=quote(value) end
local ok,_,code=os.execute(table.concat(parts,' '))
os.exit(ok and 0 or code or 1)
