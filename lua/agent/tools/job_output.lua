local jobs = require("agent.jobs")

local job_output = {}

function job_output.execute(args, context)
	if not args.id or args.id == "" then
		return { is_error = true, content = "id is required", summary = "missing id" }
	end
	local output, err, next_offset = jobs.output(args.cwd or context.cwd, args.id, args)
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
