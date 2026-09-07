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
	multi_edit = edit,
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
local multi_edit_enabled = false

function registry.set_multi_edit_enabled(enabled)
	multi_edit_enabled = enabled ~= false
end

function registry.multi_edit_enabled()
	return multi_edit_enabled
end

function registry.get(name)
	if name == "multi_edit" and not multi_edit_enabled then return nil end
	return tools[name]
end

function registry.is_valid(name)
	if registry.get(name) then return true end
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
	if multi_edit_enabled then table.insert(names, 6, "multi_edit") end
	for _, t in ipairs(mcp_tools) do
		names[#names + 1] = "mcp__" .. t._server .. "__" .. t.name
	end
	return names
end

function registry.init_mcp(config_path)
	mcp_tools = mcp.start(config_path)
	return mcp_tools
end

local function object_schema(properties, required)
	local schema = {
		type = "object",
		properties = properties or {},
		additionalProperties = false,
	}
	if required and #required > 0 then schema.required = required end
	return schema
end

local native_tool_specs = {
	ls = { "List directory entries.", object_schema({ path = { type = "string", description = "Directory path; defaults to the working directory." } }) },
	read = { "Read a focused text-file slice with line numbers and stale-edit tags.", object_schema({
		path = { type = "string" }, offset = { type = "integer", minimum = 1 }, limit = { type = "integer", minimum = 1, maximum = 300 },
	}, { "path" }) },
	find = { "List files recursively.", object_schema({
		path = { type = "string" }, maxDepth = { type = "integer", minimum = 1 }, pattern = { type = "string" },
	}) },
	grep = { "Search file contents and return bounded tagged source context around matches. Matching ranges can be edited directly without a follow-up read.", object_schema({
		pattern = { type = "string" }, path = { type = "string" }, glob = { type = "string" },
	}, { "pattern" }) },
	edit = { "Replace a tagged line range. Inspect it with read or grep first and copy its line numbers and four-character tags exactly.", object_schema({
		path = { type = "string" }, start_line = { type = "integer", minimum = 1 }, start_tag = { type = "string" },
		end_line = { type = "integer", minimum = 1 }, end_tag = { type = "string" }, content = { type = "string", description = "Literal replacement text; empty deletes the range." },
	}, { "path", "start_line", "start_tag", "end_line", "end_tag", "content" }) },
	multi_edit = { "Atomically replace multiple non-overlapping tagged ranges in one file. All tags are checked against one snapshot and no hunk is written if any hunk is stale, invalid, overlapping, or introduces a syntax error.", object_schema({
		path = { type = "string" },
		edits = { type = "array", minItems = 1, maxItems = 20, items = object_schema({
			start_line = { type = "integer", minimum = 1 }, start_tag = { type = "string" },
			end_line = { type = "integer", minimum = 1 }, end_tag = { type = "string" },
			content = { type = "string", description = "Literal replacement text; empty deletes the range." },
		}, { "start_line", "start_tag", "end_line", "end_tag", "content" }) },
	}, { "path", "edits" }) },
	write = { "Create or overwrite a file, creating parent directories when needed.", object_schema({
		path = { type = "string" }, content = { type = "string", description = "Complete literal file content." },
	}, { "path", "content" }) },
	run = { "Execute a bounded shell command and return combined stdout and stderr.", object_schema({
		command = { type = "string" }, timeout = { type = "integer", minimum = 1, description = "Timeout in milliseconds; default 120000." },
	}, { "command" }) },
	job_start = { "Start a durable background command and return its job id.", object_schema({
		command = { type = "string" }, cwd = { type = "string" }, timeout = { type = "integer", minimum = 1 }, temporary = { type = "boolean" },
	}, { "command" }) },
	job_status = { "Inspect a durable background job.", object_schema({ id = { type = "string" }, cwd = { type = "string" } }, { "id" }) },
	job_output = { "Read bounded output from a durable background job.", object_schema({
		id = { type = "string" }, cwd = { type = "string" }, stream = { type = "string", enum = { "stdout", "stderr" } },
		tail = { type = "integer", minimum = 1 }, offset = { type = "integer", minimum = 0 }, limit = { type = "integer", minimum = 1 }, search = { type = "string" },
	}, { "id" }) },
	job_stop = { "Stop a durable background job process group.", object_schema({ id = { type = "string" }, cwd = { type = "string" } }, { "id" }) },
	job_wait = { "Wait briefly for a durable job and return its status and recent output.", object_schema({
		id = { type = "string" }, cwd = { type = "string" }, timeout_ms = { type = "integer", minimum = 1 }, tail = { type = "integer", minimum = 1 }, stream = { type = "string", enum = { "stdout", "stderr" } },
	}, { "id" }) },
	update_plan = { "Create or replace the execution checklist. For a substantial normal task in an unfamiliar repository, first gather one bounded inspection batch, then call this once with a specific journey {destination,approach,proof}; avoid generic inspection steps. The harness turns real reads, mutations, and verification into visible progress and closes the checklist with the final answer. Insanitywolf cycles must still update it explicitly. Use at most one in_progress item.", object_schema({
		plan = { type = "array", items = object_schema({ step = { type = "string" }, status = { type = "string", enum = { "pending", "in_progress", "completed" } } }, { "step", "status" }) },
		journey = object_schema({
			destination = { type = "string", description = "Short user-relevant description of what will exist when the task succeeds." },
			approach = { type = "string", description = "Short concrete description of the shape or mechanism now emerging." },
			proof = { type = "string", description = "Short description of the evidence that will establish success." },
		}, { "destination", "approach", "proof" }),
		wolf = object_schema({
			title = { type = "string", description = "Short name of the chosen user-facing capability." },
			payoff = { type = "string", description = "Concrete user-visible payoff." },
			proof = { type = "string", description = "How the user can tell the capability works." },
		}, { "title", "payoff" }),
	}, { "plan" }) },
}

function registry.native_tools()
	local definitions = {}
	for _, name in ipairs(registry.names()) do
		local spec = native_tool_specs[name]
		if spec then
			local parameters = spec[2]
			definitions[#definitions + 1] = { type = "function", name = name, description = spec[1], parameters = parameters, strict = false }
		else
			for _, tool in ipairs(mcp_tools) do
				if name == "mcp__" .. tool._server .. "__" .. tool.name then
					definitions[#definitions + 1] = {
						type = "function", name = name, description = tool.description or "MCP tool",
						parameters = tool.inputSchema or object_schema(), strict = false,
					}
					break
				end
			end
		end
	end
	return definitions
end

function registry.native_system_prompt()
	local prompt = [[
You have native tools for inspecting files, editing code, running commands, managing background jobs, and updating plans. Use them directly; never print or imitate tool-call markup.

## Working strategy
- Match evidence to the question. A working directory is not relevant by default: inspect local files only to resolve a specific project-dependent uncertainty. For general web research unrelated to the project, use web evidence and answer without inventorying the workspace.
- Once authoritative evidence resolves the question, synthesize the answer instead of opening an unrelated inspection loop.
- Match research depth to the requested decision. Stop when sources support the material distinctions and a recommendation; do not turn an informal comparison into an exhaustive report.
- For current external APIs and infrastructure, ground high-risk contract seams—names, signatures, schemas, permissions, and regions—in primary documentation or official samples before writing. Verify those seams before low-risk dependency or prose cleanup, and preserve the source URLs.
- Interpret “do not run it” as prohibiting execution of the generated program and side-effectful actions such as installs or deployments. Unless the user forbids all command execution, still perform safe static checks that do not execute the program or change external state.
- For project-orientation questions, inspect authoritative documentation, package metadata, the repository tree, and representative source in one parallel batch when possible. Do not run tests or builds merely to describe a project.
- Give a concise, decision-useful orientation: identity and purpose, the main user workflow, important architectural boundaries, and current implementation reality. Distinguish documented intent from inspected code, including concrete stubs and documented components absent from the tree when supported by evidence. End with exactly three useful starting files and why each matters.
- Prefer targeted find/grep/read calls. Do not re-read content already returned unless it may have changed.
- For edits, inspect the target with read or tagged grep evidence first, then use its exact line numbers and four-character tags. Make the smallest coherent change and run focused verification.
- Batch independent inspection calls when useful. Do not call read and edit/write for the same file in parallel.
- Use run for bounded commands and job_start for servers, watchers, or long-running commands.
- For work with several genuinely dependent phases, gather one bounded initial inspection batch, then create one short execution plan. Include a concrete journey destination, approach, and proof so the interface can show where the work is going. Avoid generic plan steps such as “inspect repository structure.” Skip plans for trivial requests.
- For small, fully specified builds, proceed directly from inspection to implementation and verification, even when several files are involved. When a plan is useful and the first edits are already determined, issue the plan and edits in the same response.
- Minimize model round trips without guessing across dependencies. In each response, call every independent tool whose arguments are already known.
- When implementation and test-file contents are already determined, write them in the same response, then verify after both writes finish.
- In normal mode, call update_plan at most once. The harness closes that checklist when you give the final answer, so never rewrite it merely to advance statuses or mark completion. Insanitywolf has separate explicit plan rules.
- After inspection, use multi_edit when two or more non-overlapping replacements in one file are already known; use edit for one replacement. Never use multi_edit for dependent or overlapping changes.
- Group known import and body replacements against the same inspected file version. An earlier insertion can shift later line numbers: do not submit a later edit using tags from before that insertion. Batch independent replacements together; re-read before a dependent edit.
- Once edits succeed, combine known focused checks into one run command using && when later checks do not need model judgment.
- Do not split plan updates, edits, or redundant verification into separate model turns merely to narrate progress. Start a new tool round only when its arguments depend on results from the previous round.
- Preserve existing project patterns and user changes. Avoid unrelated refactors and destructive git operations.
- Never claim a file was read, changed, or tested unless the corresponding tool result established it.
- If a tool fails, use its actual error to recover or explain the blocker.
]]
	if not multi_edit_enabled then
		prompt = prompt:gsub("%- After inspection, use multi_edit.-\n", "- After inspection, batch non-overlapping tagged edits whose replacements are all known.\n")
	end
	return prompt
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

	return mcp_section
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
