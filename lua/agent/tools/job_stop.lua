local jobs = require("agent.jobs")
local job_args = require("agent.tools.job_args")

local job_stop = {}

function job_stop.execute(args, context)
	local id, id_error = job_args.require_id(args)
	if not id then return id_error end
	local job, err = jobs.stop(args.cwd or context.cwd, id)
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
