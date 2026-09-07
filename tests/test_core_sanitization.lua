#!/usr/bin/env lua

local script_dir = arg[0]:match("^(.*)/[^/]+$") or "."
local project_dir = script_dir .. "/.."
package.path = project_dir .. "/lua/?.lua;" .. project_dir .. "/lua/?/init.lua;" .. project_dir .. "/lua/?/?.lua;" .. package.path
pcall(require, "luarocks.loader")

local provider_response = table.concat({
	"Before",
	'<tool_result name="run" status="ok">',
	"hidden tool output",
	"</tool_result>",
	"After",
}, "\n")
local last_request = nil
local summary_request = nil
local provider_calls = 0
local fake_cancelled = false
local native_fixture = dofile(project_dir .. "/tests/native_fixture.lua")

package.loaded["agent.providers"] = {
	load = function()
		return {
				complete = function(request)
					provider_calls = provider_calls + 1
					last_request = request
					if tostring(request.system_prompt or ""):find("context summarization assistant", 1, true) then
						summary_request = request
					end
					if type(provider_response) == "table" then
						if provider_response._cancel_during_complete then
							fake_cancelled = true
						end
						return native_fixture.response(provider_response)
					end
					if type(provider_response) == "function" then
					local value = provider_response(request)
					return native_fixture.response(value)
				end
				return native_fixture.response(provider_response)
			end,
		}
	end,
}

local core = require("agent.core")
local session_module = require("agent.session")
local read_tool = require("agent.tools.read")

local passed = 0
local failed = 0

local function green(s) return "\27[32m" .. s .. "\27[0m" end
local function red(s) return "\27[31m" .. s .. "\27[0m" end
local function dim(s) return "\27[2m" .. s .. "\27[0m" end

local function test(name, fn)
	io.write("  " .. name .. " ")
	io.flush()
	local ok, err = pcall(fn)
	if ok then
		passed = passed + 1
		io.write(green("PASS") .. "\n")
	else
		failed = failed + 1
		io.write(red("FAIL") .. " (" .. tostring(err):sub(1, 100) .. ")\n")
	end
end

io.write("\n" .. dim("═══ Core Sanitization Tests ═══") .. "\n\n")

test("forwards the session tool scope to the provider", function()
	provider_response = "scoped response"
	last_request = nil
	local session = session_module.create({ tool_scope = "web_only" })
	session.cwd = project_dir
	session:add_user("research this")

	local result = core.run_session(session, nil, nil, nil)
	if result.text ~= "scoped response" then
		error("unexpected result: " .. tostring(result.text))
	end
	if not last_request or last_request.tool_scope ~= "web_only" then
		error("provider did not receive web_only tool scope")
	end
end)

test("does not execute retired delegate calls", function()
	provider_calls = 0
	provider_response = '<tool_call name="delegate_readonly">\n{"task":"Inspect","paths":["README.md"]}\n</tool_call>'
	local session = session_module.create({})
	session.cwd = project_dir
	session:add_user("try a disabled tool")
	local result = core.run_session(session, nil, nil, nil)
	for _, event in ipairs(result.events or {}) do
		if event.name == "delegate_readonly" then error("disabled delegate executed") end
	end
end)

test("strips model-emitted tool_result tags from assistant text", function()
	provider_response = table.concat({
		"Before",
		'<tool_result name="run" status="ok">',
		"hidden tool output",
		"</tool_result>",
		"After",
	}, "\n")
	local session = session_module.create({})
	session.cwd = project_dir
	session:add_user("trigger")

	local result = core.run_session(session, nil, nil, nil)
	if result.text:find("<tool_result", 1, true) then
		error("assistant text still contains tool_result: " .. result.text)
	end
	if result.text:find("hidden tool output", 1, true) then
		error("assistant text still contains tool output: " .. result.text)
	end
	if not result.text:find("Before", 1, true) or not result.text:find("After", 1, true) then
		error("assistant text lost surrounding text: " .. result.text)
	end
end)

