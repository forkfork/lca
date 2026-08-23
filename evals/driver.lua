#!/usr/bin/env lua

local function usage()
	io.stderr:write("usage: lua evals/driver.lua --root DIR --prompt-file FILE --credentials FILE --output FILE --transcript FILE [--model MODEL] [--reasoning EFFORT] [--native-tool-calling true|false] [--system-prompt-profile current|lean|minimal] [--system-prompt-append-file FILE] [--edit-tool-profile tagged|exact] [--stream-tool-call-cap N] [--stream-duplicate-call-cap N] [--read-only-batch-cap N] [--seed-context-file FILE] [--intra-turn-compaction true|false] [--context-compaction-threshold N] [--context-hard-limit N] [--compaction-keep-recent-tokens N] [--context-pressure-after-first-tool N] [--recovery-mutation-file FILE]\n")
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

package.path = options.root .. "/lua/?.lua;" .. options.root .. "/lua/?/init.lua;"
	.. options.root .. "/lua/?/?.lua;" .. package.path
require("luarocks.loader")

local json = require("agent.util.json")
local cjson = require("cjson")
local core = require("agent.core")
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
local function optional_bool(value)
	if value == nil then return nil end
	if value == "true" or value == "1" then return true end
	if value == "false" or value == "0" then return false end
	error("expected true or false, got: " .. tostring(value))
end

local session = session_module.create({
	credentials_path = options.credentials,
	model = options.model,
	reasoning_effort = options.reasoning,
	native_tool_calling = optional_bool(options["native-tool-calling"]),
	stream_tool_call_cap = options["stream-tool-call-cap"],
	stream_duplicate_call_cap = options["stream-duplicate-call-cap"],
	read_only_batch_cap = options["read-only-batch-cap"],
	intra_turn_compaction = optional_bool(options["intra-turn-compaction"]),
	context_compaction_threshold = options["context-compaction-threshold"],
	context_hard_limit = options["context-hard-limit"],
	compaction_keep_recent_tokens = options["compaction-keep-recent-tokens"],
})

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

local function profiled_system_prompt(full, profile)
	local context_start = full:find("\n## Context window\n", 1, true)
	local response_start = full:find("\n## Response guidelines\n", 1, true)
	if not context_start or not response_start or response_start <= context_start then
		error("cannot locate system prompt sections for minimal profile")
	end

	local suffix_markers = {
		"\n## Mode\n",
		"\n# Project Context\n",
		"\n## Brave Search\n",
		"\n# Project Index\n",
		"\nCurrent date:",
	}
	local suffix_start
	for _, marker in ipairs(suffix_markers) do
		local found = full:find(marker, response_start + 1, true)
		if found and (not suffix_start or found < suffix_start) then suffix_start = found end
	end
	if not suffix_start then error("cannot locate system prompt suffix for minimal profile") end

	local guidance
	if profile == "minimal" then
		guidance = {
			"\n## Response guidelines",
			"- Complete the requested task using the available tools when needed.",
			"- Be concise, verify code changes, and report only work supported by tool results.",
			"- A tool-call message must contain only tool calls.",
		}
	elseif profile == "lean" then
		guidance = {
			"\n## Context window",
			"- Do not re-read content still visible in recent tool results. After compaction, re-read source before quoting or editing it.",
			"- Keep tool output focused; search or read a range instead of dumping large files.",
			"",
			"## Response guidelines",
			"- Complete clear local work without asking permission. Be concise.",
			"- Use run to verify code changes.",
			"- A tool-call message must contain only tool calls.",
			"- Never claim a file action or test without its tool result. Acknowledge tool errors.",
			"- Ground cited paths, symbols, and code in visible tool results; re-read them when necessary.",
		}
	else
		error("cannot build system prompt profile: " .. tostring(profile))
	end
	return full:sub(1, context_start - 1) .. table.concat(guidance, "\n") .. full:sub(suffix_start)
end

