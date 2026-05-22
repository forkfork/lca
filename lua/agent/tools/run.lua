local shell = require("agent.util.shell")
local uv = require("luv")

local run = {}

local MAX_OUTPUT = 20000
local DEFAULT_TIMEOUT_MS = 120000

local function truncate_output(output)
	if #output <= MAX_OUTPUT then
		return output, false
	end
	return output:sub(1, MAX_OUTPUT) .. "\n[truncated at " .. MAX_OUTPUT .. " bytes]", true
end

function run.execute(args, context)
	if not args.command or args.command == "" then
		return {
			is_error = true,
			content = "command is required",
			summary = "missing command",
		}
	end

	local timeout_ms = tonumber(args.timeout) or DEFAULT_TIMEOUT_MS

	-- Drain any pending libuv callbacks from previous operations
	uv.run("nowait")

	local stdout_pipe = uv.new_pipe(false)
	local stderr_pipe = uv.new_pipe(false)
	local chunks = {}
	local exit_code = nil
	local timed_out = false
	local done = false

	local handle, pid = uv.spawn("sh", {
		args = { "-c", args.command },
		cwd = context.cwd,
		stdio = { nil, stdout_pipe, stderr_pipe },
	}, function(code)
		exit_code = code
		done = true
	end)

	if not handle then
		stdout_pipe:close()
		stderr_pipe:close()
		return {
			is_error = true,
			content = "failed to start command: " .. tostring(pid),
			summary = "failed to start",
		}
	end

	stdout_pipe:read_start(function(err, data)
		if data then
			chunks[#chunks + 1] = data
		end
	end)

	stderr_pipe:read_start(function(err, data)
		if data then
			chunks[#chunks + 1] = data
		end
	end)

	local timer = uv.new_timer()
	timer:start(timeout_ms, 0, function()
		if not done then
			timed_out = true
			uv.process_kill(handle, "sigkill")
		end
	end)

	local repl_ok, repl_mod = pcall(require, "agent.repl")
	while not done do
		uv.run("once")
		if repl_ok and repl_mod.cancelled then
			timed_out = true  -- reuse timeout path for cleanup
			uv.process_kill(handle, "sigkill")
			break
		end
	end

	-- Wait for process to fully exit after kill
	if not done then
		for _ = 1, 50 do
			uv.run("nowait")
			if done then break end
		end
	end

	timer:stop()
	timer:close()
	stdout_pipe:read_stop()
	stderr_pipe:read_stop()
	stdout_pipe:close()
	stderr_pipe:close()
	handle:close()

	local output = table.concat(chunks)
	local truncated
	output, truncated = truncate_output(output)

	if timed_out then
		local repl2_ok, repl2_mod = pcall(require, "agent.repl")
		if repl2_ok and repl2_mod.cancelled then
			output = output .. "\n[cancelled by user]"
			return {
				is_error = true,
				content = output,
				summary = "cancelled",
			}
		end
		output = output .. "\n[killed: exceeded " .. math.floor(timeout_ms / 1000) .. "s timeout]"
		return {
			is_error = true,
			content = output,
			summary = "timed out after " .. math.floor(timeout_ms / 1000) .. "s",
		}
	end

	local summary = "exit " .. tostring(exit_code or 1)
	if truncated then
		summary = summary .. ", truncated"
	end
	if output == "" then
		output = "(no output)"
	end

	return {
		is_error = (exit_code ~= 0),
		content = output,
		summary = summary,
	}
end

return run

