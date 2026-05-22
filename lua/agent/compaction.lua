local providers = require("agent.providers")

local compaction = {}

local CONTEXT_WINDOW = 200000
local RESERVE_TOKENS = 16384
local KEEP_RECENT_TOKENS = 20000

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

function compaction.should_compact(messages)
	local tokens = compaction.estimate_total(messages)
	return tokens > (CONTEXT_WINDOW - RESERVE_TOKENS)
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
		system_prompt = SUMMARIZATION_SYSTEM_PROMPT,
		messages = {
			{ role = "user", text = prompt_text },
		},
	})

	return response.text
end

function compaction.compact(session)
	if not compaction.should_compact(session.messages) then
		return false
	end

	local cut_index = compaction.find_cut_point(session.messages)

	-- Nothing worth summarizing
	if cut_index <= 1 then
		return false
	end

	local messages_to_summarize = {}
	for i = 1, cut_index - 1 do
		messages_to_summarize[#messages_to_summarize + 1] = session.messages[i]
	end

	local summary = compaction.generate_summary(
		messages_to_summarize,
		session.compaction_summary,
		session
	)

	-- Store summary for iterative updates
	session.compaction_summary = summary

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
