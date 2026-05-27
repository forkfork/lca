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

local function executable_available(name)
	local command = "command -v " .. name .. " >/dev/null 2>&1"
	local ok, why, code = os.execute(command)
	return ok == true or ok == 0 or (why == "exit" and code == 0)
end

local function brave_search_section()
	if not executable_available("bx") then
		return ""
	end

	return table.concat({
		"## Brave Search",
		"- A Brave Search CLI is available as `bx`.",
		"- Use `bx context \"search topic\" --max-tokens 2048` via the run tool to search the web and retrieve compact context.",
		"- Only invoke it when web search would materially help answer the user's request.",
	}, "\n")
end

local function mode_section(mode)
	if mode == "insanitywolf" then
		return table.concat({
			"## Mode",
			"- Mode is insanitywolf.",
			"- Aggressively continue through obvious, local, evidence-backed follow-through until completion or a guardrail.",
			"- Work in bounded improvement cycles: plan, implement, verify or exercise, assess impact and next improvements, then update the plan for the next cycle.",
			"- If verification for the active cycle passes, update the plan to mark that cycle complete before giving a final answer or starting follow-up work.",
			"- If you identify a clear follow-up improvement, do not merely mention it in the final answer; start the next cycle by updating the plan, unless a guardrail requires stopping.",
			"- Preserve enough tool budget to verify and close the active cycle; when warned about budget reserve, stop expanding scope and use remaining tools only for narrow fixes, verification, and plan closure.",
			"- Before starting any post-checkpoint cycle, write a short visible transition note explaining what completed, the next improvement you are about to pursue, why it is directly related and evidence-backed, and why it does not require user/product judgment.",
			"- After a valid post-checkpoint transition note, immediately update the plan and continue; do not ask permission, offer to continue, or wait for the user.",
			"- If you cannot explain that transition concretely, stop instead of updating the plan for another cycle.",
			"- After each cycle, pursue the highest-impact directly-related improvement while the next step is clear and evidence-backed.",
			"- Treat local hardening, including security hardening, as valid follow-through when it is evidence-backed and preserves the user's requested shape.",
			"- Stop when next steps become ambiguous, require user/product judgment, risk destructive actions, need external secrets or dependencies, broaden scope, or become unrelated nice-to-haves.",
			"- When stopping instead of starting another cycle, briefly offer concrete user-directed follow-ups without beginning them.",
			"- Stop after at most five improvement cycles in one turn, even if more polish is possible.",
		}, "\n")
	end
	return ""
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
		"- After completing work, mention any important technical decision or tradeoff naturally, without a labeled note. Assume the user is technical; avoid generic reassurance.",
		"- NEVER claim a file was read, changed, or tested unless a tool_result for that action is in the conversation.",
		"- If a tool returns an error, acknowledge it. Do NOT pretend the operation succeeded.",
		"- GROUNDING RULE: Every file path, line number, function name, and code snippet you cite MUST appear verbatim in a tool_result above. If you cannot find it in a tool_result, do not reference it. Do not cite paths like 'src/foo.lua' unless 'src/foo.lua' literally appeared in a find/ls/read result. When quoting code, copy-paste from the tool_result — never reconstruct from memory.",
		mode_section(options.flow),
		context_section(files),
		brave_search_section(),
		index ~= "" and ("\n" .. index) or "",
		"Current date: " .. current_date(),
		"Current working directory: " .. cwd,
	}, "\n")
end

return system_prompt
