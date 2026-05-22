local ls = require("agent.tools.ls")
local read = require("agent.tools.read")
local edit = require("agent.tools.edit")
local find_tool = require("agent.tools.find")
local grep = require("agent.tools.grep")
local run = require("agent.tools.run")
local write = require("agent.tools.write")
local mcp = require("agent.mcp")

local registry = {}

local tools = {
	edit = edit,
	find = find_tool,
	grep = grep,
	ls = ls,
	read = read,
	run = run,
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
	local names = { "ls", "read", "find", "grep", "edit", "write", "run" }
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

function registry.system_prompt()
	local base = [[
You have access to tools. You may include multiple tool calls in a single message — all will be executed in parallel.

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
- read: read a text file. Args: path (required), offset (optional, 1-indexed line), limit (optional, line count, default 2000).
- find: list files recursively. Args: path (optional), maxDepth (optional), pattern (optional, e.g. "*.lua").
- grep: search file contents. Args: pattern (required), path (optional), glob (optional).
- edit: replace lines in a file. JSON args: path, start_line, start_tag, end_line, end_tag. Raw content after JSON replaces all lines in the range. Tags are the 4-char CAS codes from read output (e.g. "10:Q8fA: code here") — they verify the file hasn't changed.
- write: create or overwrite a file. JSON args: path. Raw content after JSON becomes the file. Parent directories are created automatically.
- run: execute a shell command. Args: command, timeout (optional, milliseconds, default 120000). stdout+stderr captured.

## Strategy

- When you read a file, read the WHOLE thing (omit the limit arg). Don't use small limits like 50 or 100 — it wastes tool calls. One full read is better than three partial reads.
- For "describe/explain this project": find to see the tree, then read the key files fully. File names tell you a lot.
- For "how does X work": read the specific file(s). Use grep to locate them if needed.
- For edits: read the target file, make the change. Don't read unrelated files.
- Batch related tool calls in one message — they run in parallel.

## Rules

1. STOP IMMEDIATELY after your last </tool_call> tag. Do NOT write any text, explanation, thinking, or speculation after tool calls. The system will execute the tools and give you results — only THEN should you respond. A message with tool calls must contain NOTHING else.
2. PREFER edit over write for modifying existing files. Edit changes specific line ranges — write replaces the entire file.
3. For edit and write: put the raw file content DIRECTLY after the JSON metadata line. Do NOT put content inside the JSON. Do NOT escape newlines or quotes. Just write the code exactly as it should appear in the file. ONE EXCEPTION: if your content must contain the literal string "</tool_call>", split it in code (e.g. "</" .. "tool_call>") since that string terminates the tag.
4. If write or edit produces syntax errors, use edit to fix the specific broken lines — do NOT rewrite the entire file.
5. When editing, copy the line tags EXACTLY from the read output. They are 4-char codes like "Q8fA". If a tag doesn't match, the file changed — re-read it.
6. Do NOT re-read files already visible in a previous tool_result.
7. Do NOT guess file paths. Only read files confirmed by find/ls output.
8. NEVER output <tool_result> tags. Only the system produces those.
9. When the user gives you an explicit path, use it directly — don't find first.
10. Act immediately with tools. Do not ask for confirmation.
11. NEVER speculate about or summarize what tools will return. Wait for actual results.
]]

	if #mcp_tools > 0 then
		local mcp_section = "\nMCP (external) tools:\n"
		for _, tool in ipairs(mcp_tools) do
			local full_name = "mcp__" .. tool._server .. "__" .. tool.name
			local desc = tool.description or ""
			if #desc > 100 then desc = desc:sub(1, 100) .. "..." end
			mcp_section = mcp_section .. "- " .. full_name .. ": " .. desc .. "\n"

			-- Show input schema params
			if tool.inputSchema and tool.inputSchema.properties then
				local params = {}
				for k, v in pairs(tool.inputSchema.properties) do
					params[#params + 1] = k
				end
				if #params > 0 then
					mcp_section = mcp_section .. "  Args: " .. table.concat(params, ", ") .. "\n"
				end
			end
		end
		mcp_section = mcp_section .. "\nCall MCP tools like any other tool:\n"
		mcp_section = mcp_section .. '<tool_call name="mcp__server__tool_name">\n'
		mcp_section = mcp_section .. '{"arg1":"value1"}\n'
		mcp_section = mcp_section .. "</tool_call>\n"
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