local function exact_edit_tool_prompt(full)
	local function replace_plain(text, before, after)
		local start_at, end_at = text:find(before, 1, true)
		if not start_at then error("cannot locate edit prompt section for exact profile") end
		if text:find(before, end_at + 1, true) then
			error("edit prompt section is not unique for exact profile")
		end
		return text:sub(1, start_at - 1) .. after .. text:sub(end_at + 1)
	end
	local replacements = {
		{
			[[For edit and write, put ONLY metadata in JSON. File content goes as RAW TEXT after the JSON line — NO escaping, NO quoting, just the literal code:

<tool_call name="edit">
{"path":"file.lua","start_line":10,"start_tag":"Q8fA","end_line":12,"end_tag":"rX2b"}
replacement line 1
replacement line 2
</tool_call>

<tool_call name="write">]],
			[[For edit, put path, the exact old text, and replacement text in JSON. The old text must occur exactly once:

<tool_call name="edit">
{"path":"file.lua","oldText":"old line 1\nold line 2","newText":"replacement line 1\nreplacement line 2"}
</tool_call>

For write, put ONLY path metadata in JSON. File content goes as raw text after the JSON line:

<tool_call name="write">]],
		},
		{
			[[To delete lines, leave the content empty (nothing after the JSON line):
<tool_call name="edit">
{"path":"file.lua","start_line":10,"start_tag":"Q8fA","end_line":12,"end_tag":"rX2b"}
</tool_call>]],
			[[To delete text, use an empty newText string:
<tool_call name="edit">
{"path":"file.lua","oldText":"obsolete line\n","newText":""}
</tool_call>]],
		},
		{
			[[edit: replace lines in a file. JSON args: path, start_line, start_tag, end_line, end_tag. Raw content after JSON replaces all lines in the range. Tags are the 4-char CAS codes from read output (e.g. "10:Q8fA") — they verify the file hasn't changed.]],
			[[edit: replace one exact, unique text block in a file. JSON args: path, oldText, newText. Copy only the file content from a recent read, including whitespace; do not include displayed line-number/CAS prefixes such as "10:Q8fA:". Ambiguous or stale matches are rejected.]],
		},
		{
			[[You may batch multiple edits to the same file only when the line ranges are non-overlapping and all edits use tags from a previous read output already visible in this conversation. They are applied bottom-to-top so line numbers stay valid. If edits overlap or depend on earlier edits, make one edit, re-read, then continue.]],
			[[Do not batch multiple edits to the same file. Make one exact replacement, then re-read before another edit because the original text may be stale.]],
		},
		{
			[[For edit and write: put the raw file content DIRECTLY after the JSON metadata line. Do NOT put content inside the JSON. Do NOT escape newlines or quotes. Just write the code exactly as it should appear in the file. ONE EXCEPTION: raw content must not contain literal "<tool_call" or "</tool_call>" markup. If the file needs those strings, split or escape them in the code (e.g. "</" .. "tool_call>").]],
			[[For edit, put oldText and newText inside the JSON and escape newlines and quotes normally. For write, put raw file content directly after the JSON metadata line. Raw write content must not contain literal "<tool_call" or "</tool_call>" markup; split or escape those strings if needed.]],
		},
		{
			[[When editing, copy the line tags EXACTLY from the read output. They are 4-char codes like "Q8fA". If a tag doesn't match, the file changed — re-read it.]],
			[[When editing, copy oldText exactly from a recent read and include enough surrounding text to make it unique. Strip the displayed line-number/CAS prefix from every copied line; it is read metadata, not file content. If oldText does not match, re-read the file instead of guessing.]],
		},
	}
	for _, replacement in ipairs(replacements) do
		full = replace_plain(full, replacement[1], replacement[2])
	end
	return full
end

local prompt_profile = options["system-prompt-profile"] or "current"
local edit_tool_profile = options["edit-tool-profile"] or "tagged"
local full_system_prompt = session:get_system_prompt()
if prompt_profile == "minimal" or prompt_profile == "lean" then
	session.system_prompt = profiled_system_prompt(full_system_prompt, prompt_profile)
elseif prompt_profile ~= "current" then
	error("unknown system prompt profile: " .. tostring(prompt_profile))
end
if edit_tool_profile == "exact" then
	session.system_prompt = exact_edit_tool_prompt(session.system_prompt or full_system_prompt)
elseif edit_tool_profile ~= "tagged" then
	error("unknown edit tool profile: " .. tostring(edit_tool_profile))
end
if options["system-prompt-append-file"] then
	session.system_prompt = (session.system_prompt or full_system_prompt)
		.. "\n\n" .. read_file(options["system-prompt-append-file"])
end
session:add_user(prompt)

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

local function eval_on_tool(event)
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
		and (event.name == "edit" or event.name == "write") then
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
local ok, result = pcall(core.run_session, session, nil, eval_on_tool)
local elapsed_ms = math.floor((uv.hrtime() - started) / 1000000)
core.set_transcript(nil)

if not ok then
	write_file(options.output, json.encode({
		ok = false,
		error = tostring(result),
		elapsed_ms = elapsed_ms,
	}))
	io.stderr:write("LCA eval run failed: " .. tostring(result) .. "\n")
	os.exit(1)
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
	ok = true,
	model = session.model,
	reasoning_effort = session.reasoning_effort,
	system_prompt_profile = prompt_profile,
	edit_tool_profile = edit_tool_profile,
	stale_mutation_applied = stale_mutation and stale_mutation.applied or false,
	system_prompt_chars = #(session.system_prompt or ""),
	stream_tool_call_cap = session.stream_tool_call_cap,
	stream_duplicate_call_cap = session.stream_duplicate_call_cap,
	native_tool_calling = session.native_tool_calling,
	intra_turn_compaction = session.intra_turn_compaction,
	context_compaction_threshold = session.context_compaction_threshold,
	context_hard_limit = session.context_hard_limit,
	context_compaction_count = tonumber(session.context_compaction_count) or 0,
	context_pressure_applied = context_pressure_applied,
	recovery_mutation_applied = recovery_mutation and recovery_mutation.applied or false,
	final = result.text or "",
	tool_calls = tool_calls,
	llm_calls = math.max(0, assistant_tool_turns - initial_assistant_messages) + 1,
	elapsed_ms = elapsed_ms,
	usage = safe_value(session.usage_history or {}),
	events = safe_value(result.events or {}),
	messages = safe_value(session.messages or {}),
}))
