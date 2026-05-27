local jobs = require("agent.jobs")

local job_status = {}

local function format_job(job)
	local lines = {
		"id: " .. tostring(job.id),
		"status: " .. tostring(job.status),
		"command: " .. tostring(job.command),
		"cwd: " .. tostring(job.cwd),
		"pid: " .. tostring(job.pid),
		"pgid: " .. tostring(job.pgid),
		"alive: " .. tostring(job.alive),
		"started_at: " .. tostring(job.started_at),
	}
	if job.finished_at then lines[#lines + 1] = "finished_at: " .. tostring(job.finished_at) end
	if job.exit_code ~= nil then lines[#lines + 1] = "exit_code: " .. tostring(job.exit_code) end
	if job.timeout ~= nil then lines[#lines + 1] = "timeout: " .. tostring(job.timeout) .. "ms" end
	if job.start_error then lines[#lines + 1] = "start_error: " .. tostring(job.start_error) end
	return table.concat(lines, "\n")
end

function job_status.execute(args, context)
	if not args.id or args.id == "" then
		return { is_error = true, content = "id is required", summary = "missing id" }
	end
	local job, err = jobs.status(args.cwd or context.cwd, args.id)
	if not job then
		return { is_error = true, content = err, summary = "unknown job" }
	end
	return {
		is_error = false,
		content = format_job(job),
		summary = tostring(job.status),
	}
end

return job_status
