local jobs = require("agent.jobs")

local job_stop = {}

function job_stop.execute(args, context)
	if not args.id or args.id == "" then
		return { is_error = true, content = "id is required", summary = "missing id" }
	end
	local job, err = jobs.stop(context.cwd, args.id)
	if not job then
		return { is_error = true, content = err, summary = "unknown job" }
	end
	return {
		is_error = false,
		content = "stopped " .. tostring(job.id) .. "\nstatus: " .. tostring(job.status),
		summary = tostring(job.status),
	}
end

return job_stop
