#!/usr/bin/env lua
local project_dir = (arg[0]:match('^(.*)/[^/]+$') or '.') .. '/..'
package.path = project_dir .. '/lua/?.lua;' .. project_dir .. '/lua/?/init.lua;' .. package.path
pcall(require, 'luarocks.loader')
local fs = require('agent.util.fs')
local json = require('agent.util.json')
local shell = require('agent.util.shell')
local uv = require('luv')
local dir = os.tmpname(); os.remove(dir); assert(uv.fs_mkdir(dir, 448))
local tool = require('agent.tools.apply_patch')
local function apply(kind, file, diff)
 return tool.execute({ type = kind, path = file, diff = diff }, { cwd = dir })
end
local function check(value, expected) assert(value == expected, tostring(value) .. ' != ' .. tostring(expected)) end
local tests = 0
local function test(name, fn)
 local ok, err = pcall(fn)
 if not ok then error(name .. ': ' .. tostring(err)) end
 tests = tests + 1
end

test('create, multiple hunks, EOF, delete, and errors preserve bytes', function()
 assert(not apply('create_file', 'a.txt', '+first\n+middle\n+last').is_error)
 check(fs.read_file(dir .. '/a.txt'), 'first\nmiddle\nlast\n')
 assert(apply('create_file', 'a.txt', '+overwrite').is_error)
 assert(not apply('update_file', 'a.txt', '@@\n-first\n+FIRST\n middle\n@@\n-last\n+LAST\n*** End of File').is_error)
 local saved = fs.read_file(dir .. '/a.txt'); check(saved, 'FIRST\nmiddle\nLAST\n')
 assert(apply('update_file', 'a.txt', '@@\n-FIRST\n+partial\n@@\n-missing\n+no').is_error)
 check(fs.read_file(dir .. '/a.txt'), saved)
 assert(apply('update_file', 'a.txt', '@@\n-no such context\n+oops').is_error)
 check(fs.read_file(dir .. '/a.txt'), saved)
 assert(not apply('delete_file', 'a.txt').is_error)
 assert(apply('update_file', 'a.txt', '@@\n-x\n+y').is_error)
 assert(apply('delete_file', 'a.txt').is_error)
 assert(apply('bad', 'a.txt').is_error)
 assert(apply('create_file', 'bad.txt', 'not a plus line').is_error)
 assert(not pcall(fs.read_file, dir .. '/bad.txt'))
end)
test('CRLF preserved and syntax errors rejected', function()
 fs.write_file(dir .. '/crlf.txt', 'a\r\nb\r\n')
 assert(not apply('update_file', 'crlf.txt', '@@\n-a\n+A\n b').is_error)
 check(fs.read_file(dir .. '/crlf.txt'), 'A\r\nb\r\n')
 fs.write_file(dir .. '/code.py', 'x = 1\n')
 assert(apply('update_file', 'code.py', '@@\n-x = 1\n+def broken(').is_error)
 check(fs.read_file(dir .. '/code.py'), 'x = 1\n')
 assert(apply('create_file', 'bad.py', '+def broken(').is_error)
 assert(not pcall(fs.read_file, dir .. '/bad.py'))
end)
test('quoted paths, unicode, nested create and unchanged syntax errors', function()
 local name = "nested/a 'quote' λ.txt"
 assert(not apply('create_file', name, '+hello λ').is_error)
 assert(not apply('update_file', name, '@@\n-hello λ\n+goodbye λ').is_error)
 check(fs.read_file(dir .. '/' .. name), 'goodbye λ\n')
 fs.write_file(dir .. '/already_bad.py', 'def broken(\n# before\n')
 assert(not apply('update_file', 'already_bad.py', '@@\n-# before\n+# after').is_error)
 check(fs.read_file(dir .. '/already_bad.py'), 'def broken(\n# after\n')
end)
test('duplicate text is disambiguated by surrounding context', function()
 fs.write_file(dir .. '/repeated.txt', 'first\nvalue\nsecond\nvalue\n')
 assert(not apply('update_file', 'repeated.txt', '@@\n second\n-value\n+changed').is_error)
 check(fs.read_file(dir .. '/repeated.txt'), 'first\nvalue\nsecond\nchanged\n')
end)
test('patch interpretation never invokes a command executor', function()
 fs.write_file(dir .. '/no-process.txt', 'original\n')
 local result = tool.execute({type='update_file', path='no-process.txt', diff='@@\n-original\n+changed'},
  {cwd=dir, executor={run=function() error('patch parser launched a subprocess') end}})
 assert(not result.is_error, result.content)
 check(fs.read_file(dir .. '/no-process.txt'), 'changed\n')
end)
test('read failures never authorize creation or an update', function()
 local file = dir .. '/unreadable.txt'
 fs.write_file(file, 'preserve\n')
 local read = fs.read_file
 local function exercise()
  for _, returns_nil in ipairs({ false, true }) do
   fs.read_file = function(target)
    if target == file then
     if returns_nil then return nil end
     error('simulated permission failure')
    end
    return read(target)
   end
   assert(apply('create_file', 'unreadable.txt', '+overwrite').is_error)
   assert(apply('update_file', 'unreadable.txt', '@@\n-preserve\n+overwrite').is_error)
   check(read(file), 'preserve\n')
  end
 end
 local ok, err = pcall(exercise)
 fs.read_file = read
 assert(ok, err)
end)
test('stat failures and dangling symlinks do not authorize creation', function()
 local file = dir .. '/stat-denied.txt'
 local lstat = uv.fs_lstat
 uv.fs_lstat = function(target)
  if target == file then return nil, 'permission denied', 'EACCES' end
  return lstat(target)
 end
 local ok, result = pcall(apply, 'create_file', 'stat-denied.txt', '+overwrite')
 uv.fs_lstat = lstat
 assert(ok and result.is_error)
 assert(not lstat(file))
 assert(uv.fs_symlink(dir .. '/missing-target', dir .. '/dangling'))
 assert(apply('create_file', 'dangling', '+overwrite').is_error)
 assert(not uv.fs_lstat(dir .. '/missing-target'))
end)
test('changes during syntax validation survive update and create', function()
 local lint = require('agent.lint')
 local check_content = lint.check_content
 local function exercise()
  for _, kind in ipairs({ 'update_file', 'create_file' }) do
   local name = 'lint-' .. kind .. '.txt'
   if kind == 'update_file' then fs.write_file(dir .. '/' .. name, 'original\n') end
   lint.check_content = function()
    fs.write_file(dir .. '/' .. name, 'concurrent change\n')
    return nil
   end
   local diff = kind == 'create_file' and '+candidate' or '@@\n-original\n+candidate'
   assert(apply(kind, name, diff).is_error)
   check(fs.read_file(dir .. '/' .. name), 'concurrent change\n')
  end
 end
 local ok, err = pcall(exercise)
 lint.check_content = check_content
 assert(ok, err)
end)
test('creation cannot overwrite a target appearing immediately before open', function()
 local open = uv.fs_open
 local file = dir .. '/last-moment.txt'
 uv.fs_open = function(target, flags, mode)
  if target == file then
   check(flags, 'wx')
   check(mode, 438) -- preserve ordinary file-creation permissions
   fs.write_file(file, 'other writer\n')
  end
  return open(target, flags, mode)
 end
 local ok, result = pcall(apply, 'create_file', 'last-moment.txt', '+candidate')
 uv.fs_open = open
 assert(ok and result.is_error)
 check(fs.read_file(file), 'other writer\n')
end)
local codex = require('agent.providers.codex')
local deferred = { type = 'function_call', name = 'read', call_id = 'deferred_read', arguments = '{"path":"code.py"}' }
local operation = { type = 'update_file', path = 'code.py', diff = '@@\n-x = 1\n+x = 2' }
local item = { type = 'function_call', name = 'apply_patch', call_id = 'patch1', id = 'fc_1', arguments = json.encode(operation) }
-- Exercise real dispatch and a subsequent provider request without network calls.
local registry = require('agent.tool_registry')
local calls = 0
package.loaded['agent.core'] = nil
package.loaded['agent.providers'] = { load = function() return { complete = function(request)
 calls = calls + 1
 if calls == 1 then
  return { text = '', _output_items = {item, deferred}, _native_tool_calls = assert(codex._native_tool_calls({item, deferred})), native_tool_calling = true }
 end
 check(calls, 2)
 local body = json.decode(codex._request_body(request))
 for _, replay in ipairs(body.input) do assert(replay.call_id ~= 'deferred_read', 'deferred read must not be replayed') end
 local output
 for _, replay in ipairs(body.input) do if replay.type == 'function_call_output' then output = replay end end
 assert(output, 'patch result missing')
 check(output.type, 'function_call_output'); assert(output.output:find('Patched code.py', 1, true))
 return { text = 'done', _native_tool_calls = {}, native_tool_calling = true }
end } end }
test('core round trip executes patch and retains function result metadata', function()
 local session = require('agent.session').create({})
 session.cwd = dir
 session:add_user('Change x to 2 in code.py')
 assert(registry.get('apply_patch') and not registry.get('edit'))
 local result = require('agent.core').run_session(session)
 check(result.text, 'done'); check(calls, 2)
 check(fs.read_file(dir .. '/code.py'), 'x = 2\n')
end)
os.execute('rm -rf ' .. shell.quote(dir))
print(tostring(tests) .. ' patch interface tests passed')
