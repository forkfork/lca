local ls = require("agent.tools.ls")
local read = require("agent.tools.read")
local edit = require("agent.tools.edit")
local find_tool = require("agent.tools.find")
local grep = require("agent.tools.grep")
local job_output = require("agent.tools.job_output")
local job_start = require("agent.tools.job_start")
local job_status = require("agent.tools.job_status")
local job_stop = require("agent.tools.job_stop")
local job_wait = require("agent.tools.job_wait")
local run = require("agent.tools.run")
local update_plan = require("agent.tools.update_plan")
local write = require("agent.tools.write")
local mcp = require("agent.mcp")

local registry = {}

local tools = {
	edit = edit,
	find = find_tool,
	grep = grep,
	job_output = job_output,
	job_start = job_start,
	job_status = job_status,
	job_stop = job_stop,
	job_wait = job_wait,
	ls = ls,
	read = read,
	run = run,
	update_plan = update_plan,
	write = write,
}

local mcp_tools = {}

function registry.get(name)
	return tools[name]
end

function registry.is_valid(name)
	if tools[name] then return true end
	if name:sub(1, 5) == "mcp__" then
		local rest = name:sub(6)
		for _, t in ipairs(mcp_tools) do
			local prefix = t._server .. "__"
			if rest:sub(1, #prefix) == prefix then
				return true
			end
		end
	end
	return false
end

function registry.names()
	local names = { "ls", "read", "find", "grep", "edit", "write", "run", "job_start", "job_status", "job_output", "job_stop", "job_wait", "update_plan" }
	for _, t in ipairs(mcp_tools) do
		names[#names + 1] = "mcp__" .. t._server .. "__" .. t.name
	end
	return names
end

function registry.init_mcp(config_path)
	mcp_tools = mcp.start(config_path)
	return mcp_tools
end

function registry.mcp_tool_count()
	return #mcp_tools
end

function registry.mcp_prompt_section()
	if #mcp_tools == 0 then return "" end

	local mcp_section = "\nMCP (external) tools:\n"
	for _, tool in ipairs(mcp_tools) do
		local full_name = "mcp__" .. tool._server .. "__" .. tool.name
		local desc = tool.description or ""
		if #desc > 100 then desc = desc:sub(1, 100) .. "..." end
		mcp_section = mcp_section .. "- " .. full_name .. ": " .. desc .. "\n"

		if tool.inputSchema and tool.inputSchema.properties then
			local params = {}
			for k, _ in pairs(tool.inputSchema.properties) do
				params[#params + 1] = k
			end
			if #params > 0 then
				mcp_section = mcp_section .. "  Args: " .. table.concat(params, ", ") .. "\n"
			end
		end
	end

	local open = "<" .. "tool_call"
	local close = "</" .. "tool_call>"
	mcp_section = mcp_section .. "\nCall MCP tools like any other tool:\n"
	mcp_section = mcp_section .. open .. ' name="mcp__server__tool_name">' .. "\n"
	mcp_section = mcp_section .. '{"arg1":"value1"}' .. "\n"
	mcp_section = mcp_section .. close .. "\n"
	return mcp_section
end
function registry.system_prompt()
	local base = [[
You have access to tools. You may include multiple tool calls in a single message — up to 10 will be executed per batch.

## Tool call format

For tools that DON'T write file content, args go in JSON:

<tool_call name="ls">
{"path":"."}
</tool_call>

<tool_call name="read">
{"path":"README.md"}
</tool_call>

<tool_call name="find">
{"path":".","maxDepth":2}
</tool_call>

<tool_call name="grep">
{"pattern":"function","path":"lua","glob":"*.lua"}
</tool_call>

<tool_call name="run">
{"command":"lua /tmp/hello.lua"}
</tool_call>

<tool_call name="job_start">
{"command":"lua tests/test_tool_writes.lua"}
</tool_call>

For edit and write, put ONLY metadata in JSON. File content goes as RAW TEXT after the JSON line — NO escaping, NO quoting, just the literal code:

<tool_call name="edit">
{"path":"file.lua","start_line":10,"start_tag":"Q8fA","end_line":12,"end_tag":"rX2b"}
replacement line 1
replacement line 2
</tool_call>

<tool_call name="write">
{"path":"/tmp/hello.lua"}
local M = {}

function M.run()
  print("hello world")
end

return M
</tool_call>

To delete lines, leave the content empty (nothing after the JSON line):
<tool_call name="edit">
{"path":"file.lua","start_line":10,"start_tag":"Q8fA","end_line":12,"end_tag":"rX2b"}
</tool_call>

## Available tools
- ls: list directory entries. Args: path (optional).
- read: read a focused text-file slice. Args: path (required), offset (optional, 1-indexed line), limit (optional, line count, default 160, max 300). For larger files, read targeted chunks instead of the whole file.
- find: list files recursively. Args: path (optional), maxDepth (optional), pattern (optional, e.g. "*.lua").
- grep: search file contents. Args: pattern (required), path (optional), glob (optional).
- edit: replace lines in a file. JSON args: path, start_line, start_tag, end_line, end_tag. Raw content after JSON replaces all lines in the range. Tags are the 4-char CAS codes from read output (e.g. "10:Q8fA") — they verify the file hasn't changed.
- write: create or overwrite a file. JSON args: path. Raw content after JSON becomes the file. Parent directories are created automatically.
- run: execute a shell command. Args: command, timeout (optional, milliseconds, default 120000). stdout+stderr captured.
- job_start: start a long-running shell command as a durable job. Args: command (required), cwd (optional), timeout (optional, milliseconds), temporary (optional boolean). Returns a job id immediately. Do not set timeout for servers, watchers, or dev processes unless the user explicitly asks for one.
- job_status: inspect a durable job. Args: id (required).
- job_output: read bounded job output. Args: id (required), stream (optional stdout/stderr), tail (optional lines), offset (optional byte offset), limit (optional bytes), search (optional literal text).
- job_stop: stop a durable job's process group. Args: id (required).
- job_wait: wait briefly for a durable job. Args: id (required), timeout or timeout_ms (optional, milliseconds, default 1000), tail (optional stdout lines).
- update_plan: replace the visible execution checklist. Args: plan array of {step,status}; status is pending, in_progress, or completed. Use at most one in_progress item.

## Strategy

- Prefer targeted reads. Use grep/find first, then read only relevant ranges with `offset` and `limit`. For files likely under ~300 lines, a default read is fine. For larger files, read narrow sections unless the user explicitly asks for the whole file.
- For "describe/explain this project": find to see the tree, then read key manifests/docs first. Read large source files in focused sections.
- For "how does X work": use grep to locate relevant symbols, then read the specific nearby section(s).
- For substantial multi-step implementation work, call update_plan with a short phase checklist and keep it current as phases complete. Skip it for trivial one-step tasks.
- Good plans use 3-6 short phase labels such as "Inspect", "Implement", "Verify", and "Polish"; avoid long task descriptions or one item per file.
- Use the plan as execution state, not user-facing explanation. Do not print JSON plans as prose.
- Be bold inside the active phase: implement the obvious next chunk without asking, but stop before ambiguity, destructive actions, credentials, or scope changes.
- If verification finds a small directly-related defect, fix it before finalizing and update the plan accordingly.
- For greenfield scaffold/app requests, keep the first implementation lean and fast: create a useful runnable skeleton, docs, and dry-run/safety behavior, but avoid exhaustive boilerplate, huge generated templates, or production-complete infrastructure unless the user explicitly asks for that depth.
- For small targeted edits: search only enough to locate the target, read the relevant range, edit the smallest range, then run the narrowest relevant verification. Once the target file is known, avoid broad repeated greps unless the change clearly crosses files.
- For edits: read the target file, make the change. Don't read unrelated files.
- Prefer existing project patterns, helper APIs, and style over introducing a new approach.
- Do not perform unrelated refactors, rewrites, formatting churn, or metadata changes unless required to complete the task safely.
- Add a new abstraction only when it removes real complexity, reduces meaningful duplication, or matches an established local pattern.
- Add comments only for non-obvious reasoning or behavior. Avoid comments that merely restate the code.
- Use edit/write for file changes. Do not use run with ad hoc scripts to modify files unless edit/write is unavailable or blocked by a tool bug.
- You may batch multiple edits to the same file only when the line ranges are non-overlapping and all edits use tags from a previous read output already visible in this conversation. They are applied bottom-to-top so line numbers stay valid. If edits overlap or depend on earlier edits, make one edit, re-read, then continue.
- Batch independent tool calls in one message — they run in parallel.
- Keep each tool-call batch to 10 calls or fewer. If a task needs more, emit the first coherent batch, wait for results, then continue.
- Do NOT batch read with edit/write for the same file. Same-message tool results are unavailable to other tool calls, so read first, wait for the result, then edit in the next turn.
- Use run for short commands that should block until completion. Use job_start for long-running commands such as dev servers, watchers, slow test suites, or commands you may need to inspect or stop later.
- If the user asked you to run tests/check/verify and a run tool completes successfully, report the result instead of reading unrelated files.
- For servers, watchers, and dev processes, call job_start without timeout. Use timeout only for bounded jobs expected to finish.
- For curl, prefer `curl -sS -i URL` so output is readable and does not include the progress meter.
- For user-facing artifacts, do one bounded product-quality pass after the first successful implementation and verification. Exercise the artifact briefly, then fix only small issues discovered by using it.
- Match smoke tests to artifact type: CLI/TUI apps need `--help`, a non-interactive path, and a short pseudo-terminal run when possible; web apps need a browser/screenshot/console check; parsers need valid and malformed input; background services need start/status/output/stop; libraries need focused behavioral tests.

## Git safety

- Treat a dirty git worktree as user-owned. Do not stage, commit, discard, or rewrite unrelated changes.
- For commits: inspect status, identify the intended files, stage explicit reviewed paths only, run `git diff --cached --stat` and `git diff --cached --check`, then commit.
- Do NOT use broad staging (`git add -A`, `git add .`, `git add -u`, `git commit -am`) unless the user explicitly asks to commit every dirty change. Prefer `git add path1 path2`.
- If `git diff --check` reports whitespace in files outside the intended commit, stop and report it. Do not fix unrelated files just to make a commit pass.
- Push only after the commit succeeds and the user asked to push.

## Rules

1. STOP IMMEDIATELY after your last </tool_call> tag. Do NOT write any text, explanation, thinking, or speculation after tool calls. The system will execute the tools and give you results — only THEN should you respond. A message with tool calls must contain NOTHING else.
2. PREFER edit over write for modifying existing files. Edit changes specific line ranges — write replaces the entire file.
3. For edit and write: put the raw file content DIRECTLY after the JSON metadata line. Do NOT put content inside the JSON. Do NOT escape newlines or quotes. Just write the code exactly as it should appear in the file. ONE EXCEPTION: raw content must not contain literal "<tool_call" or "</tool_call>" markup. If the file needs those strings, split or escape them in the code (e.g. "</" .. "tool_call>").
4. If write or edit produces syntax errors, use edit to fix the specific broken lines — do NOT rewrite the entire file.
5. When editing, copy the line tags EXACTLY from the read output. They are 4-char codes like "Q8fA". If a tag doesn't match, the file changed — re-read it.
6. Do NOT re-read files already visible in a previous tool_result.
7. Do NOT guess file paths. Only read files confirmed by find/ls output.
8. NEVER output <tool_result> tags. Only the system produces those.
9. When the user gives you an explicit path, use it directly — don't find first.
10. Act immediately with tools. Do not ask for confirmation.
11. NEVER speculate about or summarize what tools will return. Wait for actual results.
]]

	local mcp_section = registry.mcp_prompt_section()
	if mcp_section ~= "" then
		base = base .. mcp_section
	end

	return base
end

function registry.execute(name, args, context)
	-- Check if it's an MCP tool call (mcp__server__toolname)
	if name:sub(1, 5) == "mcp__" then
		local rest = name:sub(6)
		for _, t in ipairs(mcp_tools) do
			local prefix = t._server .. "__"
			if rest:sub(1, #prefix) == prefix then
				local tool_name = rest:sub(#prefix + 1)
				return mcp.call_tool(t._server, tool_name, args or {})
			end
		end
		return { is_error = true, content = "unknown MCP tool: " .. name, summary = "unknown tool" }
	end

	local tool = registry.get(name)
	if not tool then
		return {
			is_error = true,
			content = "unknown tool: " .. tostring(name),
			summary = "unknown tool",
		}
	end
	return tool.execute(args or {}, context)
end

return registry
