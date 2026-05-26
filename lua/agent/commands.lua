local commands = {}
local context_limits = require("agent.context_limits")
local jobs = require("agent.jobs")

local HELP = [[
/help                 show commands
/status               show cwd, model, credentials, and turn count
/plan                 show current execution plan
/context [n]          show context/token breakdown and largest messages
/jobs [--all]         list background jobs
/job <id>             show durable job status
/job-output <id> [n]  show last n stdout lines for a durable job
/job-stop <id>        stop a durable job
/job-wait <id> [ms]   wait briefly for a durable job
/job-prune [days]     prune old finished jobs
/model <id>           change model
/reasoning <effort>   set reasoning effort: none, low, medium, high, xhigh
/service-tier <tier>  set service tier: auto, default, flex, priority
/flow [mode]          show or set flow mode: off, on, insanitywolf
/credentials <path>   change credentials file
/explain [path]       explain a project using read-only inspection
/save [path]          save session to file (default: .lca-session.json)
/load [path]          load session from file (default: .lca-session.json)
/compact              summarize the current transcript now
/clear                clear session transcript and saved session file
/exit                 quit and save session
]]

local function trim(value)
	return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function fmt_num(value)
	if value == nil then return "-" end
	local n = tonumber(value)
	if n then return tostring(math.floor(n)) end
	return tostring(value)
end

local function compact_command(value)
	value = tostring(value or "")
	value = value:gsub("%s+", " ")
	if #value > 80 then
		value = value:sub(1, 77) .. "..."
	end
	return value
end

