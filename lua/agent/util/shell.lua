local uv = require("luv")
local DEFAULT_PROGRESS_INTERVAL_MS = 2000

local shell = {}

function shell.quote(value)
	return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function kill_process_tree(pid, handle, signal)
	signal = signal or "sigterm"
	if pid then
		os.execute("pkill -" .. (signal == "sigkill" and "KILL" or "TERM") .. " -P " .. tostring(pid) .. " >/dev/null 2>&1")
	end
	if handle and not handle:is_closing() then
		pcall(uv.process_kill, handle, signal)
	end
end

-- Plain execution capability. Output combines stdout/stderr in arrival order.
-- opts: cwd, timeout (ms), cancelled, progress, progress_interval_ms,
-- inherit_stderr (legacy capture callers). No timeout unless requested.
function shell:run(command, opts)
	opts = opts or {}
	-- Drain any pending libuv callbacks from previous operations
	uv.run("nowait")

	local stdout_pipe = uv.new_pipe(false)
	local stderr_pipe = not opts.inherit_stderr and uv.new_pipe(false) or nil
	local chunks = {}
	local output_bytes = 0
	local output_chunks = 0
	local exit_code = nil
	local timed_out = false
	local done = false

	local handle, pid = uv.spawn("sh", {
		args = { "-c", command },
		cwd = opts.cwd,
		stdio = { nil, stdout_pipe, stderr_pipe or 2 },
	}, function(code)
		exit_code = code
		done = true
	end)

	if not handle then
		stdout_pipe:close()
		if stderr_pipe then stderr_pipe:close() end
		return { output = "", code = 127, error = tostring(pid) }
	end

	stdout_pipe:read_start(function(_, data)
		if data then
			chunks[#chunks + 1] = data
			output_bytes = output_bytes + #data
			output_chunks = output_chunks + 1
		end
	end)

	if stderr_pipe then
		stderr_pipe:read_start(function(_, data)
			if data then
				chunks[#chunks + 1] = data
				output_bytes = output_bytes + #data
				output_chunks = output_chunks + 1
			end
		end)
	end

	local progress_timer
	if type(opts.progress) == "function" then
		local interval_ms = math.max(100, math.floor(tonumber(opts.progress_interval_ms) or DEFAULT_PROGRESS_INTERVAL_MS))
		local started_ns = uv.hrtime()
		progress_timer = uv.new_timer()
		progress_timer:start(interval_ms, interval_ms, function()
			if done then return end
			opts.progress({
				elapsed_ms = math.floor((uv.hrtime() - started_ns) / 1000000),
				output_bytes = output_bytes,
				output_chunks = output_chunks,
			})
		end)
	end

	local timer = opts.timeout and uv.new_timer()
	if timer then
		timer:start(opts.timeout, 0, function()
			if not done then
				timed_out = true
				kill_process_tree(pid, handle, "sigterm")
			end
		end)
	end

	local function is_cancelled()
		if type(opts.cancelled) == "function" then
			return opts.cancelled() == true
		end
		return false
	end
	while not done do
		uv.run("once")
		if is_cancelled() then
			timed_out = true  -- reuse timeout path for cleanup
			kill_process_tree(pid, handle, "sigterm")
			break
		end
	end

	-- Wait for process to fully exit after kill
	if not done then
		for _ = 1, 50 do
			uv.run("nowait")
			if done then break end
		end
		if not done then
			kill_process_tree(pid, handle, "sigkill")
			for _ = 1, 50 do
				uv.run("nowait")
				if done then break end
			end
		end
	end

	if timer then timer:stop(); timer:close() end
	if progress_timer then progress_timer:stop(); progress_timer:close() end
	stdout_pipe:read_stop()
	if stderr_pipe then stderr_pipe:read_stop() end
	stdout_pipe:close()
	if stderr_pipe then stderr_pipe:close() end
	handle:close()

	local output = table.concat(chunks)
	return { output = output, code = exit_code, timed_out = timed_out, cancelled = timed_out and is_cancelled() }
end

-- Optional callback form for concurrent discovery batches; callback receives the same result.
function shell:run_async(cmd, opts, callback)
	local stdout_pipe = uv.new_pipe()
	local stderr_pipe = uv.new_pipe()
	local chunks = {}
	local handle

	handle = uv.spawn("sh", {
		args = { "-c", cmd },
		cwd = opts.cwd,
		stdio = { nil, stdout_pipe, stderr_pipe },
	}, function(code)
		stdout_pipe:close()
		stderr_pipe:close()
		handle:close()
		callback({ output = table.concat(chunks), code = code })
	end)

	if not handle then
		stdout_pipe:close()
		stderr_pipe:close()
		callback({ output = "[error: failed to spawn process]", code = 127, error = "failed to spawn process" })
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

-- Preserve the existing throwing, stdout-only helper for its callers.
function shell.capture(command, executor)
	local result = (executor or shell):run(command, { inherit_stderr = true })
	if result.error or result.code ~= 0 then
		error("command failed (" .. tostring(result.code) .. "): " .. command)
	end
	return result.output
end

return shell
