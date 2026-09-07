package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path
pcall(require, 'luarocks.loader')
local json = require('agent.util.json')
local fs = require('agent.util.fs')
local path = os.tmpname()
local long_arg = string.rep('long argument é\n', 100)
local long_result = string.rep('full result 🌈\n', 1000) .. '\0END'
local long_prompt = string.rep('user prompt\n', 100)
local calls = 0
local fail_provider = false
local summarizing = false
package.loaded['agent.providers'] = { load = function() return { complete = function(request)
	if fail_provider then error('injected provider error') end
	if summarizing then return { text = 'recorded summary' } end
	calls = calls + 1
	if calls % 2 == 1 then
		return { text = '', _native_tool_calls = {
			{ name = 'read', native_call_id = 'read-' .. calls, args = { path = long_arg } },
		}, _output_items = { { type = 'function_call', call_id = 'read-' .. calls,
			name = 'read', arguments = json.encode({ path = long_arg }) } } }
	end
	assert(request.messages[#request.messages].text:find('END', 1, true))
	return { text = 'done', _native_tool_calls = {}, _usage = { prompt_tokens = 12, completion_tokens = 3 } }
end } end }
require('agent.tools.read').execute = function()
	return { is_error = false, content = long_result, summary = 'read all' }
end
local core = require('agent.core')
local sessions = require('agent.session')
core.set_transcript(path)
for _ = 1, 2 do
	local session = sessions.create({})
	session:add_user(long_prompt)
	assert(core.run_session(session).text == 'done')
end
fail_provider = true
local failed_session = sessions.create({})
failed_session:add_user('trigger error')
assert(not pcall(core.run_session, failed_session))
fail_provider, summarizing = false, true
assert(require('agent.compaction').generate_summary(failed_session.messages, nil, failed_session) == 'recorded summary')
core.set_transcript(nil)

-- Reopening closes both previous handles and starts a fresh sequence.
local other = os.tmpname()
core.set_transcript(other)
core.set_transcript(other .. '.next')
core.set_transcript(nil)
for _, name in ipairs({ other, other .. '.jsonl', other .. '.next', other .. '.next.jsonl' }) do os.remove(name) end

local records = {}
for line in fs.read_file(path .. '.jsonl'):gmatch('[^\n]+') do
	local record = json.decode(line)
	assert(record.sequence == #records + 1)
	assert(record.version == 1 and record.timestamp:match('^%d%d%d%d%-%d%d%-%d%dT.*%.%d+Z$'))
	assert(type(record.monotonic_ms) == 'number')
	records[#records + 1] = record
end
local requests, results, responses, errors = 0, 0, 0, 0
local started = {}
for _, record in ipairs(records) do
	local data = record.data
	if record.event == 'model_request' then
		requests = requests + 1
		assert(data.system_prompt and data.model)
		if record.turn_id <= 2 then assert(data.messages[1].text == long_prompt) end
	elseif record.event == 'tool_batch' then
		for _, call in ipairs(data.calls) do started[data.model_call_id .. '/' .. call.runtime_call_id] = true end
	elseif record.event == 'tool_result' then
		results = results + 1
		assert(data.args.path == long_arg and data.result.content == long_result)
		assert(data.result.is_error == false and data.model_message:find('END', 1, true))
		assert(started[data.model_call_id .. '/' .. data.call_id])
		assert(data.model_call_id == string.format('%d:1', record.turn_id))
	elseif record.event == 'model_response' then
		responses = responses + 1
	elseif record.event == 'model_error' then
		errors = errors + 1
		assert(data.error:find('injected provider error', 1, true))
	end
end
assert(requests == 6 and results == 2 and responses == 5 and errors == 1)
assert(fs.read_file(path):find('ASSISTANT RESPONSE', 1, true))
os.remove(path)
os.remove(path .. '.jsonl')

-- A failed buffered log flush must be visible, not silently discard evidence.
local uv = require('luv')
if uv.fs_stat('/dev/full') then
	assert(uv.fs_symlink('/dev/full', path .. '.jsonl'))
	local ok, err = pcall(core.set_transcript, path)
	assert(not ok and tostring(err):find('No space', 1, true), tostring(err))
	pcall(core.set_transcript, nil)
	os.remove(path .. '.jsonl')
	os.remove(path)
end
print('structured transcript preserves complete exchanges, IDs, timestamps and errors: PASS')