local function estimate_tokens(value)
	if type(value) ~= "string" then return 0 end
	return math.ceil(#value / 4)
end

local function format_token_count(tokens)
	if tokens >= 1000 then
		return "~" .. tostring(math.floor((tokens + 500) / 1000)) .. "k"
	end
	return tostring(tokens)
end

local function format_cache_trend(history)
	if type(history) ~= "table" or #history == 0 then
		return nil
	end
	local start = math.max(1, #history - 4)
	local parts = {}
	for i = start, #history do
		local sample = history[i]
		local pct = tonumber(sample.cached_percent)
		if not pct then
			local prompt = tonumber(sample.prompt_tokens) or 0
			local cached = tonumber(sample.cached_tokens) or 0
			pct = prompt > 0 and (cached / prompt * 100) or 0
		end
		parts[#parts + 1] = string.format("%.1f%%", pct)
	end
	return table.concat(parts, " -> ")
end

local function message_label(message)
	if message.tool_name then
		return "tool:" .. tostring(message.tool_name)
	end
	return tostring(message.role or "unknown")
end

local function preview_text(text)
	text = tostring(text or ""):gsub("\r", ""):gsub("\n", " "):gsub("%s+", " "):match("^%s*(.-)%s*$")
	if #text > 90 then
		return text:sub(1, 87) .. "..."
	end
	return text
end

local function format_context_report(session, limit)
	limit = math.max(1, math.min(tonumber(limit) or 8, 30))
	local usage_tokens, usage_estimate
	if session.estimated_model_input_tokens_usage_aware then
		usage_tokens, usage_estimate = session:estimated_model_input_tokens_usage_aware()
	end
	local session_tokens = session:estimated_session_tokens()
	local system_tokens = session:estimated_system_prompt_tokens()
	local mcp_prompt_tokens = session:estimated_mcp_prompt_tokens()
	local model_tokens = session_tokens + system_tokens + mcp_prompt_tokens
	local mcp_result_tokens = session:estimated_mcp_tokens()
	local context_window = context_limits.context_window(session.model)
	local reserve_tokens = context_limits.reserve_tokens()
	local auto_compact_threshold = context_limits.auto_compact_threshold(session.model)

	local lines = {
		"context",
		"  model input: " .. format_token_count(model_tokens) .. " tokens",
		"  session:     " .. format_token_count(session_tokens) .. " tokens (" .. tostring(#session.messages) .. " messages)",
		"  system:      " .. format_token_count(system_tokens) .. " tokens",
		"  MCP prompt:  " .. format_token_count(mcp_prompt_tokens) .. " tokens",
		"  MCP results: " .. format_token_count(mcp_result_tokens) .. " tokens",
		"  window:      " .. format_token_count(context_window) .. " tokens",
		"  reserve:     " .. format_token_count(reserve_tokens) .. " tokens",
		"  auto compact:" .. (auto_compact_threshold <= 0 and " disabled" or (" " .. format_token_count(auto_compact_threshold) .. " tokens")),
		"  compacted:   " .. (session.compaction_summary and "yes" or "no"),
		"",
	}
	if usage_estimate then
		lines[#lines + 1] = "usage-aware estimate"
		lines[#lines + 1] = "  model input: " .. format_token_count(usage_tokens) .. " tokens"
		lines[#lines + 1] = "  last usage:  " .. format_token_count(usage_estimate.usage_tokens) .. " tokens at message #" .. tostring(usage_estimate.message_index)
		lines[#lines + 1] = "  trailing:    " .. format_token_count(usage_estimate.trailing_tokens) .. " tokens"
		local usage = session.last_usage or {}
		lines[#lines + 1] = "  cache read:  " .. format_token_count(tonumber(usage.cached_tokens) or 0) .. " tokens"
		local trend = format_cache_trend(session.usage_history)
		if trend then
			lines[#lines + 1] = "  cache trend: " .. trend
		end
		lines[#lines + 1] = ""
	end

	local buckets = {}
	local largest = {}
	local slimmed_count = 0
	local slimmed_bytes_removed = 0
	for index, message in ipairs(session.messages) do
		local label = message_label(message)
		local tokens = estimate_tokens(message.role) + estimate_tokens(message.tool_name) + estimate_tokens(message.text) + 6
		buckets[label] = (buckets[label] or 0) + tokens
		if message.slimmed then
			slimmed_count = slimmed_count + 1
			local before = tonumber(message.slimmed_from_bytes) or #(message.text or "")
			slimmed_bytes_removed = slimmed_bytes_removed + math.max(0, before - #(message.text or ""))
		end
		largest[#largest + 1] = {
			index = index,
			label = label,
			tokens = tokens,
			bytes = #(message.text or ""),
			preview = preview_text(message.text),
		}
	end

	local bucket_rows = {}
	for label, tokens in pairs(buckets) do
		bucket_rows[#bucket_rows + 1] = { label = label, tokens = tokens }
	end
	table.sort(bucket_rows, function(a, b) return a.tokens > b.tokens end)

	lines[#lines + 1] = "by source"
	for _, row in ipairs(bucket_rows) do
		lines[#lines + 1] = string.format("  %-16s %8s tokens", row.label, format_token_count(row.tokens))
	end
	if slimmed_count > 0 then
		lines[#lines + 1] = ""
		lines[#lines + 1] = "slimmed"
		lines[#lines + 1] = string.format("  %d messages, %d bytes removed", slimmed_count, slimmed_bytes_removed)
	end
	if session.compaction_details then
		local read_files = session.compaction_details.read_files or session.compaction_details.readFiles or {}
		local modified_files = session.compaction_details.modified_files or session.compaction_details.modifiedFiles or {}
		if #read_files > 0 or #modified_files > 0 then
			lines[#lines + 1] = ""
			lines[#lines + 1] = "file context"
			if #read_files > 0 then
				lines[#lines + 1] = "  read:     " .. table.concat(read_files, ", ")
			end
			if #modified_files > 0 then
				lines[#lines + 1] = "  modified: " .. table.concat(modified_files, ", ")
			end
		end
	end

	table.sort(largest, function(a, b) return a.tokens > b.tokens end)
	lines[#lines + 1] = ""
	lines[#lines + 1] = "largest messages"
	for i = 1, math.min(limit, #largest) do
		local item = largest[i]
		lines[#lines + 1] = string.format(
			"  #%d %-16s %8s tokens  %d bytes  %s",
			item.index,
			item.label,
			format_token_count(item.tokens),
			item.bytes,
			item.preview
		)
	end

	return table.concat(lines, "\n")
end

local function format_job(job)
	local lines = {
		"id: " .. tostring(job.id),
		"status: " .. tostring(job.status),
		"command: " .. tostring(job.command),
		"cwd: " .. tostring(job.cwd),
		"pid: " .. fmt_num(job.pid),
		"pgid: " .. fmt_num(job.pgid),
		"alive: " .. tostring(job.alive == true),
		"started_at: " .. tostring(job.started_at or "-"),
	}
	if job.finished_at then lines[#lines + 1] = "finished_at: " .. tostring(job.finished_at) end
	if job.exit_code ~= nil then lines[#lines + 1] = "exit_code: " .. fmt_num(job.exit_code) end
	if job.timeout ~= nil then lines[#lines + 1] = "timeout: " .. fmt_num(job.timeout) .. "ms" end
	if job.stdout then lines[#lines + 1] = "stdout: " .. tostring(job.stdout) end
	if job.stderr then lines[#lines + 1] = "stderr: " .. tostring(job.stderr) end
	return table.concat(lines, "\n")
end

local function single_job_id(session)
	local visible = jobs.visible(session.cwd)
	if #visible == 1 then
		return visible[1].id
	end
	local all = jobs.list(session.cwd)
	if #all == 1 then
		return all[1].id
	end
	return nil
end

local function resolve_job_args(name, rest, session, numeric_remainder)
	local first, remainder = rest:match("^(%S+)%s*(.*)$")
	if first and first:match("^job_%d+$") then
		return first, trim(remainder or "")
	end
	local id = single_job_id(session)
	if not id then
		return nil, nil, "usage: /" .. name .. " <id>"
	end
	if first and first ~= "" then
		if numeric_remainder and tonumber(first) then
			return id, first
		end
		return nil, nil, "usage: /" .. name .. " <id>"
	end
	return id, ""
end

local function dispatch_job_command(name, rest, session, ui)
	if name == "jobs" then
		local all = rest == "--all" or rest == "all"
		local list = jobs.visible(session.cwd, { all = all })
		if #list == 0 then
			ui.muted(all and "no jobs" or "no active jobs")
			return true
		end
		if ui.jobs then
			ui.jobs(list, { all = all })
		else
			local lines = {}
			for _, job in ipairs(list) do
				lines[#lines + 1] = string.format("%s  %s  pid=%s  %s",
					tostring(job.id),
					tostring(job.status),
					fmt_num(job.pid),
					compact_command(job.command))
			end
			ui.block(table.concat(lines, "\n"))
		end
		return true
	end

	if name == "job-prune" then
		local days = tonumber(rest ~= "" and rest or nil)
		local result = jobs.prune(session.cwd, { days = days, min_finished = 0 })
		if result.count == 0 then
			ui.muted("no jobs pruned")
		else
			ui.muted("pruned " .. tostring(result.count) .. " jobs: " .. table.concat(result.pruned, ", "))
		end
		return true
	end

	local numeric_remainder = name == "job-output" or name == "job-wait"
	local id, tail_or_timeout, arg_err = resolve_job_args(name, rest, session, numeric_remainder)
	if not id then
		ui.error(arg_err)
		return true
	end

	if name == "job" or name == "job-status" then
		local job, err = jobs.status(session.cwd, id)
		if not job then ui.error(err); return true end
		if ui.job_detail then
			ui.job_detail(job)
		else
			ui.block(format_job(job))
		end
	elseif name == "job-output" then
		local tail = tonumber(trim(tail_or_timeout or "")) or 50
		local output, err = jobs.output(session.cwd, id, { tail = tail })
		if not output then ui.error(err); return true end
		if ui.job_output then
			ui.job_output(id, output, { tail = tail })
		else
			ui.block(output ~= "" and output or "(no output)")
		end
	elseif name == "job-stop" then
		local job, err = jobs.stop(session.cwd, id)
		if not job then ui.error(err); return true end
		ui.muted("job " .. tostring(job.id) .. ": " .. tostring(job.status))
	elseif name == "job-wait" then
		local timeout = tonumber(trim(tail_or_timeout or "")) or 1000
		local job, err = jobs.wait(session.cwd, id, { timeout = timeout })
		if not job then ui.error(err); return true end
		if ui.job_detail then
			ui.job_detail(job)
		else
			ui.block(format_job(job))
		end
	else
		return false
	end
	return true
end

function commands.dispatch(line, session, ui)
	local name, rest = line:match("^/([^%s]+)%s*(.*)$")
	if not name then
		return false
	end
	rest = trim(rest or "")

	if name == "help" then
		ui.block(HELP)
	elseif name == "status" then
		ui.status(session)
	elseif name == "plan" then
		if ui.plan then
			ui.plan(session.plan)
		elseif session.plan and #session.plan > 0 then
			ui.block("plan: " .. tostring(#session.plan) .. " steps")
		else
			ui.muted("  no active plan")
		end
	elseif name == "context" then
		ui.block(format_context_report(session, rest))
	elseif name == "jobs" or name == "job" or name == "job-status" or name == "job-output" or name == "job-stop" or name == "job-wait" or name == "job-prune" then
		dispatch_job_command(name, rest, session, ui)
	elseif name == "model" then
		if rest == "" then
			ui.error("usage: /model <id>")
		else
			session.model = rest
			ui.muted("model: " .. session.model)
		end
	elseif name == "reasoning" then
		if rest == "" then
			session.reasoning_effort = nil
			ui.muted("reasoning: default")
		else
			local ok, value = pcall(function()
				return require("agent.session").resolve_reasoning_effort(rest)
			end)
			if not ok then
				ui.error(tostring(value))
			else
				session.reasoning_effort = value
				ui.muted("reasoning: " .. session.reasoning_effort)
			end
		end
	elseif name == "service-tier" or name == "tier" then
		if rest == "" then
			session.service_tier = nil
			ui.muted("service tier: default")
		else
			local ok, value = pcall(function()
				return require("agent.session").resolve_service_tier(rest)
			end)
			if not ok then
				ui.error(tostring(value))
			else
				session.service_tier = value
				ui.muted("service tier: " .. session.service_tier)
			end
		end
	elseif name == "flow" then
		if rest == "" then
			ui.muted("flow: " .. (session.flow or "off"))
		else
			local ok, value = pcall(function()
				return require("agent.session").resolve_flow(rest)
			end)
			if not ok then
				ui.error("usage: /flow off|on|insanitywolf")
			else
				session.flow = value
				session.system_prompt = nil
				session.system_prompt_version = nil
				ui.muted("flow: " .. session.flow)
			end
		end
	elseif name == "credentials" then
		if rest == "" then
			ui.error("usage: /credentials <path>")
		else
			session.credentials_path = rest
			ui.muted("credentials: " .. session.credentials_path)
		end
		local target = rest ~= "" and rest or "."
		session:add_user(table.concat({
			"Explain the project at " .. target .. ".",
			"",
			"Use tools first. Follow this workflow:",
			"1. ls " .. target,
			"2. find " .. target .. " with maxDepth 2",
			"3. read README, AGENTS, manifest, package, build, or config files that exist",
			"4. grep for likely entrypoints and important functions if the structure is unclear",
			"5. read the central source files",
			"6. answer with: what it does, how it is structured, main entrypoints, how to run/check it, and where to make common changes",
			"",
			"Do not edit or write files for this explanation.",
		}, "\n"))
		return "run"
	elseif name == "clear" then
		session:clear()
		local ok, err = session:save()
		if ok then
			ui.muted("session cleared and saved to " .. session.DEFAULT_SESSION_FILE)
		else
			ui.error("session cleared in memory but save failed: " .. (err or "unknown error"))
		end
	elseif name == "save" then
		local path = rest ~= "" and rest or nil
		local ok, err = session:save(path)
		if ok then
			ui.muted("session saved to " .. (path or session.DEFAULT_SESSION_FILE))
		else
			ui.error(err)
		end
	elseif name == "load" then
		local path = rest ~= "" and rest or nil
		local ok, err = session:load(path)
		if ok then
			ui.muted(session:load_message(path))
		else
			ui.error(err)
		end
	elseif name == "compact" then
		local compaction = require("agent.compaction")
		ui.muted("compacting transcript...")
		local ok, compacted, msgs_removed, new_tokens = pcall(function()
			return compaction.compact(session, { force = true })
		end)
		if not ok then
			ui.error(tostring(compacted))
		elseif compacted then
			ui.compaction(msgs_removed, new_tokens)
		else
			ui.muted("nothing to compact")
		end
	elseif name == "exit" or name == "quit" then
		return true
	else
		ui.error("unknown command: /" .. name)
	end

	return false
end

return commands
