local root = assert(require('luv').cwd())
package.path = root .. '/lua/?.lua;' .. root .. '/lua/?/init.lua;' .. package.path
require('luarocks.loader')
local json = require('agent.util.json')
local state = require('agent.operational_state')
local compaction = require('agent.compaction')
local session = require('agent.session').create({})
local provider = require('agent.providers.codex')
local function observe(command, id)
 local args = {command = command}
 state.observe(session, {phase='start', name='run', args=args, call_id=id})
 state.observe(session, {phase='finish', name='run', args=args, call_id=id, result={summary='exit 0',content='check passed'}})
end
local function body()
 return json.decode(provider._request_body({model='gpt-6-astra',system_prompt='Test',tool_scope='none',messages=state.request_messages(session)}))
end
session:add_user('Verify the change.')
observe('check-before-compaction', 'one')
-- Ordinary history must not acquire a changing synthetic tail.
assert(#state.request_messages(session) == 1)
local original = compaction.generate_summary
compaction.generate_summary = function() return 'Verification remains relevant.' end
assert(compaction.compact(session,{force=true}))
local first = body()
assert(session.messages[1].text:find('check-before-compaction',1,true))
local frozen = session.messages[1].text
session:add_assistant('I will inspect the result.')
session:add_user('Inspection found no changes.')
observe('inspect-after-compaction','two')
local second = body()
for i, item in ipairs(first.input) do
 assert(json.encode(item) == json.encode(second.input[i]), 'serialized prior request changed at item ' .. i)
end
assert(session.messages[1].text == frozen)
assert(state.tokens(session) == 0, 'persisted snapshot must not be counted twice')
assert(compaction.compact(session,{force=true}))
assert(session.messages[1].text:find('inspect-after-compaction',1,true))
local _, snapshots = session.messages[1].text:gsub('<operational%-state>','')
assert(snapshots == 1, 'compaction must replace the checkpoint rather than accumulate snapshots')
compaction.generate_summary = original
print('PASS operational cache: immutable serialized prefix, updated compaction snapshot, no transient tail')
