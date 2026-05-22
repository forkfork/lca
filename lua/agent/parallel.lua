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

	local results = {}

	if #shell_batch > 1 then
		local pending = #shell_batch

		for _, item in ipairs(shell_batch) do
			spawn_and_collect(item.cmd, function(output, exit_code)
				local result = format_result(item.tc.name, item.tc.args, output, exit_code)
				results[item.index] = result
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
		local result = registry.execute(item.tc.name, item.tc.args, context)
		results[item.index] = result
		if on_tool then
			on_tool({ type = "tool", name = item.tc.name, args = item.tc.args, result = result })
		end
	end

	for _, item in ipairs(other_batch) do
		-- Check cancellation between sequential tool executions
		if repl_ok and repl_mod.cancelled then break end
		local tc = item.tc
		local result = registry.execute(tc.name, tc.args, context)
		results[item.index] = result
		if on_tool then
			on_tool({ type = "tool", name = tc.name, args = tc.args, result = result })
		end
	end

	return results
end

return parallel

