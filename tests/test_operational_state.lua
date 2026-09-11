local root = (arg[0]:match("^(.*)/[^/]+$") or ".") .. "/.."
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
pcall(require, "luarocks.loader")
local state = require("agent.operational_state")
local sessions = require("agent.session")
local compaction = require("agent.compaction")
local uv = require("luv")
local tmp = assert(uv.fs_mkdtemp("/tmp/lca-obligations-XXXXXX"))
local session = sessions.create({})
session.cwd = tmp
local next_id = 0
local function start(name, args)
	next_id = next_id + 1
	local event = { phase = "start", name = name, args = args, call_id = "test-" .. next_id }
	state.observe(session, event)
	return event
end
local function finish(event, failed)
	event.phase = "finish"
	event.result = { is_error = failed, summary = failed and "exit 1: regression failed" or "exit 0" }
	state.observe(session, event)
end
local function contains(text, value) assert(text:find(value, 1, true), value .. " missing from " .. text) end

-- Preserve the pass and the later edit separately, without classifying freshness.
finish(start("run", {command = "make test"}), false)
contains(state.render(session), '"outcome":"succeeded"')
finish(start("write", {path = "app.lua", content = string.rep("large payload", 1000)}), false)
contains(state.render(session), '"name":"write"')
assert(not state.render(session):find("large payload", 1, true))
local failed = start("run", {command = "make test"})
finish(failed, true)
finish(start("run", {command = "printf unrelated"}), false)
assert(next(session.operational_state.failures))
session.plan = {{step = "Run integration checks", status = "pending"}}
start("run", {command = "slow-check"})
session:add_user("Fix the bug. Do not change the public API.")
session:add_assistant("The proposed API rewrite was rejected because callers depend on it.")

-- Even an inadequate generated narrative cannot erase separately held facts.
local original = compaction.generate_summary
compaction.generate_summary = function() return "Everything is done." end
local ok, err = pcall(function()
	assert(compaction.compact(session, {force = true}))
	assert(compaction.compact(session, {force = true}))
end)
compaction.generate_summary = original
assert(ok, err)
local prompt = state.request_messages(session)[1].text
local stored_count = #session.messages
local base_prompt = session:get_system_prompt()
local requests = state.request_messages(session)
assert(#session.messages == stored_count and #requests == stored_count)
assert(requests[1] == session.messages[1], "historical prefix must remain unchanged")
assert(not base_prompt:find("<operational-state>", 1, true), "changing state must not invalidate the system prompt prefix")
assert(session:estimated_model_input_tokens() >= state.tokens(session))
contains(prompt, '"outcome":"failed"')
contains(prompt, "Run integration checks")
contains(prompt, "No completion observed")
contains(prompt, "slow-check")
contains(prompt, '"name":"write"')
local path = tmp .. "/session.json"
assert(session:save(path))
local restored = sessions.create({})
assert(restored:load(path))
assert(restored.operational_state.resumed)
contains(state.render(restored), "Session restored")
local resumed = state.request_messages(restored)
contains(resumed[#resumed].text, "regression failed")
contains(resumed[#resumed].text, "Run integration checks")
local resumed_count = #resumed
state.request_messages(restored)
assert(#restored.messages == resumed_count, "resume snapshot must be inserted once")
restored:clear()
assert(restored.operational_state == nil)

-- Identical retry retires the failure, duplicate completions do nothing.
finish(start("run", {command = "make test"}), false)
assert(next(session.operational_state.failures) == nil)
local count = #session.operational_state.commands
state.observe(session, failed)
assert(#session.operational_state.commands == count)

-- Preserve event ordering across overlapping calls without inventing validity.
session = sessions.create({})
local edit = start("edit", {path = "app.lua"})
local check = start("run", {command = "make test"})
finish(edit, false); finish(check, false)
local edit_receipt = session.operational_state.changes[1]
local check_receipt = session.operational_state.commands[1]
assert(edit_receipt.evidence < check_receipt.evidence)
assert(check_receipt.evidence < edit_receipt.completed_at)
assert(edit_receipt.completed_at < check_receipt.completed_at)
local summary_prompt = compaction._build_summary_prompt({}, "old", session)
contains(summary_prompt, "user non-goals")
contains(summary_prompt, "rejected alternative")
contains(summary_prompt, "historical evidence")

-- Running jobs remain visible across compaction; completion is an observation,
-- not automatic verification. Other sessions' completed jobs are not imported.
local jobs = require("agent.jobs")
local original_list = jobs.list
jobs.list = function() return {
	{id = "job_active", command = "integration-check", status = "running", alive = true, stdout = "/tmp/check.out"},
	{id = "job_unrelated", command = "old-check", status = "exited", exit_code = 0},
} end
state.refresh_jobs(session)
contains(state.render(session), "job_active")
assert(not state.render(session):find("job_unrelated", 1, true))
contains(state.render(session), '"status":"running"')
jobs.list = function() return {{id = "job_active", command = "integration-check", status = "exited", exit_code = 1}} end
state.refresh_jobs(session)
assert(session.operational_state.jobs.job_active.status == "exited")
jobs.list = original_list
contains(state.render(session), '"exit_code":1')

-- Runtime fallback call IDs can repeat across turns without losing obligations.
session = sessions.create({})
state.begin_turn(session)
state.observe(session, {phase = "start", name = "run", call_id = "tool-1", args = {command = "old"}})
state.begin_turn(session)
state.observe(session, {phase = "start", name = "run", call_id = "tool-1", args = {command = "new"}})
contains(state.render(session), '"command":"old"')
contains(state.render(session), '"command":"new"')
-- Replay the exact Ready failure captured by the live screen. The same facts
-- reach the continuing agent and the summarizer, without stale/unresolved labels.
local json = require("agent.util.json")
local fixture = assert(io.open(root .. "/tests/fixtures/operational-ready.json"))
local captured = json.decode(fixture:read("*a")); fixture:close()
session = sessions.create({})
for _, event in ipairs(captured.events) do state.observe(session, event) end
local rendered = state.render(session)
contains(rendered, '"outcome":"failed"')
contains(rendered, '"outcome":"succeeded"')
contains(rendered, '"timeout":20000')
contains(rendered, 'syntax check passed')
contains(rendered, 'Ran 3 tests')
assert(not rendered:find('stale:', 1, true))
assert(not rendered:find('Failure without', 1, true))
assert(not rendered:find('"revision"', 1, true))
-- Failure retained due to different arguments, but emitted only once in order.
local _, failure_count = rendered:gsub('"outcome":"failed"', '')
assert(failure_count == 1)
local summary = compaction._build_summary_prompt({}, nil, session)
contains(summary, rendered)
contains(summary, 'Read-only inspection alone does not invalidate a passing check')
-- Old persisted inferred metadata must not reappear in either consumer.
session.operational_state.revision = 999
session.operational_state.commands[1].revision = 1
session.operational_state.commands[1].overlapping_mutation = true
assert(state.render(session) == rendered)
-- Recent receipts may roll off, but the original failed outcome remains.
for i = 1, 25 do finish(start("run", {command = "unrelated-" .. i}), false) end
contains(state.render(session), 'AssertionError: 1100 != 1000')

assert(os.remove(path)); assert(uv.fs_rmdir(tmp))
print("PASS durable obligations: compaction, resume, retries, freshness, overlap and summary contract")
