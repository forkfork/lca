local root = (arg[0]:match("^(.*)/[^/]+$") or ".") .. "/.."
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
require("luarocks.loader")
local uv = require("luv")
local json = require("agent.util.json")
local pilot = dofile(root .. "/evals/state_context.lua")
local tmp = assert(uv.fs_mkdtemp("/tmp/lca-state-test-XXXXXX"))
local valid = '<agent_state>{"goal":"fix","current_beliefs":[],"completed":[],"open_questions":[],"planned_next":[],"constraints":[],"rejected":[],"verification":[]}</agent_state>'
assert(not pcall(pilot.parse, "missing"))
assert(not pcall(pilot.parse, '<agent_state>{"goal":"fix"}</agent_state>'))
assert(not pcall(pilot.parse, valid:gsub('"fix"', '"' .. string.rep("x", 8000) .. '"')))
for _, mode in ipairs({ "normal", "state_only", "state_history" }) do
	local session = { messages = {
		{ role = "user", text = "original task" },
		{ role = "assistant", text = "obsolete reasoning", provider_items = {{ type = "reasoning", encrypted_content = "OLD_SECRET" }} },
		{ role = "user", text = "correction" },
	}, get_system_prompt = function() return "system" end }
	local p = pilot.new(mode, session, tmp)
	p.before_step(session)
	p.on_request({ system_prompt = session.system_prompt, messages = session.messages })
	p.on_response({ text = valid .. "answer", _usage = { prompt_tokens = 10, output_tokens = 20 } })
	session.messages[#session.messages + 1] = { role = "assistant", text = "new reasoning", provider_items = {
		{ type = "reasoning", encrypted_content = "NEW_SECRET" },
		{ type = "function_call", call_id = "call1", name = "read", arguments = '{"path":"x"}' },
	} }
	session.messages[#session.messages + 1] = { role = "user", tool_name = "read", native_call_id = "call1", text = "first evidence" }
	p.before_step(session)
	local payload = json.encode(session.messages)
	assert(payload:find("original task") and payload:find("correction") and payload:find("first evidence"))
	if mode == "state_only" then
		assert(not payload:find("SECRET") and not payload:find("reasoning"))
		assert(payload:find("call1")) -- native call/output pairing survives
	else
		assert(payload:find("OLD_SECRET"))
	end
	p.on_request({ system_prompt = session.system_prompt, messages = session.messages })
	p.on_response({ text = valid })
	session.messages[#session.messages + 1] = { role = "user", tool_name = "read", text = "second evidence" }
	p.before_step(session)
	payload = json.encode(session.messages)
	assert(payload:find("second evidence"))
	if mode == "state_only" then assert(not payload:find("first evidence") and not payload:find("call1")) end
	assert(#p.usage == 1)
	local f = assert(io.open(tmp .. "/observation-0001.json")); local archived = f:read("*a"); f:close()
	assert(archived:find("first evidence") and archived:find("NEW_SECRET"))
	if mode ~= "normal" then
		assert(p.updates == 2)
		assert(not pcall(p.on_response, { text = "missing state", _usage = { output_tokens = 5 } }))
		assert(#p.errors == 1 and #p.usage == 2)
	end
end
-- Exercise the real core hook ordering and provider serialization boundary.
local calls = 0
local fixture = dofile(root .. "/tests/native_fixture.lua")
package.loaded["agent.providers"] = { load = function() return { complete = function(request)
	calls = calls + 1
	local payload = json.encode(request.messages)
	assert(not payload:find("OLD_SECRET"))
	if calls == 3 then
		assert(not payload:find("Agent Notes"), "older read result leaked through core")
		assert(payload:find("LCATUI_ROCKSPEC"), "latest read result was lost")
		return { text = valid .. "done", _native_tool_calls = {} }
	end
	local path = calls == 1 and "AGENTS.md" or "Makefile"
	return fixture.response({ text = valid .. '<tool_call name="read">{"path":"' .. path .. '"}</tool_call>',
		_output_items = {{ type = "reasoning", encrypted_content = "OLD_SECRET" }} })
end } end }
local session = require("agent.session").create({})
session:add_user("Inspect AGENTS.md and then Makefile")
local p = pilot.new("state_only", session, tmp)
local result = require("agent.core").run_session(session, nil, nil, nil, nil, p)
assert(result.text == "done" and calls == 3 and p.updates == 3)
print("state-context protocol, isolation, archives, pairing, correction and failed-call accounting: PASS")
