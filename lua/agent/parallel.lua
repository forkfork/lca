local uv = require("luv")
local registry = require("agent.tool_registry")
local path_util = require("agent.util.path")
local shell_util = require("agent.util.shell")

local parallel = {}

local SHELL_TOOLS = {
	ls = true,
	find = true,
	grep = true,
}

local FILE_MUTATION_TOOLS = {
	edit = true,
	write = true,
}

local FILE_READ_TOOLS = {
	read = true,
}

local START_EVENT_TOOLS = {
	find = true,
	grep = true,
	job_output = true,
	job_start = true,
	job_status = true,
	job_stop = true,
	job_wait = true,
	ls = true,
	run = true,
	shell = true,
}

local function emit_start(on_tool, tc)
	if on_tool and START_EVENT_TOOLS[tc.name] then
		on_tool({ type = "tool", phase = "start", name = tc.name, args = tc.args })
	end
end

local function file_mutation_target(tc, context)
	if not FILE_MUTATION_TOOLS[tc.name] then
		return nil
	end
	local args = tc.args or {}
	if not args.path or args.path == "" then
		return nil
	end
	return path_util.resolve(args.path, context.cwd or ".")
end

local function file_read_target(tc, context)
	if not FILE_READ_TOOLS[tc.name] then
		return nil
	end
	local args = tc.args or {}
	if not args.path or args.path == "" then
		return nil
	end
	return path_util.resolve(args.path, context.cwd or ".")
end

local function stale_batch_result(path)
	return {
		is_error = true,
		content = "A previous tool call in this batch already modified " .. path .. ". Re-read the file before editing or writing it again.",
		summary = "stale batch mutation",
	}
end

local function dependent_batch_result(path)
	return {
		is_error = true,
		ui_state = "deferred",
		content = "This batch both reads and modifies " .. path .. ". Tool results from the same assistant message are not available to later tool calls; read the file first, then edit or write it in the next turn.",
		summary = "dependent batch mutation",
	}
end

local function edit_range(tc)
	if tc.name ~= "edit" then
		return nil
	end
	local args = tc.args or {}
	if not args.start_line or not args.start_tag or not args.end_tag then
		return nil
	end
	local start_line = math.floor(tonumber(args.start_line) or 0)
	local end_line = math.floor(tonumber(args.end_line) or start_line)
	if start_line < 1 or end_line < start_line then
		return nil
	end
	return start_line, end_line
end

local function safe_tagged_edit_group(items)
	for _, item in ipairs(items) do
		local start_line, end_line = edit_range(item.tc)
		if not start_line then
			return false
		end
		item.start_line = start_line
		item.end_line = end_line
	end

	table.sort(items, function(a, b)
		if a.start_line == b.start_line then
			return a.end_line > b.end_line
		end
		return a.start_line < b.start_line
	end)

	local previous_end = 0
	for _, item in ipairs(items) do
		if item.start_line <= previous_end then
			return false
		end
		previous_end = item.end_line
	end

	return true
end

