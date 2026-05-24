local jobs = require("agent.jobs")

local job_start = {}

function job_start.execute(args, context)
	local job, err = jobs.start(args, context)
	if not job then
		return {
			is_error = true,
			content = err or "failed to start job",
			summary = "failed to start",
		}
	end

	return {
		is_error = false,
		job = job,
		content = table.concat({
			"started " .. job.id,
			"command: " .. job.command,
			"cwd: " .. job.cwd,
			"timeout: " .. (job.timeout and tonumber(job.timeout) and tonumber(job.timeout) > 0 and (tostring(math.floor(tonumber(job.timeout) / 1000)) .. "s") or "none"),
			"stdout: " .. job.stdout,
			"stderr: " .. job.stderr,
		}, "\n"),
		summary = "started " .. job.id,
	}
end

return job_start
