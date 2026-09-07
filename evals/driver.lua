#!/usr/bin/env lua

local function usage()
	io.stderr:write("usage: lua evals/driver.lua --root DIR --prompt-file FILE --credentials FILE --output FILE --transcript FILE [--model gpt-5.6-sol|gpt-5.6-terra|gpt-5.6-luna] [--reasoning EFFORT] [--tool-scope all|web_only|none] [--multi-edit-enabled true|false] [--system-prompt-profile current|pre-harness-quality] [--system-prompt-append-file FILE] [--edit-tool-profile tagged] [--read-only-batch-cap N] [--grep-evidence true|false] [--stale-edit-evidence true|false] [--completion-audit true|false] [--blank-workspace-inventory-guard true|false] [--seed-context-file FILE] [--intra-turn-compaction true|false] [--context-compaction-threshold N] [--context-hard-limit N] [--compaction-keep-recent-tokens N] [--context-pressure-after-first-tool N] [--recovery-mutation-file FILE]\n")
	os.exit(2)
end

local options = {}
local index = 1
while index <= #arg do
	local key = arg[index]
	if key:sub(1, 2) ~= "--" or not arg[index + 1] then usage() end
	options[key:sub(3)] = arg[index + 1]
	index = index + 2
end

if not options.root or not options["prompt-file"] or not options.credentials
	or not options.output or not options.transcript then
	usage()
end

-- Reject historical treatments before reading fixtures or making model calls.
for _, key in ipairs({ "delegate-readonly-enabled", "delegate-readonly-profile", "tool-dag-enabled", "readonly-fork-join-enabled" }) do
	if options[key] ~= nil then error("retired experiment option: " .. key .. "; see research/archive/README.md") end
end
local retired_prompt_profiles = {
	["workflow-lite"] = true, ["planning-clarity"] = true,
	["repo-facts"] = true, lean = true, minimal = true,
}
if retired_prompt_profiles[options["system-prompt-profile"]] then
	error("retired experiment option: system-prompt-profile=" .. options["system-prompt-profile"] .. "; see research/archive/README.md")
end
if options["edit-tool-profile"] == "exact" then
	error("retired experiment option: edit-tool-profile=exact; native tools require tagged edits")
end

package.path = options.root .. "/lua/?.lua;" .. options.root .. "/lua/?/init.lua;"
	.. options.root .. "/lua/?/?.lua;" .. package.path
require("luarocks.loader")

local json = require("agent.util.json")
local cjson = require("cjson")
local core = require("agent.core")
local registry = require("agent.tool_registry")
local session_module = require("agent.session")
local path_util = require("agent.util.path")
local uv = require("luv")

local function read_file(path)
	local file = assert(io.open(path, "r"))
	local body = file:read("*a")
	file:close()
	return body
end

local function write_file(path, body)
	local file = assert(io.open(path, "w"))
	file:write(body, "\n")
	file:close()
end

local function write_exact(path, body)
	local file = assert(io.open(path, "w"))
	file:write(body)
	file:close()
end

local function safe_value(value, depth)
	depth = depth or 0
	if depth > 8 then return "[depth limit]" end
	if value == cjson.empty_array or value == cjson.null then return value end
	if type(value) == "string" then
		if #value > 50000 then
			return value:sub(1, 50000) .. "...[truncated]"
		end
		return value
	end
	if type(value) == "number" or type(value) == "boolean" or value == nil then
		return value
	end
	if type(value) ~= "table" then return tostring(value) end
	local copy = {}
	for key, child in pairs(value) do
		copy[type(key) == "number" and key or tostring(key)] = safe_value(child, depth + 1)
	end
	return copy
end

local prompt = read_file(options["prompt-file"])
local tool_scope = options["tool-scope"]
if tool_scope == "all" then tool_scope = nil end
if tool_scope ~= nil and tool_scope ~= "web_only" and tool_scope ~= "none" and tool_scope ~= "local_only" then
	error("tool scope must be all, local_only, web_only, or none")
end
local function optional_bool(value)
	if value == nil then return nil end
	if value == "true" or value == "1" then return true end
	if value == "false" or value == "0" then return false end
	error("expected true or false, got: " .. tostring(value))
end

local multi_edit_option = optional_bool(options["multi-edit-enabled"])
if multi_edit_option ~= nil then
	registry.set_multi_edit_enabled(multi_edit_option)
end

local session = session_module.create({
	credentials_path = options.credentials,
	model = options.model,
	reasoning_effort = options.reasoning,
	tool_scope = tool_scope,
	read_only_batch_cap = options["read-only-batch-cap"],
	grep_evidence = optional_bool(options["grep-evidence"]),
	stale_edit_evidence = optional_bool(options["stale-edit-evidence"]),
	intra_turn_compaction = optional_bool(options["intra-turn-compaction"]),
	context_compaction_threshold = options["context-compaction-threshold"],
	context_hard_limit = options["context-hard-limit"],
	compaction_keep_recent_tokens = options["compaction-keep-recent-tokens"],
})
session.completion_audit = optional_bool(options["completion-audit"])
session.blank_workspace_inventory_guard = optional_bool(options["blank-workspace-inventory-guard"])

