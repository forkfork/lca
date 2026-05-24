local providers = require("agent.providers")
local context_limits = require("agent.context_limits")
local protocol = require("agent.tool_protocol")

local compaction = {}

local KEEP_RECENT_TOKENS = 20000
local SLIM_KEEP_RECENT_MESSAGES = tonumber(os.getenv("LCA_SLIM_KEEP_RECENT_MESSAGES") or "") or 8
local SLIM_LARGE_MESSAGE_BYTES = tonumber(os.getenv("LCA_SLIM_LARGE_MESSAGE_BYTES") or "") or 6000
local SLIM_TARGET_SESSION_TOKENS = tonumber(os.getenv("LCA_SLIM_TARGET_SESSION_TOKENS") or "") or 50000
local SLIM_TARGET_MESSAGES = tonumber(os.getenv("LCA_SLIM_TARGET_MESSAGES") or "") or 160
local SLIM_KEEP_READS_PER_PATH = tonumber(os.getenv("LCA_SLIM_KEEP_READS_PER_PATH") or "") or 8

local SUMMARIZATION_SYSTEM_PROMPT = "You are a context summarization assistant. Your task is to read a conversation between a user and an AI coding assistant, then produce a structured summary following the exact format specified.\n\nDo NOT continue the conversation. Do NOT respond to any questions in the conversation. ONLY output the structured summary."

local SUMMARIZATION_PROMPT = [[The messages above are a conversation to summarize. Create a structured context checkpoint summary that another LLM will use to continue the work.

Use this EXACT format:

## Goal
[What is the user trying to accomplish? Can be multiple items if the session covers different tasks.]

## Constraints & Preferences
- [Any constraints, preferences, or requirements mentioned by user]
- [Or "(none)" if none were mentioned]

## Progress
### Done
- [x] [Completed tasks/changes]

### In Progress
- [ ] [Current work]

### Blocked
- [Issues preventing progress, if any]

## Key Decisions
- **[Decision]**: [Brief rationale]

## Next Steps
1. [Ordered list of what should happen next]

## Critical Context
- [Any data, examples, or references needed to continue]
- [Or "(none)" if not applicable]

Keep each section concise. Preserve exact file paths, function names, and error messages.]]

local UPDATE_SUMMARIZATION_PROMPT = [[The messages above are NEW conversation messages to incorporate into the existing summary provided in <previous-summary> tags.

Update the existing structured summary with new information. RULES:
- PRESERVE all existing information from the previous summary
- ADD new progress, decisions, and context from the new messages
- UPDATE the Progress section: move items from "In Progress" to "Done" when completed
- UPDATE "Next Steps" based on what was accomplished
- PRESERVE exact file paths, function names, and error messages
- If something is no longer relevant, you may remove it

Use this EXACT format:

## Goal
[Preserve existing goals, add new ones if the task expanded]

## Constraints & Preferences
- [Preserve existing, add new ones discovered]

## Progress
### Done
- [x] [Include previously done items AND newly completed items]

### In Progress
- [ ] [Current work - update based on progress]

### Blocked
- [Current blockers - remove if resolved]

## Key Decisions
- **[Decision]**: [Brief rationale] (preserve all previous, add new)

## Next Steps
1. [Update based on current state]

## Critical Context
- [Preserve important context, add new if needed]

Keep each section concise. Preserve exact file paths, function names, and error messages.]]

