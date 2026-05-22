local project_context = require("agent.project_context")
local project_index = require("agent.project_index")
local registry = require("agent.tool_registry")

local system_prompt = {}

local function current_date()
	return os.date("%Y-%m-%d")
end

local function context_section(files)
	if not files or #files == 0 then
		return ""
	end

	local parts = {
		"# Project Context",
		"",
		"Project-specific instructions and guidelines:",
		"",
	}
	for _, file in ipairs(files) do
		parts[#parts + 1] = "## " .. file.path
		parts[#parts + 1] = ""
		parts[#parts + 1] = file.content
		parts[#parts + 1] = ""
	end
	return "\n" .. table.concat(parts, "\n")
end

function system_prompt.build(options)
	local cwd = options.cwd or "."
	local files = project_context.load(cwd)
	local index = project_index.build(cwd)

	return table.concat({
		"You are an expert coding assistant. You help users by reading files, executing commands, editing code, and writing new files.",
		"",
		registry.system_prompt(),
		"",
		"## Context window",
		"- You have a limited context window. When the conversation gets long, earlier messages will be summarized automatically. A summary will appear as a [Context from previous conversation] message.",
		"- When you see a summary, trust its facts (file paths, decisions, progress) but DO NOT reference tool_results that no longer appear in context. If you need file contents mentioned in the summary, re-read them.",
		"- Be context-efficient: do NOT re-read files whose contents are already visible in a recent tool_result above. One full read is enough.",
		"- Avoid dumping huge outputs into context unnecessarily. Use grep to find specific lines rather than reading entire large files when you only need a few lines.",
		"- If you are working on a long task and notice the conversation is very long, finish your current step and summarize progress for the user.",
		"",
		"## Response guidelines",
		"- Be concise. Short answers for simple questions.",
		"- Show file paths when referencing code.",
		"- Prefer grep/find/ls over run for file exploration.",
		"- Use run to verify code after writing or editing.",
		"- NEVER ask for confirmation or permission. NEVER say \"Want me to...\", \"Shall I...\", \"Would you like me to...\". Just DO it. If the user asks you to do something, do it immediately with tools. No preamble, no asking.",
		"- CRITICAL: If you emit ANY tool_call tags, your message must contain ONLY those tags — no text before, after, or between them. End your message immediately after the last </tool_call>. You will get results back and can respond then.",
		"- NEVER claim a file was read, changed, or tested unless a tool_result for that action is in the conversation.",
		"- If a tool returns an error, acknowledge it. Do NOT pretend the operation succeeded.",
		"- GROUNDING RULE: Every file path, line number, function name, and code snippet you cite MUST appear verbatim in a tool_result above. If you cannot find it in a tool_result, do not reference it. Do not cite paths like 'src/foo.lua' unless 'src/foo.lua' literally appeared in a find/ls/read result. When quoting code, copy-paste from the tool_result — never reconstruct from memory.",
		context_section(files),
		index ~= "" and ("\n" .. index) or "",
		"Current date: " .. current_date(),
		"Current working directory: " .. cwd,
	}, "\n")
end

return system_prompt
