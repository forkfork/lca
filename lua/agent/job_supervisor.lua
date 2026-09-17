local jobs = require("agent.jobs")
local uv = require("luv")

local supervisor = {}

local function finish(job, status, code, signal)
	local cwd = job.store_cwd or job.cwd
	return jobs.with_lock(cwd, function()
		local current = jobs.load(cwd, job.id)
		if not current then return end
		if current.status ~= "stopped" then current.status = status end
		current.exit_code = code
		if signal and signal > 0 then current.signal = signal end
		current.finished_at = current.finished_at or jobs.now_iso()
		return jobs.save(cwd, current)
	end)
end

function supervisor.main(argv)
	local cwd, id = argv[1], argv[2]
	local job, handle, stdout_fd, stderr_fd
	local done, timed_out = false, false
	local exit_code, exit_signal, timer, kill_timer

	-- Stop and launch share the store lock: either stop wins before execution,
	-- or it sees the published process group and can terminate it.
	local ok, err = jobs.with_lock(cwd, function()
		job = jobs.load(cwd, id)
		if not job or job.status ~= "starting" then return true end
		stdout_fd = uv.fs_open(job.stdout, "a", tonumber("644", 8))
		stderr_fd = uv.fs_open(job.stderr, "a", tonumber("644", 8))
		local start_error
		if stdout_fd and stderr_fd then
			local pid_or_err
			handle, pid_or_err = uv.spawn("sh", {
				args = { "-c", job.command }, cwd = job.cwd, detached = true,
				stdio = { nil, stdout_fd, stderr_fd },
			}, function(code, signal)
				done, exit_signal = true, signal
				exit_code = signal and signal > 0 and (128 + signal) or code
				if timer then timer:stop(); timer:close(); timer = nil end
				-- Keep timeout escalation alive even if the shell exits first.
			end)
			if handle then
				job.pid, job.pgid = pid_or_err, pid_or_err
				job.process_start_ticks, job.boot_id = jobs.process_identity(pid_or_err)
				job.status = "running"
			else
				start_error = tostring(pid_or_err)
			end
		else
			start_error = "failed to open job log files"
		end
		if start_error then
			job.status = "failed_to_start"
			job.finished_at = jobs.now_iso()
			job.start_error = start_error
		end
		return jobs.save(cwd, job)
	end)
	if not ok and handle then
		jobs.signal_group(job, "sigkill")
		while not done do uv.run("once") end
		handle:close(); handle = nil
	end
	if not handle then
		if stdout_fd then uv.fs_close(stdout_fd) end
		if stderr_fd then uv.fs_close(stderr_fd) end
		if not ok then error(err) end
		return
	end

	if job.timeout and job.timeout > 0 then
		timer = uv.new_timer()
		timer:start(job.timeout, 0, function()
			if done then return end
			timed_out = true
			jobs.signal_group(job, "sigterm")
			kill_timer = uv.new_timer()
			kill_timer:start(500, 0, function()
				jobs.signal_group(job, "sigkill")
				kill_timer:stop(); kill_timer:close(); kill_timer = nil
			end)
		end)
	end

	while not done or kill_timer do uv.run("once") end
	local saved, save_err = finish(job, timed_out and "timed_out" or "exited", exit_code, exit_signal)
	handle:close()
	uv.fs_close(stdout_fd)
	uv.fs_close(stderr_fd)
	uv.run("nowait")
	if not saved and save_err then error(save_err) end
end

return supervisor
