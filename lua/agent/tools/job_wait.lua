local jobs = require("agent.jobs")

local job_wait = {}

local function format_job(job)
	local lines = {
		"id: " .. tostring(job.id),
		"status: " .. tostring(job.status),
		"command: " .. tostring(job.command),
	}
	if job.exit_code ~= nil then lines[#lines + 1] = "exit_code: " .. tostring(job.exit_code) end
	if job.finished_at then lines[#lines + 1] = "finished_at: " .. tostring(job.finished_at) end
	return table.concat(lines, "\n")
end

function job_wait.execute(args, context)
	if not args.id or args.id == "" then
		return { is_error = true, content = "id is required", summary = "missing id" }
	end
	local job, err = jobs.wait(context.cwd, args.id, args)
	if not job then
		return { is_error = true, content = err, summary = "unknown job" }
	end

	local content = format_job(job)
	if args.tail then
		local output = jobs.output(context.cwd, args.id, { stream = args.stream or "stdout", tail = args.tail })
		if output and output ~= "" then
			content = content .. "\n\n" .. output
		end
	end

	return {
		is_error = false,
		content = content,
		summary = tostring(job.status),
	}
end

return job_wait