local function collect_edit_groups(other_batch, context)
	local groups = {}
	for _, item in ipairs(other_batch) do
		local target = file_mutation_target(item.tc, context)
		if target and item.tc.name == "edit" then
			groups[target] = groups[target] or {}
			groups[target][#groups[target] + 1] = item
		end
	end

	local safe_groups = {}
	for target, items in pairs(groups) do
		if #items > 1 and safe_tagged_edit_group(items) then
			safe_groups[target] = items
		end
	end
	return safe_groups
end

local function collect_read_targets(other_batch, context)
	local targets = {}
	for _, item in ipairs(other_batch) do
		local target = file_read_target(item.tc, context)
		if target then
			targets[target] = true
		end
	end
	return targets
end

local function tool_to_command(name, args, context)
	local cwd = context.cwd or "."

	if name == "ls" then
		local target = path_util.resolve(args.path or ".", cwd)
		return "ls -1 " .. shell_util.quote(target) .. " 2>/dev/null"
	elseif name == "find" then
		local target = path_util.resolve(args.path or ".", cwd)
		local max_depth = math.floor(tonumber(args.maxDepth) or 3)
		local pattern = args.pattern or ""
		local cmd = "find " .. shell_util.quote(target) .. " -maxdepth " .. tostring(max_depth) .. " -type f"
		if pattern ~= "" then
			cmd = cmd .. " -name " .. shell_util.quote(pattern)
		end
		return cmd .. " | sort"
	elseif name == "grep" then
		if not args.pattern or args.pattern == "" then
			return nil
		end
		local target = path_util.resolve(args.path or ".", cwd)
		if args.glob and args.glob ~= "" then
			return "rg --line-number --color=never --glob " .. shell_util.quote(args.glob) .. " " .. shell_util.quote(args.pattern) .. " " .. shell_util.quote(target) .. " 2>&1"
		end
		return "rg --line-number --color=never " .. shell_util.quote(args.pattern) .. " " .. shell_util.quote(target) .. " 2>&1"
	end

	return nil
end

local MAX_BYTES = 20000
local MAX_READ_BATCH_BYTES = tonumber(os.getenv("LCA_READ_BATCH_MAX_BYTES") or "") or 24000

local function truncate(output)
	if #output <= MAX_BYTES then
		return output, false
	end
	return output:sub(1, MAX_BYTES) .. "\n[truncated at " .. MAX_BYTES .. " bytes]", true
end

local function count_lines(output)
	local count = 0
	for _ in output:gmatch("[^\n]+") do
		count = count + 1
	end
	return count
end

local function format_result(name, _args, output, exit_code)
	if exit_code == 127 then
		return {
			is_error = true,
			content = output ~= "" and output or "command not found",
			summary = "spawn failed",
		}
	end

	local truncated
	output, truncated = truncate(output)
	local count = count_lines(output)

	if name == "ls" then
		return {
			is_error = false,
			content = output ~= "" and output or "(empty directory)",
			summary = tostring(count) .. " entries",
		}
	elseif name == "find" then
		local summary = tostring(count) .. " files"
		if truncated then summary = summary .. ", truncated" end
		return {
			is_error = false,
			content = output ~= "" and output or "(no files)",
			summary = summary,
		}
	elseif name == "grep" then
		if exit_code ~= 0 and exit_code ~= 1 then
			return {
				is_error = true,
				content = output,
				summary = "exit " .. tostring(exit_code),
			}
		end
		local summary = tostring(count) .. " matches"
		if truncated then summary = summary .. ", truncated" end
		return {
			is_error = false,
			content = output ~= "" and output or "(no matches)",
			summary = summary,
		}
	end

	return { is_error = true, content = "unknown tool", summary = "error" }
end

local function normalized_number(value, fallback)
	local number = tonumber(value)
	if not number then
		number = fallback
	end
	return tostring(math.floor(number or 0))
end

local function read_call_key(tc, context)
	if tc.name ~= "read" then
		return nil
	end
	local args = tc.args or {}
	if not args.path or args.path == "" then
		return nil
	end
	local target = path_util.resolve(args.path, context.cwd or ".")
	return table.concat({
		target,
		normalized_number(args.offset, 1),
		normalized_number(args.limit, -1),
	}, "\0")
end

local function duplicate_read_result(original_index)
	return {
		is_error = false,
		content = "Duplicate read skipped; same result as tool call #" .. tostring(original_index) .. ".",
		summary = "duplicate read",
	}
end

local function already_read_result(info)
	local where = info and info.message_index and ("message #" .. tostring(info.message_index)) or "recent context"
	return {
		is_error = false,
		ui_state = "deferred",
		content = "Read skipped; this exact file range is already visible in " .. where .. ". Use the existing read result unless the file changed.",
		summary = "already in context",
	}
end

local function read_budget_result(max_bytes)
	return {
		is_error = false,
		ui_state = "deferred",
		content = "Read batch output budget reached (" .. tostring(max_bytes) .. " bytes). Use a smaller targeted read in the next turn.",
		summary = "read budget reached",
	}
end

local function spawn_and_collect(cmd, callback)
	local stdout_pipe = uv.new_pipe()
	local stderr_pipe = uv.new_pipe()
	local chunks = {}
	local handle

	handle = uv.spawn("sh", {
		args = { "-c", cmd },
		stdio = { nil, stdout_pipe, stderr_pipe },
	}, function(code)
		stdout_pipe:close()
		stderr_pipe:close()
		handle:close()
		callback(table.concat(chunks), code)
	end)

	if not handle then
		stdout_pipe:close()
		stderr_pipe:close()
		callback("[error: failed to spawn process]", 127)
		return
	end

	stdout_pipe:read_start(function(err, data)
		if data then
			chunks[#chunks + 1] = data
		elseif not err then
			stdout_pipe:read_stop()
		end
	end)

	stderr_pipe:read_start(function(err, data)
		if data then
			chunks[#chunks + 1] = data
		elseif not err then
			stderr_pipe:read_stop()
		end
	end)
end

function parallel.execute_batch(tool_calls, context, on_tool)
	local shell_batch = {}
	local other_batch = {}
	local repl_ok, repl_mod = pcall(require, "agent.repl")

	for i, tc in ipairs(tool_calls) do
		if SHELL_TOOLS[tc.name] then
			local cmd = tool_to_command(tc.name, tc.args, context)
			if cmd then
				shell_batch[#shell_batch + 1] = { index = i, tc = tc, cmd = cmd }
			else
				other_batch[#other_batch + 1] = { index = i, tc = tc }
			end
		else
			other_batch[#other_batch + 1] = { index = i, tc = tc }
		end
	end

	local deduped_shell_batch = {}
	local shell_seen = {}
	for _, item in ipairs(shell_batch) do
		local key = item.tc.name .. "\0" .. item.cmd
		local existing = shell_seen[key]
		if existing then
			existing.duplicates = existing.duplicates or {}
			existing.duplicates[#existing.duplicates + 1] = item.index
		else
			shell_seen[key] = item
			deduped_shell_batch[#deduped_shell_batch + 1] = item
		end
	end
	shell_batch = deduped_shell_batch

	local results = {}
	local deduped_other_batch = {}
	local read_seen = {}
	local recent_read_keys = context.recent_read_keys or {}
	for _, item in ipairs(other_batch) do
		local key = read_call_key(item.tc, context)
		if key and read_seen[key] then
			results[item.index] = duplicate_read_result(read_seen[key])
		elseif key and recent_read_keys[key] then
			results[item.index] = already_read_result(recent_read_keys[key])
		else
			if key then
				read_seen[key] = item.index
			end
			deduped_other_batch[#deduped_other_batch + 1] = item
		end
	end
	other_batch = deduped_other_batch

	if #shell_batch > 1 then
		local pending = #shell_batch

		for _, item in ipairs(shell_batch) do
			emit_start(on_tool, item.tc)
			spawn_and_collect(item.cmd, function(output, exit_code)
				local result = format_result(item.tc.name, item.tc.args, output, exit_code)
				results[item.index] = result
				for _, duplicate_index in ipairs(item.duplicates or {}) do
					results[duplicate_index] = result
				end
				if on_tool then
					on_tool({ type = "tool", name = item.tc.name, args = item.tc.args, result = result })
				end
				pending = pending - 1
			end)
		end

		while pending > 0 do
			uv.run("once")
			if repl_ok and repl_mod.cancelled then break end
		end
	elseif #shell_batch == 1 then
		local item = shell_batch[1]
		emit_start(on_tool, item.tc)
		local result = registry.execute(item.tc.name, item.tc.args, context)
		results[item.index] = result
		for _, duplicate_index in ipairs(item.duplicates or {}) do
			results[duplicate_index] = result
		end
		if on_tool then
			on_tool({ type = "tool", name = item.tc.name, args = item.tc.args, result = result })
		end
	end

	local mutated_targets = {}
	local read_targets = collect_read_targets(other_batch, context)
	local edit_groups = collect_edit_groups(other_batch, context)
	local completed_group_targets = {}
	local read_batch_bytes = 0
	for _, item in ipairs(other_batch) do
		-- Check cancellation between sequential tool executions
		if repl_ok and repl_mod.cancelled then break end
		local tc = item.tc
		local mutation_target = file_mutation_target(tc, context)
		local result
		local result_emitted = false
		local edit_group = mutation_target and edit_groups[mutation_target]
		if mutation_target and read_targets[mutation_target] then
			result = dependent_batch_result(mutation_target)
		elseif edit_group and not completed_group_targets[mutation_target] and not mutated_targets[mutation_target] then
			table.sort(edit_group, function(a, b)
				if a.start_line == b.start_line then
					return a.end_line > b.end_line
				end
				return a.start_line > b.start_line
			end)
			local any_success = false
			for _, group_item in ipairs(edit_group) do
				if repl_ok and repl_mod.cancelled then break end
				emit_start(on_tool, group_item.tc)
				local group_result = registry.execute(group_item.tc.name, group_item.tc.args, context)
				results[group_item.index] = group_result
				if group_result and not group_result.is_error then
					any_success = true
				end
				if on_tool then
					on_tool({ type = "tool", name = group_item.tc.name, args = group_item.tc.args, result = group_result })
				end
			end
			result_emitted = true
			completed_group_targets[mutation_target] = true
			if any_success then
				mutated_targets[mutation_target] = true
			end
			result = results[item.index]
		elseif edit_group and completed_group_targets[mutation_target] then
			result = results[item.index]
			result_emitted = true
		elseif mutation_target and mutated_targets[mutation_target] then
			result = stale_batch_result(mutation_target)
		elseif tc.name == "read" and read_batch_bytes >= MAX_READ_BATCH_BYTES then
			result = read_budget_result(MAX_READ_BATCH_BYTES)
		else
			emit_start(on_tool, tc)
			result = registry.execute(tc.name, tc.args, context)
			if mutation_target and result and not result.is_error then
				mutated_targets[mutation_target] = true
			end
		end
		if tc.name == "read" and result and not result.is_error and result.summary ~= "duplicate read" then
			read_batch_bytes = read_batch_bytes + #(result.content or "")
			if read_batch_bytes > MAX_READ_BATCH_BYTES then
				result = read_budget_result(MAX_READ_BATCH_BYTES)
			end
		end
		results[item.index] = result
		if on_tool and not result_emitted then
			on_tool({ type = "tool", name = tc.name, args = tc.args, result = result })
		end
	end

	return results
end

return parallel
