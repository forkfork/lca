local jobs = require("agent.jobs")
local job_args = require("agent.tools.job_args")

local job_output = {}

function job_output.execute(args, context)
	local id, id_error = job_args.require_id(args)
	if not id then return id_error end
	local output, err, next_offset = jobs.output(args.cwd or context.cwd, id, args)
	if not output then
		return { is_error = true, content = err, summary = "output failed" }
	end
	if output == "" then output = "(no output)" end
	local summary = "output"
	if next_offset then
		summary = "offset " .. tostring(next_offset)
	end
	return {
		is_error = false,
		content = output,
		summary = summary,
	}
end

return job_output
