local jobs = require("agent.jobs")
local uv = require("luv")

local supervisor = {}

local function save(job)
	jobs.save(job.cwd, job)
end

local function finish(job, status, code)
	local current = jobs.load(job.cwd, job.id)
	if current and current.status == "stopped" then
		current.exit_code = code
		current.finished_at = current.finished_at or jobs.now_iso()
		save(current)
		return
	end
	job.status = status
	job.exit_code = code
	job.finished_at = jobs.now_iso()
	save(job)
end

function supervisor.main(argv)
	local cwd = argv[1]
	local id = argv[2]
	local job = jobs.load(cwd, id)
	if not job then
		return
	end

	local stdout_fd = uv.fs_open(job.stdout, "a", tonumber("644", 8))
	local stderr_fd = uv.fs_open(job.stderr, "a", tonumber("644", 8))
	if not stdout_fd or not stderr_fd then
		job.status = "failed_to_start"
		job.finished_at = jobs.now_iso()
		job.start_error = "failed to open job log files"
		save(job)
		return
	end

	local done = false
	local timed_out = false
	local timer
	local kill_timer
	local handle, pid_or_err = uv.spawn("sh", {
		args = { "-c", job.command },
		cwd = job.cwd,
		detached = true,
		stdio = { nil, stdout_fd, stderr_fd },
	}, function(code)
		done = true
		if timer then
			timer:stop()
			timer:close()
		end
		if kill_timer then
			kill_timer:stop()
			kill_timer:close()
		end
		if timed_out then
			finish(job, "timed_out", code)
		else
			finish(job, "exited", code)
		end
	end)

	if not handle then
		uv.fs_close(stdout_fd)
		uv.fs_close(stderr_fd)
		job.status = "failed_to_start"
		job.finished_at = jobs.now_iso()
		job.start_error = tostring(pid_or_err)
		save(job)
		return
	end

	job.pid = pid_or_err
	job.pgid = pid_or_err
	job.status = "running"
	save(job)

	if job.timeout and job.timeout > 0 then
		timer = uv.new_timer()
		timer:start(job.timeout, 0, function()
			if done then return end
			timed_out = true
			local pgid = tostring(math.floor(tonumber(job.pgid)))
			os.execute("/bin/kill -TERM -- -" .. pgid .. " >/dev/null 2>&1")
			kill_timer = uv.new_timer()
			kill_timer:start(500, 0, function()
				if done then return end
				os.execute("/bin/kill -KILL -- -" .. pgid .. " >/dev/null 2>&1")
			end)
		end)
	end

	while not done do
		uv.run("once")
	end

	handle:close()
	uv.fs_close(stdout_fd)
	uv.fs_close(stderr_fd)
	uv.run("nowait")
end

return supervisor