if options["seed-context-file"] then
	local seed = json.decode(read_file(options["seed-context-file"]))
	if type(seed) ~= "table" or type(seed.messages) ~= "table" then
		error("seed context must contain a messages array")
	end
	for _, message in ipairs(seed.messages) do
		if type(message) ~= "table" or (message.role ~= "user" and message.role ~= "assistant") then
			error("invalid seeded context message")
		end
		local text = tostring(message.text or "")
		if message.repeat_text ~= nil or message.repeat_count ~= nil then
			local count = tonumber(message.repeat_count)
			if type(message.repeat_text) ~= "string" or not count or count < 0 or count > 10000 then
				error("invalid seeded context repetition")
			end
			text = text .. string.rep(message.repeat_text, math.floor(count))
		end
		session.messages[#session.messages + 1] = {
			role = message.role,
			text = text,
			tool_name = message.tool_name,
		}
	end
end

local function pre_harness_quality_prompt(full)
	local lines = {
		"- In a blank or new workspace, use at most one inventory call. Do not batch ls, find, and grep against the same empty root; use the project index and the first result, then begin the requested research or implementation.",
		"- For web-researched implementation, prefer primary current documentation and turn mandatory platform or API requirements into an explicit acceptance checklist before coding. Start with at most three focused searches; search again only for a named unresolved requirement.",
		"- Separate fast deterministic local checks from slow, environment-dependent, remote, cloud, or hardware checks. Do not hide a slow external probe at the end of a long command chain; preserve clear evidence for every check that completed.",
		"- For deployment and infrastructure work, syntax checks and static builds do not prove deployability. Distinguish files written, local checks executed, static contracts checked, and external deployment or invocation actually completed.",
		"- Do not call an implementation complete when a required external path was not exercised. State the exact boundary and lead with what was actually proven.",
	}
	for _, line in ipairs(lines) do
		local needle = "\n" .. line
		local start_at, end_at = full:find(needle, 1, true)
		if not start_at then error("cannot locate harness-quality policy line") end
		full = full:sub(1, start_at - 1) .. full:sub(end_at + 1)
	end
	return full
end

local prompt_profile = options["system-prompt-profile"] or "current"
local edit_tool_profile = options["edit-tool-profile"] or "tagged"
local full_system_prompt = session:get_system_prompt()
if prompt_profile == "pre-harness-quality" then
	session.system_prompt = pre_harness_quality_prompt(full_system_prompt)
elseif prompt_profile ~= "current" then
	error("unknown system prompt profile: " .. tostring(prompt_profile))
end
if edit_tool_profile ~= "tagged" then
	error("unknown edit tool profile: " .. tostring(edit_tool_profile))
end
if options["system-prompt-append-file"] then
	session.system_prompt = (session.system_prompt or full_system_prompt)
		.. "\n\n" .. read_file(options["system-prompt-append-file"])
end
if options["experience-file"] then
	session:add_user(read_file(options["experience-file"]))
end
if prompt_profile == "current" then
	local directory = assert(options.output:match("^(.*)/[^/]+$"))
	write_file(directory .. "/prompt-profile.json", json.encode({
		profile = prompt_profile, baseline = full_system_prompt,
		effective = session.system_prompt or full_system_prompt,
	}))
end
session:add_user(prompt)

local context_pilot
if options["context-mode"] then
	context_pilot = dofile(options.root .. "/evals/state_context.lua").new(
		options["context-mode"], session, assert(options.output:match("^(.*)/[^/]+$")))
end

local initial_assistant_messages = 0
for _, message in ipairs(session.messages or {}) do
	if message.role == "assistant" then
		initial_assistant_messages = initial_assistant_messages + 1
	end
end

local stale_mutation
if options["stale-mutation-file"] then
	stale_mutation = json.decode(read_file(options["stale-mutation-file"]))
	if type(stale_mutation) ~= "table" or type(stale_mutation.path) ~= "string"
		or type(stale_mutation.old_text) ~= "string" or type(stale_mutation.new_text) ~= "string" then
		error("invalid stale mutation fixture")
	end
	stale_mutation.applied = false
end

local context_pressure = tonumber(options["context-pressure-after-first-tool"])
local context_pressure_applied = false
local recovery_mutation
if options["recovery-mutation-file"] then
	recovery_mutation = json.decode(read_file(options["recovery-mutation-file"]))
	if type(recovery_mutation) ~= "table" or type(recovery_mutation.path) ~= "string"
		or type(recovery_mutation.old_text) ~= "string" or type(recovery_mutation.new_text) ~= "string" then
		error("invalid recovery mutation fixture")
	end
	recovery_mutation.applied = false
	recovery_mutation.target_changed = false
end