function compaction.estimate_tokens(message)
	local text = message.text or ""
	return math.ceil(#text / 4)
end

function compaction.estimate_total(messages)
	local total = 0
	for _, msg in ipairs(messages) do
		total = total + compaction.estimate_tokens(msg)
	end
	return total
end

local function attr(text, name)
	return tostring(text or ""):match(name .. '="([^"]*)"')
end

local function line_count(text)
	local count = 0
	for _ in tostring(text or ""):gmatch("\n") do
		count = count + 1
	end
	return count
end

local function compact_command(value, max_len)
	value = tostring(value or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
	max_len = max_len or 100
	if #value > max_len then
		value = value:sub(1, max_len - 3) .. "..."
	end
	return value
end

local function summarize_assistant_tool_calls(text)
	local calls = protocol.extract_all_tool_calls(text or "")
	if #calls == 0 then
		return nil
	end
	local lines = { "[old assistant tool calls slimmed]" }
	for _, call in ipairs(calls) do
		local args = call.args or {}
		local detail = call.name
		if args.path then
			detail = detail .. " path=" .. tostring(args.path)
		elseif args.command then
			detail = detail .. " command=" .. compact_command(args.command)
		elseif args.pattern then
			detail = detail .. " pattern=" .. tostring(args.pattern)
		end
		local raw = args._raw_content or args.content
		if raw and raw ~= "" then
			detail = detail .. " content_omitted=" .. tostring(#raw) .. " bytes"
		end
		lines[#lines + 1] = "- " .. detail
	end
	return table.concat(lines, "\n")
end

local function add_sorted(set, out)
	local values = {}
	for value in pairs(set) do
		values[#values + 1] = value
	end
	table.sort(values)
	for _, value in ipairs(values) do
		out[#out + 1] = value
	end
end

local function file_ops_from_message(message, ops)
	if not message then return end
	local text = message.text or ""
	if message.role == "assistant" then
		for _, call in ipairs(protocol.extract_all_tool_calls(text)) do
			local args = call.args or {}
			local path = args.path and tostring(args.path) or nil
			if path and path ~= "" then
				if call.name == "read" then
					ops.read[path] = true
				elseif call.name == "edit" or call.name == "write" then
					ops.modified[path] = true
				end
			end
		end
	elseif message.tool_name then
		local path = attr(text, "path")
		if path and path ~= "" then
			if message.tool_name == "read" then
				ops.read[path] = true
			elseif message.tool_name == "edit" or message.tool_name == "write" then
				ops.modified[path] = true
			end
		end
	end
end

function compaction.file_operations(messages, previous)
	local ops = { read = {}, modified = {} }
	if previous then
		for _, path in ipairs(previous.read_files or previous.readFiles or {}) do
			ops.read[tostring(path)] = true
		end
		for _, path in ipairs(previous.modified_files or previous.modifiedFiles or {}) do
			ops.modified[tostring(path)] = true
		end
	end
	for _, message in ipairs(messages or {}) do
		file_ops_from_message(message, ops)
	end

	local read_files = {}
	local modified_files = {}
	for path in pairs(ops.modified) do
		ops.read[path] = nil
	end
	add_sorted(ops.read, read_files)
	add_sorted(ops.modified, modified_files)
	return {
		read_files = read_files,
		modified_files = modified_files,
	}
end

local function format_file_operations(details)
	if not details then return "" end
	local lines = {}
	if #(details.read_files or {}) > 0 then
		lines[#lines + 1] = "<read-files>"
		for _, path in ipairs(details.read_files) do
			lines[#lines + 1] = tostring(path)
		end
		lines[#lines + 1] = "</read-files>"
	end
	if #(details.modified_files or {}) > 0 then
		lines[#lines + 1] = "<modified-files>"
		for _, path in ipairs(details.modified_files) do
			lines[#lines + 1] = tostring(path)
		end
		lines[#lines + 1] = "</modified-files>"
	end
	if #lines == 0 then return "" end
	return table.concat(lines, "\n")
end

local function append_file_operations(text, details)
	local formatted = format_file_operations(details)
	if formatted == "" then
		return text
	end
	return tostring(text or "") .. "\n\n" .. formatted
end

local function summarize_tool_result(message)
	local text = message.text or ""
	local tool_name = message.tool_name or attr(text, "name") or "tool"
	local status = attr(text, "status") or "ok"
	local path = attr(text, "path")
	local command = attr(text, "command")
	local header = '<tool_result name="' .. tostring(tool_name) .. '" status="' .. tostring(status) .. '"'
	if path then
		header = header .. ' path="' .. path .. '"'
	end
	if command then
		header = header .. ' command="' .. command .. '"'
	end
	header = header .. ">"

	local detail
	if tool_name == "read" and path then
		detail = "[old read result slimmed; re-read " .. path .. " if exact contents or line tags are needed; original was " .. tostring(#text) .. " bytes, " .. tostring(line_count(text)) .. " lines]"
	elseif tool_name == "run" and command then
		detail = "[old run result slimmed; command=" .. compact_command(command, 160) .. "; original was " .. tostring(#text) .. " bytes]"
	else
		detail = "[old " .. tostring(tool_name) .. " result slimmed; original was " .. tostring(#text) .. " bytes]"
	end
	return table.concat({ header, detail, "</tool_result>" }, "\n")
end

function compaction.slim_history(session, opts)
	opts = opts or {}
	local messages = session.messages or {}
	local keep_recent = math.max(0, tonumber(opts.keep_recent_messages) or SLIM_KEEP_RECENT_MESSAGES)
	local keep_reads_per_path = math.max(1, tonumber(opts.keep_reads_per_path) or SLIM_KEEP_READS_PER_PATH)
	local max_bytes = math.max(1000, tonumber(opts.large_message_bytes) or SLIM_LARGE_MESSAGE_BYTES)
	local target_tokens = math.max(0, tonumber(opts.target_session_tokens) or SLIM_TARGET_SESSION_TOKENS)
	local recent_start = math.max(1, #messages - keep_recent + 1)
	local protected_read = {}
	local reads_seen_by_path = {}

	for i = #messages, 1, -1 do
		local message = messages[i]
		if message and message.tool_name == "read" then
			local path = attr(message.text, "path")
			if path then
				local count = reads_seen_by_path[path] or 0
				if count < keep_reads_per_path then
					protected_read[i] = true
					reads_seen_by_path[path] = count + 1
				end
			end
		end
	end

	local changed = 0
	local bytes_removed = 0
	local details = {}
	local function replace_message(index, message, replacement, reason)
		if replacement and #replacement < #(message.text or "") then
			local original_bytes = #(message.text or "")
			local label = message.tool_name and ("tool:" .. tostring(message.tool_name)) or tostring(message.role or "message")
			local path = attr(message.text, "path")
			message.text = replacement
			message.slimmed = true
			message.slimmed_from_bytes = original_bytes
			message.slimmed_reason = reason
			changed = changed + 1
			bytes_removed = bytes_removed + (original_bytes - #replacement)
			details[#details + 1] = {
				index = index,
				label = label,
				path = path,
				reason = reason,
				before = original_bytes,
				after = #replacement,
			}
			return true
		end
		return false
	end

	for i, message in ipairs(messages) do
		local text = message.text or ""
		if #text >= max_bytes and i < recent_start and not message.slimmed then
			local replacement
			if message.role == "assistant" and text:find("<tool_call", 1, true) then
				replacement = summarize_assistant_tool_calls(text)
			elseif message.tool_name then
				if message.tool_name ~= "read" or not protected_read[i] then
					replacement = summarize_tool_result(message)
				end
			end
			replace_message(i, message, replacement, "large-old-message")
		end
	end

	if target_tokens > 0 and session.estimated_session_tokens and session:estimated_session_tokens() > target_tokens then
		local candidates = {}
		for i, message in ipairs(messages) do
			local text = message.text or ""
			if i < recent_start and not message.slimmed and #text >= 1000 then
				if (message.tool_name == "read" and not protected_read[i])
					or (message.role == "assistant" and text:find("<tool_call", 1, true)) then
					candidates[#candidates + 1] = { index = i, bytes = #text, message = message }
				end
			end
		end
		table.sort(candidates, function(a, b) return a.bytes > b.bytes end)
		for _, candidate in ipairs(candidates) do
			if session:estimated_session_tokens() <= target_tokens then
				break
			end
			local message = candidate.message
			local replacement
			if message.role == "assistant" and (message.text or ""):find("<tool_call", 1, true) then
				replacement = summarize_assistant_tool_calls(message.text)
			elseif message.tool_name then
				replacement = summarize_tool_result(message)
			end
			replace_message(candidate.index, message, replacement, "target-budget")
		end
	end

	return changed > 0, changed, bytes_removed, details
end

local function message_brief(message)
	local label = message.tool_name and ("tool:" .. tostring(message.tool_name)) or tostring(message.role or "message")
	local text = tostring(message.text or ""):gsub("\r", ""):gsub("\n", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
	if #text > 180 then
		text = text:sub(1, 177) .. "..."
	end
	return "- " .. label .. ": " .. text
end

local function flush_coalesced(messages, bucket)
	if #bucket == 0 then return end
	local role = bucket[1].role
	local label = role == "assistant" and "assistant history" or "tool/user history"
	local lines = { "[old " .. label .. " coalesced; re-read files or rerun commands if exact evidence is needed]" }
	local ops = compaction.file_operations(bucket)
	local formatted_ops = format_file_operations(ops)
	if formatted_ops ~= "" then
		lines[#lines + 1] = formatted_ops
	end
	for _, message in ipairs(bucket) do
		lines[#lines + 1] = message_brief(message)
	end
	messages[#messages + 1] = {
		role = role,
		text = table.concat(lines, "\n"),
		coalesced = true,
		coalesced_count = #bucket,
	}
end

function compaction.coalesce_slimmed_history(session, opts)
	opts = opts or {}
	local messages = session.messages or {}
	local target_messages = math.max(0, tonumber(opts.target_messages) or SLIM_TARGET_MESSAGES)
	if target_messages <= 0 or #messages <= target_messages then
		return false, 0, 0
	end

	local keep_recent = math.max(0, tonumber(opts.keep_recent_messages) or SLIM_KEEP_RECENT_MESSAGES)
	local recent_start = math.max(1, #messages - keep_recent + 1)
	local out = {}
	local bucket = {}
	local coalesced_messages = 0
	local bytes_removed = 0

	for i, message in ipairs(messages) do
		local can_coalesce = i < recent_start and (message.slimmed or message.coalesced)
		if can_coalesce then
			if #bucket > 0 and bucket[1].role ~= message.role then
				flush_coalesced(out, bucket)
				bucket = {}
			end
			bucket[#bucket + 1] = message
			coalesced_messages = coalesced_messages + 1
			bytes_removed = bytes_removed + #(message.text or "")
		else
			flush_coalesced(out, bucket)
			bucket = {}
			out[#out + 1] = message
		end
	end
	flush_coalesced(out, bucket)

	if #out >= #messages then
		return false, 0, 0
	end
	for _, message in ipairs(out) do
		if message.coalesced then
			bytes_removed = bytes_removed - #(message.text or "")
		end
	end
	session.messages = out
	return true, coalesced_messages, math.max(0, bytes_removed)
end

function compaction.should_compact(messages)
	local tokens = compaction.estimate_total(messages)
	return context_limits.should_compact(tokens)
end

function compaction.find_cut_point(messages)
	local accumulated = 0
	local cut_index = 1

	for i = #messages, 1, -1 do
		accumulated = accumulated + compaction.estimate_tokens(messages[i])
		if accumulated >= KEEP_RECENT_TOKENS then
			cut_index = i
			break
		end
	end

	-- Snap to a user message boundary (don't cut mid-turn)
	for j = cut_index, #messages do
		if messages[j].role == "user" and not messages[j].tool_name then
			return j
		end
	end

	return cut_index
end

local function serialize_messages(messages)
	local parts = {}
	for _, msg in ipairs(messages) do
		local role_label
		if msg.role == "user" then
			if msg.tool_name then
				role_label = "Tool result (" .. msg.tool_name .. ")"
			else
				role_label = "User"
			end
		else
			role_label = "Assistant"
		end
		parts[#parts + 1] = "[" .. role_label .. "]: " .. (msg.text or "")
	end
	return table.concat(parts, "\n\n")
end

function compaction.generate_summary(messages_to_summarize, previous_summary, session)
	local conversation_text = serialize_messages(messages_to_summarize)

	local prompt_text = "<conversation>\n" .. conversation_text .. "\n</conversation>\n\n"
	if previous_summary then
		prompt_text = prompt_text .. "<previous-summary>\n" .. previous_summary .. "\n</previous-summary>\n\n"
		prompt_text = prompt_text .. UPDATE_SUMMARIZATION_PROMPT
	else
		prompt_text = prompt_text .. SUMMARIZATION_PROMPT
	end

	local provider = providers.load(session.credentials_path)
	local response = provider.complete({
		credentials_path = session.credentials_path,
		model = session.model,
		reasoning_effort = session.reasoning_effort,
		service_tier = session.service_tier,
		system_prompt = SUMMARIZATION_SYSTEM_PROMPT,
		messages = {
			{ role = "user", text = prompt_text },
		},
	})

	return response.text
end

function compaction.compact(session, opts)
	opts = opts or {}
	if not opts.force and not opts.bypass_threshold and not compaction.should_compact(session.messages) then
		return false
	end
	if #session.messages == 0 then
		return false
	end

	local cut_index
	if opts.force then
		cut_index = #session.messages + 1
	else
		cut_index = compaction.find_cut_point(session.messages)
	end

	-- Nothing worth summarizing
	if cut_index <= 1 then
		return false
	end

	local messages_to_summarize = {}
	for i = 1, cut_index - 1 do
		messages_to_summarize[#messages_to_summarize + 1] = session.messages[i]
	end
	local file_details = compaction.file_operations(messages_to_summarize, session.compaction_details)

	local summary = compaction.generate_summary(
		messages_to_summarize,
		session.compaction_summary,
		session
	)
	summary = append_file_operations(summary, file_details)

	-- Store summary for iterative updates
	session.compaction_summary = summary
	session.compaction_details = file_details

	-- Replace old messages with summary + kept messages
	local kept_messages = {}
	for i = cut_index, #session.messages do
		kept_messages[#kept_messages + 1] = session.messages[i]
	end

	session.messages = {}
	session.messages[1] = {
		role = "user",
		text = "[Context from previous conversation]\n\n" .. summary,
	}
	session.messages[2] = {
		role = "assistant",
		text = "Understood. I have the context from our previous conversation. How can I help?",
	}
	for _, msg in ipairs(kept_messages) do
		session.messages[#session.messages + 1] = msg
	end

	return true, #messages_to_summarize, compaction.estimate_total(session.messages)
end

return compaction
