local root = assert(require('luv').cwd())
package.path = root .. '/lua/?.lua;' .. root .. '/lua/?/init.lua;' .. package.path
require('luarocks.loader')
local uv, json = require('luv'), require('agent.util.json')
local state, core = require('agent.operational_state'), require('agent.core')
local render, observe, complete = state.render, state.observe, core.complete_logged
local shell = require('agent.util.shell')
local tmp = assert(uv.fs_mkdtemp('/tmp/lca-discrimination-XXXXXX'))
local calls = 0
-- Exercise the ordinary summary construction and capture path with a stubbed
-- transport only. Live screens use the real provider unchanged.
core.complete_logged = function(provider, request)
 calls = calls + 1
 assert(request.messages[1].text:find('syntax check passed', 1, true))
 request.on_request_body('{"offline_stub":true}')
 return {text = 'Naturally generated checkpoint stub ' .. calls, _usage = {prompt_tokens = 10, output_tokens = 10}}
end
for _, scenario in ipairs({'pending','ready'}) do
 local summary
 for _, arm in ipairs({'ledger','receipts'}) do
  state.render, state.observe = render, observe
  local dir = tmp .. '/' .. scenario .. '-' .. arm
  assert(uv.fs_mkdir(dir,493))
  assert(os.execute('cp -R ' .. shell.quote(root .. '/evals/scenarios/obligation_' .. scenario .. '/fixture') .. ' ' .. shell.quote(dir .. '/workspace')))
  assert(uv.chdir(dir .. '/workspace'))
  uv.os_setenv('EVAL_VERIFY_STATE_DIR', dir)
  uv.os_setenv('PATH', root .. '/evals/scenarios/obligation_' .. scenario .. '/environment/bin:' .. assert(os.getenv('PATH')))
  local session = require('agent.session').create({model='gpt-6-astra',reasoning_effort='high'})
  local report = dofile(root .. '/evals/obligation_discrimination.lua').setup(session,arm,scenario,dir)
  if arm == 'ledger' then summary = report.summary; assert(report.view:find('<operational%-state>'))
  else assert(report.summary == summary); assert(report.view:find('<command%-receipts>')) end
  assert(#report.events == (scenario == 'pending' and 6 or 8))
  assert(session.messages[1].text:find(summary,1,true))
  assert(uv.chdir(root))
 end
end
assert(calls == 2, 'checkpoint must be generated once per pair')
state.render, state.observe, core.complete_logged = render, observe, complete
local function remove(path)
 if uv.fs_stat(path).type ~= 'directory' then assert(uv.fs_unlink(path)); return end
 local scan = assert(uv.fs_scandir(path))
 while true do local name = uv.fs_scandir_next(scan); if not name then break end; remove(path .. '/' .. name) end
 assert(uv.fs_rmdir(path))
end
remove(tmp)
print('PASS obligation discrimination: real checks, shared generated checkpoint, ledger/receipt activation')
