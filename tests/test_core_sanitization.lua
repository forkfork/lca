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
							require("agent.repl").cancelled = true
						end
						return provider_response
					end
				if type(provider_response) == "function" then
					return {
						text = provider_response(request),
					}
				end
				return {
					text = provider_response,
				}
			end,
		}
	end,
}

local core = require("agent.core")
local session_module = require("agent.session")

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

test("strips model-emitted tool_result tags from assistant text", function()
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
	local assistant_text = session.messages[2] and session.messages[2].text or ""
	local count = 0
	for _ in assistant_text:gmatch("<tool_call") do
		count = count + 1
	end
	if count ~= 2 then
		error("expected only 2 unique executed tool calls in history, got " .. tostring(count) .. ": " .. assistant_text)
	end
end)

test("batch cap is surfaced to next model turn", function()
	provider_calls = 0
	local first_response = {}
	for i = 1, 12 do
		first_response[#first_response + 1] = '<tool_call name="ls">'
		first_response[#first_response + 1] = '{"path":"missing-' .. tostring(i) .. '"}'
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

test("normal mode does not add an insanitywolf policy", function()
	provider_calls = 0
	provider_response = "normal done"
	last_request = nil

	local session = session_module.create({ flow = "off" })
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

test("insanitywolf mode is included in system prompt", function()
	provider_response = "insanitywolf done"
	last_request = nil

	local session = session_module.create({ flow = "insanitywolf" })
	session.cwd = project_dir
	session:add_user("trigger insanitywolf")

	local result = core.run_session(session, nil, nil, nil)
	if result.text ~= "insanitywolf done" then
		error("unexpected result: " .. tostring(result.text))
	end
	if not last_request or type(last_request.system_prompt) ~= "string" then
		error("provider request was not captured")
	end
	if not last_request.system_prompt:find("insanitywolf", 1, true) then
		error("missing insanitywolf mode policy in system prompt")
	end
	if not last_request.system_prompt:find("bounded improvement cycles", 1, true) then
		error("missing insanitywolf cycle policy in system prompt")
	end
	if not last_request.system_prompt:find("mark that cycle complete", 1, true) then
		error("missing insanitywolf completion policy in system prompt")
	end
	if not last_request.system_prompt:find("do not merely mention it", 1, true) then
		error("missing insanitywolf follow-up planning policy in system prompt")
	end
	if not last_request.system_prompt:find("do not ask permission", 1, true) then
		error("missing insanitywolf continue-without-permission policy in system prompt")
	end
	if not last_request.system_prompt:find("budget reserve", 1, true) then
		error("missing insanitywolf tool budget reserve policy in system prompt")
	end
	if not last_request.system_prompt:find("at most five improvement cycles", 1, true) then
		error("missing insanitywolf cycle cap in system prompt")
	end
	if not last_request.system_prompt:find("visible transition note", 1, true) then
		error("missing insanitywolf transition policy in system prompt")
	end
	if not last_request.system_prompt:find("user%-directed follow%-ups") then
		error("missing insanitywolf stop offer policy in system prompt")
	end
	if not last_request.system_prompt:find("security hardening", 1, true) then
		error("missing insanitywolf security hardening policy in system prompt")
	end
	if not last_request.system_prompt:find("authentication", 1, true)
		or not last_request.system_prompt:find("CSRF tokens", 1, true)
		or not last_request.system_prompt:find("user%-directed offer")
	then
		error("missing insanitywolf auth/admin autonomous hardening policy in system prompt")
	end
	if not last_request.system_prompt:find("boring conventional default", 1, true)
		or not last_request.system_prompt:find("SQLite", 1, true)
		or not last_request.system_prompt:find("server%-rendered HTML")
	then
		error("missing insanitywolf boring defaults policy in system prompt")
	end
	if not last_request.system_prompt:find("standard password hashing", 1, true)
		or not last_request.system_prompt:find("simple durable local job", 1, true)
		or not last_request.system_prompt:find("Makefile", 1, true)
	then
		error("missing insanitywolf stronger technical defaults policy in system prompt")
	end
end)

test("insanitywolf checkpoints compact cycle context", function()
	provider_calls = 0
	last_request = nil
	summary_request = nil
	local main_calls = 0
	provider_response = function(request)
		if tostring(request.system_prompt or ""):find("context summarization assistant", 1, true) then
			return "## Goal\ncheckpoint\n\n## Next Steps\n1. Keep detailed next improvement.\n\n## Critical Context\n- exact next detail"
		end
		main_calls = main_calls + 1
		if main_calls == 1 then
			return table.concat({
				'<tool_call name="update_plan">',
				'{"plan":[{"step":"First cycle","status":"completed"}]}',
				"</tool_call>",
			}, "\n")
		end
		return "done"
	end

	local session = session_module.create({ flow = "insanitywolf" })
	session.cwd = project_dir
	session:add_user("trigger insanitywolf checkpoint")

	local result = core.run_session(session, nil, nil, nil)

	if result.text ~= "done" then
		error("unexpected result: " .. tostring(result.text))
	end
	if not summary_request then
		error("expected insanitywolf checkpoint summarization request")
	end
	local prompt = summary_request.messages[1].text or ""
	if not prompt:find("Additional insanitywolf checkpoint rules", 1, true) then
		error("missing checkpoint summary instructions")
	end
	if not prompt:find("authentication", 1, true)
		or not prompt:find("CSRF tokens", 1, true)
		or not prompt:find("Do not put these in user%-directed offers")
	then
		error("missing checkpoint auth/admin hardening classification rules")
	end
	if not session.compaction_summary or not session.compaction_summary:find("## Current Plan", 1, true) then
		error("checkpoint summary did not retain current plan")
	end
	if session.plan ~= nil then
		error("completed plan should be cleared before the next insanitywolf cycle")
	end
	local found_continue = false
	for _, message in ipairs(session.messages) do
		if message.role == "user"
			and tostring(message.text or ""):find("concrete high%-impact implementation improvement")
			and tostring(message.text or ""):find("visible transition note", 1, true)
			and tostring(message.text or ""):find("offer concise concrete directions", 1, true)
			and tostring(message.text or ""):find("security hardening", 1, true)
			and tostring(message.text or ""):find("auth/admin hardening", 1, true)
			and tostring(message.text or ""):find("Do not ask permission", 1, true)
		then
			found_continue = true
			break
		end
	end
	if not found_continue then
		error("checkpoint did not add a continuation instruction")
	end
end)

test("insanitywolf does not checkpoint before plan completion", function()
	provider_calls = 0
	last_request = nil
	summary_request = nil
	local main_calls = 0
	provider_response = function(request)
		if tostring(request.system_prompt or ""):find("context summarization assistant", 1, true) then
			return "unexpected summary"
		end
		main_calls = main_calls + 1
		if main_calls == 1 then
			return table.concat({
				'<tool_call name="update_plan">',
				'{"plan":[{"step":"First cycle","status":"in_progress"},{"step":"Next improvement","status":"pending"}]}',
				"</tool_call>",
			}, "\n")
		end
		return "done"
	end

	local session = session_module.create({ flow = "insanitywolf" })
	session.cwd = project_dir
	session:add_user("trigger incomplete insanitywolf plan")

	local result = core.run_session(session, nil, nil, nil)

	if result.text ~= "done" then
		error("unexpected result: " .. tostring(result.text))
	end
	if summary_request then
		error("checkpoint should not run before plan completion")
	end
end)

test("partial salvage emits quiet thinking status", function()
	provider_response = {
		text = table.concat({
			'<tool_call name="ls">',
			'{"path":"."}',
			"</tool_call>",
		}, "\n"),
		_partial_salvage = true,
		_partial_salvaged_calls = 1,
		_response_bytes = 1234,
	}

	local session = session_module.create({})
	session.cwd = project_dir
	session:add_user("trigger partial salvage")

	local statuses = {}
	core.run_session(session, nil, nil, function(info)
		if info.status then
			statuses[#statuses + 1] = info.status
		end
	end)

	local found = false
	for _, status in ipairs(statuses) do
		if status == "salvaged partial response  1 tools" then
			found = true
			break
		end
	end
	if not found then
		error("missing partial salvage thinking status")
	end
end)

test("cancel after partial salvage preserves recovered tool metadata", function()
	provider_response = {
		text = table.concat({
			'<tool_call name="ls">',
			'{"path":"."}',
			"</tool_call>",
		}, "\n"),
		_partial_salvage = true,
		_partial_salvaged_calls = 1,
		_response_bytes = 4321,
		_cancel_during_complete = true,
	}

	local repl = require("agent.repl")
	repl.cancelled = false

	local session = session_module.create({})
	session.cwd = project_dir
	session:add_user("trigger cancelled partial salvage")

	local result = core.run_session(session, nil, nil, nil)
	repl.cancelled = false

	if result._cancelled ~= true then
		error("expected cancelled result")
	end
	if result._partial_salvage ~= true then
		error("expected partial salvage metadata")
	end
	if result._partial_salvaged_calls ~= 1 then
		error("expected one salvaged call")
	end
	if result.text:find('<tool_call name="ls">', 1, true) == nil then
		error("expected salvaged tool text to be preserved")
	end
end)

test("insanitywolf warns before tool budget exhaustion", function()
	provider_calls = 0
	last_request = nil
	summary_request = nil
	provider_response = function()
		local n = tostring(provider_calls)
		return table.concat({
			'<tool_call name="run">',
			'{"command":"true # budget-a-' .. n .. '"}',
			"</tool_call>",
			'<tool_call name="run">',
			'{"command":"true # budget-b-' .. n .. '"}',
			"</tool_call>",
			'<tool_call name="run">',
			'{"command":"true # budget-c-' .. n .. '"}',
			"</tool_call>",
			'<tool_call name="run">',
			'{"command":"true # budget-d-' .. n .. '"}',
			"</tool_call>",
		}, "\n")
	end

	local session = session_module.create({ flow = "insanitywolf" })
	session.cwd = project_dir
	session:add_user("burn budget")

	core.run_session(session, nil, nil, nil)

	local found = false
	for _, message in ipairs(session.messages) do
		if message.role == "user" and tostring(message.text or ""):find("Insanitywolf tool budget reserve reached", 1, true) then
			found = true
			break
		end
	end
	if not found then
		error("missing insanitywolf tool budget reserve warning")
	end
end)

io.write("\n" .. dim("─────────────────────────────────────") .. "\n")
io.write(string.format("  %s passed, %s failed\n",
	green(tostring(passed)), failed > 0 and red(tostring(failed)) or tostring(failed)))
io.write("\n")
os.exit(failed > 0 and 1 or 0)