local captured_events = {}
local function eval_on_tool(event)
	captured_events[#captured_events + 1] = event
	if recovery_mutation and not recovery_mutation.applied
		and recovery_mutation.target_changed
		and event.phase == "start" and event.name == "run"
	then
		-- Inject at the verification boundary, after the complete edit batch. Mutating
		-- batches can contain multiple same-file edits executed bottom-to-top; injecting
		-- after an individual edit lets a later edit accidentally erase the fault.
		local target = path_util.resolve(recovery_mutation.path, session.cwd)
		local body = read_file(target)
		local start_at, end_at = body:find(recovery_mutation.old_text, 1, true)
		if not start_at or body:find(recovery_mutation.old_text, end_at + 1, true) then
			error("recovery mutation old_text must match exactly once before verification")
		end
		write_exact(target, body:sub(1, start_at - 1) .. recovery_mutation.new_text .. body:sub(end_at + 1))
		recovery_mutation.applied = true
	end
	if not event.result or event.result.is_error then return end
	if recovery_mutation and not recovery_mutation.applied
		and (event.name == "edit" or event.name == "multi_edit" or event.name == "write") then
		local event_path = event.args and event.args.path
		local target = path_util.resolve(recovery_mutation.path, session.cwd)
		if event_path and path_util.resolve(event_path, session.cwd) == target then
			recovery_mutation.target_changed = true
		end
	end
	if context_pressure and not context_pressure_applied then
		session.last_usage = {
			total_tokens = context_pressure,
			prompt_tokens = context_pressure,
			output_tokens = 0,
			cached_tokens = 0,
			message_index = #session.messages,
			timestamp = os.time(),
		}
		context_pressure_applied = true
	end
	if event.name ~= "read" then return end
	if not stale_mutation or stale_mutation.applied then return end
	local event_path = event.args and event.args.path
	if not event_path then return end
	local target = path_util.resolve(stale_mutation.path, session.cwd)
	if path_util.resolve(event_path, session.cwd) ~= target then return end

	local body = read_file(target)
	local start_at, end_at = body:find(stale_mutation.old_text, 1, true)
	if not start_at or body:find(stale_mutation.old_text, end_at + 1, true) then
		error("stale mutation old_text must match exactly once")
	end
	write_exact(target, body:sub(1, start_at - 1) .. stale_mutation.new_text .. body:sub(end_at + 1))
	stale_mutation.applied = true
end

core.set_transcript(options.transcript)
local started = uv.hrtime()
local model_activities = {}
local ok, result = pcall(core.run_session, session, nil, eval_on_tool, nil, nil, {
	before_step = context_pilot and context_pilot.before_step,
	on_request = context_pilot and context_pilot.on_request,
	on_response = context_pilot and context_pilot.on_response,
	on_model_activity = function(activity)
		model_activities[#model_activities + 1] = safe_value(activity)
	end,
})
local elapsed_ms = math.floor((uv.hrtime() - started) / 1000000)
core.set_transcript(nil)

if not ok then
	io.stderr:write("LCA eval run failed: " .. tostring(result) .. "\n")
	result = { error = tostring(result), events = captured_events }
end

local tool_calls = 0
for _, event in ipairs(result.events or {}) do
	if event.result ~= nil then tool_calls = tool_calls + 1 end
end
local assistant_tool_turns = 0
for _, message in ipairs(session.messages or {}) do
	if message.role == "assistant" then assistant_tool_turns = assistant_tool_turns + 1 end
end

write_file(options.output, json.encode({
	ok = ok,
	error = result.error,
	context_pilot = context_pilot and context_pilot.report(),
	model = session.model,
	reasoning_effort = session.reasoning_effort,
	tool_scope = session.tool_scope,
	system_prompt_profile = prompt_profile,
	edit_tool_profile = edit_tool_profile,
	multi_edit_enabled = registry.multi_edit_enabled(),
	grep_evidence = session.grep_evidence,
	stale_edit_evidence = session.stale_edit_evidence,
	stale_mutation_applied = stale_mutation and stale_mutation.applied or false,
	system_prompt_chars = #(session.system_prompt or ""),
	native_tool_calling = session.native_tool_calling,
	intra_turn_compaction = session.intra_turn_compaction,
	context_compaction_threshold = session.context_compaction_threshold,
	context_hard_limit = session.context_hard_limit,
	context_compaction_count = tonumber(session.context_compaction_count) or 0,
	context_pressure_applied = context_pressure_applied,
	recovery_mutation_applied = recovery_mutation and recovery_mutation.applied or false,
	final = result.text or "",
	tool_calls = tool_calls,
	llm_calls = context_pilot and context_pilot.requests or math.max(0, assistant_tool_turns - initial_assistant_messages) + 1,
	elapsed_ms = elapsed_ms,
	usage = safe_value(context_pilot and context_pilot.usage or session.usage_history or {}),
	model_activities = model_activities,
	events = safe_value(result.events or {}),
	messages = safe_value(session.messages or {}),
}))
if not ok then os.exit(1) end
