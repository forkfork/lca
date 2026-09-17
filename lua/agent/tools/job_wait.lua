local jobs = require("agent.jobs")
local job_args = require("agent.tools.job_args")

local job_wait = {}

function job_wait.execute(args, context)
	local id, id_error = job_args.require_id(args)
	if not id then return id_error end
	if args.stream and args.stream ~= "stdout" and args.stream ~= "stderr" then
		return { is_error = true, content = "stream must be stdout or stderr", summary = "invalid stream" }
	end
	local cwd = args.cwd or context.cwd
	local job, err, reason = jobs.wait(cwd, id, args, context)
	if not job then
		return { is_error = true, content = err, summary = reason or "unknown job" }
	end

	local content = jobs.describe(job)
	local active = job.status == "starting" or job.status == "running"
	content = content .. "\nwait_reason: " .. (reason or (active and "deadline" or "completed"))
	local streams = args.stream and { args.stream } or { "stdout", "stderr" }
	for _, stream in ipairs(streams) do
		local options = args.tail and { stream = stream, tail = args.tail }
			or { stream = stream, offset = args[stream .. "_offset"] or 0, limit = args.limit }
		local output, output_err, next_offset, more = jobs.output(cwd, id, options)
		if not output then
			return { is_error = true, content = content .. "\n" .. tostring(output_err), summary = "output failed" }
		end
		if next_offset then
			content = content .. "\n" .. stream .. "_offset: " .. tostring(next_offset)
			content = content .. "\n" .. stream .. "_more: " .. tostring(more)
		end
		if output ~= "" then content = content .. "\n\n" .. stream .. ":\n" .. output end
	end
	return { is_error = false, content = content, summary = tostring(job.status) }
end

return job_wait