test("normal plans close with the final answer without a ceremonial update", function()
	provider_calls = 0
	provider_response = function()
		if provider_calls == 1 then
			return table.concat({
				'<tool_call name="update_plan">',
				'{"plan":[{"step":"Make the change","status":"in_progress"},{"step":"Verify it","status":"pending"}]}',
				"</tool_call>",
			}, "\n")
		end
		return "implemented and verified"
	end

	local session = session_module.create({})
	session.cwd = project_dir
	session:add_user("do substantial work")
	local result = core.run_session(session, nil, nil, nil)

	if result.text ~= "implemented and verified" then
		error("unexpected result: " .. tostring(result.text))
	end
	if provider_calls ~= 2 then
		error("expected one plan round and one final round, got " .. tostring(provider_calls))
	end
	if session.plan ~= nil then
		error("normal plan remained active after the final answer")
	end
end)

test("research builds receive one evidence audit before completion", function()
	provider_calls = 0
	provider_response = function(request)
		if provider_calls == 1 then
			return table.concat({
				'<tool_call name="write">',
				'{"path":"completion-audit-fixture.txt","content":"built\\n"}',
				"</tool_call>",
			}, "\n")
		elseif provider_calls == 2 then
			return "Built a complete demo."
		end
		local messages = {}
		for _, message in ipairs(request.messages or {}) do
			messages[#messages + 1] = tostring(message.text or "")
		end
		if not table.concat(messages, "\n"):find("Harness completion audit", 1, true) then
			error("completion audit was not sent to the model")
		end
		return "Locally written; external deployment was not exercised."
	end

	local session = session_module.create({})
	session.cwd = project_dir .. "/tests/tmp"
	os.execute("mkdir -p " .. string.format("%q", session.cwd))
	session:add_user("search current documentation then build a demo")
	local result = core.run_session(session, nil, nil, nil)

	if provider_calls ~= 3 then
		error("expected one completion audit round, got " .. tostring(provider_calls) .. " provider calls")
	end
	if result.text ~= "Locally written; external deployment was not exercised." then
		error("unexpected audited result: " .. tostring(result.text))
	end
	local file = io.open(session.cwd .. "/completion-audit-fixture.txt", "r")
	if file then file:close() os.remove(session.cwd .. "/completion-audit-fixture.txt") end
end)

test("completion audit blocks redundant workspace inventory", function()
	provider_calls = 0
	provider_response = function(request)
		if provider_calls == 1 then
			return '<tool_call name="write">\n{"path":"audit-inventory-fixture.txt","content":"built\\n"}\n</tool_call>'
		elseif provider_calls == 2 then
			return "Built a complete demo."
		elseif provider_calls == 3 then
			return '<tool_call name="ls">\n{"path":"."}\n</tool_call>'
		end
		local joined = {}
		for _, message in ipairs(request.messages or {}) do
			joined[#joined + 1] = tostring(message.text or "")
		end
		if not table.concat(joined, "\n"):find("Completion%-audit inventory guard") then
			error("blocked inventory was not surfaced")
		end
		return "Proven locally; external deployment was not exercised."
	end

	local session = session_module.create({})
	session.cwd = project_dir .. "/tests/tmp"
	os.execute("mkdir -p " .. string.format("%q", session.cwd))
	session:add_user("research requirements then build a demo")
	local result = core.run_session(session, nil, nil, nil)
	if result.text ~= "Proven locally; external deployment was not exercised." then error(result.text) end
	for _, event in ipairs(result.events) do
		if event.name == "ls" or event.name == "find" then
			error("completion audit executed redundant inventory")
		end
	end
	os.remove(session.cwd .. "/audit-inventory-fixture.txt")
end)

test("turn usage aggregates every model call", function()
	provider_calls = 0
	provider_response = function()
		if provider_calls == 1 then
			return {
				text = '<tool_call name="update_plan">\n{"plan":[{"step":"Do it","status":"in_progress"}]}\n</tool_call>',
				_usage = { prompt_tokens = 100, cached_tokens = 50, cache_available = true, output_tokens = 10, total_tokens = 110 },
			}
		end
		return {
			text = "done",
			_usage = { prompt_tokens = 200, cached_tokens = 100, cache_available = true, output_tokens = 5, total_tokens = 205 },
		}
	end
	local session = session_module.create({})
	session.cwd = project_dir
	session:add_user("track the whole turn")
	local result = core.run_session(session, nil, nil, nil)
	if result._usage.prompt_tokens ~= 200 then error("last-call usage changed") end
	if result._turn_usage.prompt_tokens ~= 300 then error("prompt usage was not aggregated") end
	if result._turn_usage.cached_tokens ~= 150 then error("cached usage was not aggregated") end
	if result._turn_usage.output_tokens ~= 15 or result._turn_usage.total_tokens ~= 315 then error("total usage was not aggregated") end
	if result._turn_usage.model_calls ~= 2 or result._turn_usage.usage_calls ~= 2 then error("model-call count was not aggregated") end
	if result._turn_usage.cache_available ~= true then error("aggregate cache telemetry should be available") end
end)

test("tool events retain model-call batch and emission identity", function()
	provider_calls = 0
	provider_response = function()
		if provider_calls == 1 then
			return '<tool_call name="read">\n{"path":"README.md","offset":1,"limit":2}\n</tool_call>'
		end
		return "done"
	end
	local session = session_module.create({})
	session.cwd = project_dir
	session:add_user("inspect two lines")
	local result = core.run_session(session, nil, nil, nil)
	if #result.events ~= 1 then error("expected one read finish event") end
	local event = result.events[1]
	if event.model_call_id ~= 1 or event.batch_id ~= 1 or event.model_index ~= 1 then
		error("tool event lost authoritative batch identity")
	end
end)

test("stores only deduped executed tool calls in assistant history", function()
	provider_calls = 0
	provider_response = table.concat({
		'<tool_call name="ls">',
		'{"path":"."}',
		"</tool_call>",
		'<tool_call name="ls">',
		'{"path":"."}',
		"</tool_call>",
		'<tool_call name="find">',
		'{"path":".","maxDepth":2}',
		"</tool_call>",
		'<tool_call name="find">',
		'{"path":".","maxDepth":2}',
		"</tool_call>",
	}, "\n")

	local session = session_module.create({})
	session.cwd = project_dir
	session:add_user("trigger duplicate tools")

	local result = core.run_session(session, nil, nil, nil)
	-- Expected: the stub provider keeps asking for tools until the budget
	-- path returns. This test is about recorded history, not final text.
	local _ = result
	local assistant_text = ""
	for _, message in ipairs(session.messages) do
		if message.role == "assistant" then
			assistant_text = message.text or ""
			break
		end
	end
	local count = 0
	for _ in assistant_text:gmatch("<tool_call") do
		count = count + 1
	end
	if count ~= 2 then
		error("expected only 2 unique executed tool calls in history, got " .. tostring(count) .. ": " .. assistant_text)
	end
end)

test("blank workspace executes only one initial inventory call", function()
	provider_calls = 0
	local blank_dir = project_dir .. "/tests/tmp/blank-inventory"
	os.execute("mkdir -p " .. string.format("%q", blank_dir))
	provider_response = function(request)
		if provider_calls == 1 then
			return table.concat({
				'<tool_call name="ls">',
				'{"path":"."}',
				"</tool_call>",
				'<tool_call name="find">',
				'{"path":".","maxDepth":2}',
				"</tool_call>",
				'<tool_call name="grep">',
				'{"path":".","pattern":"AgentCore"}',
				"</tool_call>",
			}, "\n")
		end
		local joined = {}
		for _, message in ipairs(request.messages or {}) do
			joined[#joined + 1] = tostring(message.text or "")
		end
		if not table.concat(joined, "\n"):find("Blank%-workspace inventory guard") then
			error("blank-workspace guard was not surfaced")
		end
		return "continued after one inventory call"
	end

	local session = session_module.create({})
	session.cwd = blank_dir
	session:add_user("build a new project")
	local result = core.run_session(session, nil, nil, nil)
	if result.text ~= "continued after one inventory call" then error(result.text) end
	if #result.events == 0 then error("missing executed inventory event") end
	for _, event in ipairs(result.events) do
		if event.name ~= "ls" or event.model_index ~= 1 then
			error("a deferred inventory tool executed")
		end
	end
end)

test("batch cap is surfaced to next model turn", function()
	provider_calls = 0
	local first_response = {}
	for i = 1, 12 do
		first_response[#first_response + 1] = '<tool_call name="job_stop">'
		first_response[#first_response + 1] = '{"id":"job-' .. tostring(i) .. '"}'
		first_response[#first_response + 1] = "</tool_call>"
	end
	provider_response = function(request)
		for _, message in ipairs(request.messages or {}) do
			if tostring(message.text or ""):find("Batch cap reached", 1, true) then
				return "done after cap"
			end
		end
		return table.concat(first_response, "\n")
	end

	local session = session_module.create({})
	session.cwd = project_dir
	session:add_user("trigger too many tools")
	local result = core.run_session(session, nil, nil, nil)

	if result.text ~= "done after cap" then
		error("unexpected result: " .. tostring(result.text))
	end
	if provider_calls ~= 2 then
		error("expected 2 provider calls, got " .. tostring(provider_calls))
	end
	local found = false
	for _, message in ipairs(session.messages) do
		if tostring(message.text or ""):find("only the first 10 tool calls ran", 1, true) then
			found = true
			break
		end
	end
	if not found then
		error("missing batch cap steering message")
	end
end)

test("duplicate-heavy tool batch is surfaced to next model turn", function()
	provider_calls = 0
	provider_response = function(request)
		for _, message in ipairs(request.messages or {}) do
			if tostring(message.text or ""):find("Duplicate tool%-call guard", 1, false) then
				return "done after duplicate guard"
			end
		end
		return table.concat({
			'<tool_call name="ls">',
			'{"path":"."}',
			"</tool_call>",
			'<tool_call name="ls">',
			'{"path":"."}',
			"</tool_call>",
			'<tool_call name="ls">',
			'{"path":"."}',
			"</tool_call>",
		}, "\n")
	end

	local session = session_module.create({})
	session.cwd = project_dir
	session:add_user("trigger duplicate batch")
	local result = core.run_session(session, nil, nil, nil)

	if result.text ~= "done after duplicate guard" then
		error("unexpected result: " .. tostring(result.text))
	end
end)

test("context reserve compacts completed history between tool calls", function()
	provider_calls = 0
	summary_request = nil
	local main_calls = 0
	provider_response = function(request)
		if tostring(request.system_prompt or ""):find("context summarization assistant", 1, true) then
			summary_request = request
			return "## Goal\nHonor the latest correction."
		end
		main_calls = main_calls + 1
		if main_calls == 1 then
			return table.concat({
				'<tool_call name="ls">',
				'{"path":"."}',
				"</tool_call>",
			}, "\n")
		end
		return "done after intra-turn compaction"
	end

	local session = session_module.create({
		context_compaction_threshold = 50,
		compaction_keep_recent_tokens = 1,
	})
	session.cwd = project_dir
	session:add_user("old request")
	session:add_assistant("old answer")
	session:add_user("latest correction")
	session.estimated_model_input_tokens_usage_aware = function(self)
		return #self.messages <= 3 and 10 or 100
	end

	local result = core.run_session(session, nil, nil, nil)
	if result.text ~= "done after intra-turn compaction" then
		error("unexpected result: " .. tostring(result.text))
	end
	if not summary_request then
		error("expected an intra-turn summary request")
	end
	if not tostring(summary_request.messages[1].text):find("old request", 1, true) then
		error("completed history was not sent to summarization")
	end
	local joined = {}
	for _, message in ipairs(last_request.messages or {}) do
		joined[#joined + 1] = tostring(message.text or "")
	end
	joined = table.concat(joined, "\n")
	if not joined:find("latest correction", 1, true) or not joined:find('<tool_result name="ls"', 1, true) then
		error("active turn was split during compaction")
	end
end)

test("later read cannot invalidate an earlier mutation in one response", function()
	provider_calls = 0
	local target = os.tmpname() .. "_dependency_prefix.txt"
	local file = assert(io.open(target, "w"))
	file:write("old\n")
	file:close()
	local tag = read_tool.line_tag(1, "old")
	provider_response = function(request)
		for _, message in ipairs(request.messages or {}) do
			if tostring(message.text or ""):find("Tool dependency boundary reached", 1, true) then
				return "done after dependency boundary"
			end
		end
		return table.concat({
			'<tool_call name="edit">',
			'{"path":"' .. target .. '","start_line":1,"start_tag":"' .. tag .. '","end_line":1,"end_tag":"' .. tag .. '"}',
			"new",
			"</tool_call>",
			'<tool_call name="read">',
			'{"path":"' .. target .. '"}',
			"</tool_call>",
		}, "\n")
	end

	local session = session_module.create({})
	session.cwd = project_dir
	session:add_user("edit then inspect")
	local result = core.run_session(session, nil, nil, nil)
	local updated_file = assert(io.open(target, "r"))
	local updated = updated_file:read("*a")
	updated_file:close()
	os.remove(target)

	if result.text ~= "done after dependency boundary" then
		error("unexpected result: " .. tostring(result.text))
	end
	if not updated:match("^new\n*$") then
		error("earlier mutation was not executed: " .. tostring(updated))
	end
	local first_assistant = session.messages[2] and session.messages[2].text or ""
	if first_assistant:find('<tool_call name="read">', 1, true) then
		error("deferred read was stored as executed assistant history")
	end
end)

test("read-only batch cap steers away from broad inventory", function()
	provider_calls = 0
	local first_response = {}
	for i = 1, 12 do
		first_response[#first_response + 1] = '<tool_call name="ls">'
		first_response[#first_response + 1] = '{"path":"missing-' .. tostring(i) .. '"}'
		first_response[#first_response + 1] = "</tool_call>"
	end
	provider_response = function(request)
		for _, message in ipairs(request.messages or {}) do
			if tostring(message.text or ""):find("Read%-only batch cap reached") then
				return "done after read-only cap"
			end
		end
		return table.concat(first_response, "\n")
	end

	local session = session_module.create({})
	session.cwd = project_dir
	session:add_user("trigger too much inventory")
	local result = core.run_session(session, nil, nil, nil)

	if result.text ~= "done after read-only cap" then
		error("unexpected result: " .. tostring(result.text))
	end
	local found = false
	for _, message in ipairs(session.messages) do
		local text = tostring(message.text or "")
		if text:find("only the first 7 inspection calls ran", 1, true)
			and text:find("Stop broad workspace inventory", 1, true)
		then
			found = true
			break
		end
	end
	if not found then
		error("missing read-only batch cap steering message")
	end
end)

test("read-only batch cap can be overridden without changing the general cap", function()
	provider_calls = 0
	local first_response = {}
	for i = 1, 7 do
		first_response[#first_response + 1] = '<tool_call name="ls">'
		first_response[#first_response + 1] = '{"path":"missing-custom-' .. tostring(i) .. '"}'
		first_response[#first_response + 1] = "</tool_call>"
	end
	provider_response = function(request)
		for _, message in ipairs(request.messages or {}) do
			if tostring(message.text or ""):find("only the first 4 inspection calls ran", 1, true) then
				return "done after custom read-only cap"
			end
		end
		return table.concat(first_response, "\n")
	end

	local session = session_module.create({ read_only_batch_cap = 4 })
	session.cwd = project_dir
	session:add_user("trigger custom inventory cap")
	local result = core.run_session(session, nil, nil, nil)

	if result.text ~= "done after custom read-only cap" then
		error("unexpected result: " .. tostring(result.text))
	end
end)

test("thinking tool count reports last batch not cumulative total", function()
	provider_calls = 0
	provider_response = function()
		if provider_calls == 1 then
			return table.concat({
				'<tool_call name="ls">',
				'{"path":"missing-a"}',
				"</tool_call>",
				'<tool_call name="ls">',
				'{"path":"missing-b"}',
				"</tool_call>",
			}, "\n")
		elseif provider_calls == 2 then
			return table.concat({
				'<tool_call name="ls">',
				'{"path":"missing-c"}',
				"</tool_call>",
			}, "\n")
		end
		return "done"
	end

	local session = session_module.create({})
	session.cwd = project_dir
	session:add_user("trigger two batches")
	local tool_counts = {}
	local total_counts = {}
	local result = core.run_session(session, nil, nil, function(info)
		if not info.status then
			tool_counts[#tool_counts + 1] = info.tools
			total_counts[#total_counts + 1] = info.total_tools
		end
	end)

	if result.text ~= "done" then
		error("unexpected result: " .. tostring(result.text))
	end
	if tool_counts[1] ~= 2 or tool_counts[2] ~= 1 then
		error("expected last-batch counts 2,1 got " .. tostring(tool_counts[1]) .. "," .. tostring(tool_counts[2]))
	end
	if total_counts[1] ~= 2 or total_counts[2] ~= 3 then
		error("expected cumulative counts 2,3 got " .. tostring(total_counts[1]) .. "," .. tostring(total_counts[2]))
	end
end)

test("task prompt has no autonomous mode policy", function()
	provider_calls = 0
	provider_response = "normal done"
	last_request = nil

	local session = session_module.create({})
	session.cwd = project_dir
	session:add_user("trigger normal mode")

	local result = core.run_session(session, nil, nil, nil)
	if result.text ~= "normal done" then
		error("unexpected result: " .. tostring(result.text))
	end
	if not last_request or type(last_request.system_prompt) ~= "string" then
		error("provider request was not captured")
	end
	if last_request.system_prompt:find("## Mode", 1, true) then
		error("normal mode should not include a mode policy")
	end
	if #last_request.messages ~= 1 then
		error("mode policy should not be appended as a session message")
	end
end)

test("completed plans return normally without autonomous checkpoints", function()
	provider_calls = 0
	summary_request = nil
	provider_response = function()
		if provider_calls == 1 then
			return '<tool_call name="update_plan">\n{"plan":[{"step":"Requested work","status":"completed"}]}\n</tool_call>'
		end
		return "done"
	end
	local session = session_module.create({})
	session.cwd = project_dir
	session:add_user("finish the requested work")
	local result = core.run_session(session, nil, nil, nil)
	assert(result.text == "done")
	assert(provider_calls == 2)
	assert(summary_request == nil)
	assert(session.plan == nil)
	assert(session.journey == nil)
end)
test("false tool protocol apology is ignored after tool results", function()
	provider_calls = 0
	provider_response = function()
		if provider_calls == 1 then
			return table.concat({
				'<tool_call name="run">',
				'{"command":"printf ok","timeout":120000}',
				"</tool_call>",
			}, "\n")
		elseif provider_calls == 2 then
			return "I’m sorry, but I can’t continue because the previous tool-call turn was emitted incorrectly: it mixed tool calls in a final response and used malformed `update_plan` arguments."
		end
		return "Done after retry."
	end

	local session = session_module.create({})
	session.cwd = project_dir
	session:add_user("trigger false apology")

	local result = core.run_session(session, nil, nil, nil)
	if result.text ~= "Done after retry." then
		error("expected false apology to be retried, got: " .. tostring(result.text))
	end
	local found_correction = false
	for _, message in ipairs(session.messages) do
		if message.role == "user" and tostring(message.text or ""):find("incorrectly claimed", 1, true) then
			found_correction = true
			break
		end
	end
	if not found_correction then
		error("missing correction message after false apology")
	end
end)

test("normal mode preserves recovery tools after a late verification failure", function()
	provider_calls = 0
	last_request = nil
	summary_request = nil
	provider_response = function()
		if provider_calls <= 10 then
			local command_a = provider_calls == 10 and "false # late-verification-failure" or "true"
			local n = tostring(provider_calls)
			return table.concat({
				'<tool_call name="run">',
				'{"command":"' .. command_a .. '","timeout":120000}',
				"</tool_call>",
				'<tool_call name="run">',
				'{"command":"true # normal-budget-b-' .. n .. '","timeout":120000}',
				"</tool_call>",
				'<tool_call name="run">',
				'{"command":"true # normal-budget-c-' .. n .. '","timeout":120000}',
				"</tool_call>",
				'<tool_call name="run">',
				'{"command":"true # normal-budget-d-' .. n .. '","timeout":120000}',
				"</tool_call>",
			}, "\n")
		elseif provider_calls == 11 then
			return table.concat({
				'<tool_call name="run">',
				'{"command":"true # recovery-fix","timeout":120000}',
				"</tool_call>",
				'<tool_call name="run">',
				'{"command":"true # recovery-verification","timeout":120000}',
				"</tool_call>",
			}, "\n")
		end
		return "recovered and verified"
	end

	local session = session_module.create({})
	session.cwd = project_dir
	session:add_user("build and verify a project")

	local result = core.run_session(session, nil, nil, nil)
	if result.text ~= "recovered and verified" then
		error("late failure did not receive recovery tools: " .. tostring(result.text))
	end
	if provider_calls ~= 12 then
		error("expected recovery tool round plus final response, got " .. tostring(provider_calls) .. " provider calls")
	end

	local found_reserve = false
	local found_recovery = false
	for _, message in ipairs(session.messages) do
		local text = tostring(message.text or "")
		if message.role == "user" and text:find("Normal-mode tool budget reserve reached", 1, true) then
			found_reserve = true
		end
		if message.role == "user" and text:find("Recovery tool budget activated", 1, true) then
			found_recovery = true
		end
	end
	if not found_reserve then error("missing normal-mode reserve warning") end
	if not found_recovery then error("missing late-failure recovery message") end
end)

test("normal mode grants closure tools when an unfinished build consumes the base budget", function()
	provider_calls = 0
	last_request = nil
	summary_request = nil
	provider_response = function(request)
		if provider_calls <= 10 then
			local n = tostring(provider_calls)
			return table.concat({
				'<tool_call name="run">',
				'{"command":"true # base-a-' .. n .. '","timeout":120000}',
				"</tool_call>",
				'<tool_call name="run">',
				'{"command":"true # base-b-' .. n .. '","timeout":120000}',
				"</tool_call>",
				'<tool_call name="run">',
				'{"command":"true # base-c-' .. n .. '","timeout":120000}',
				"</tool_call>",
				'<tool_call name="run">',
				'{"command":"true # base-d-' .. n .. '","timeout":120000}',
				"</tool_call>",
			}, "\n")
		elseif provider_calls == 11 then
			local joined = {}
			for _, message in ipairs(request.messages or {}) do
				joined[#joined + 1] = tostring(message.text or "")
			end
			if not table.concat(joined, "\n"):find("bounded closure allowance", 1, true) then
				error("closure allowance was not surfaced to the model")
			end
			return table.concat({
				'<tool_call name="run">',
				'{"command":"true # generate-lockfile","timeout":120000}',
				"</tool_call>",
				'<tool_call name="run">',
				'{"command":"true # final-verification","timeout":120000}',
				"</tool_call>",
			}, "\n")
		end
		return "finished and verified during closure"
	end

	local session = session_module.create({})
	session.cwd = project_dir
	session:add_user("build a complete project and verify it")

	local result = core.run_session(session, nil, nil, nil)
	if result.text ~= "finished and verified during closure" then
		error("base exhaustion did not receive closure tools: " .. tostring(result.text))
	end
	if provider_calls ~= 12 then
		error("expected closure tool round plus final response, got " .. tostring(provider_calls) .. " provider calls")
	end
end)

io.write("\n" .. dim("─────────────────────────────────────") .. "\n")
io.write(string.format("  %s passed, %s failed\n",
	green(tostring(passed)), failed > 0 and red(tostring(failed)) or tostring(failed)))
io.write("\n")
os.exit(failed > 0 and 1 or 0)
