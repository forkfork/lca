local job_args = {}

function job_args.valid_id(id)
	return type(id) == "string" and id:match("^job_%d+$") ~= nil
end

function job_args.require_id(args)
	if args.id == nil or args.id == "" then
		return nil, { is_error = true, content = "id is required", summary = "missing id" }
	end
	if not job_args.valid_id(args.id) then
		return nil, {
			is_error = true,
			content = "id must be a job id like job_1; pass wait duration as timeout or timeout_ms",
			summary = "invalid id",
		}
	end
	return args.id
end

return job_args
