local update_plan = {}

local VALID_STATUSES = {
	pending = true,
	in_progress = true,
	completed = true,
}

local function trim(value)
	return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function normalize_plan(plan)
	if type(plan) ~= "table" then
		return nil, "plan array is required"
	end

	local normalized = {}
	local in_progress_count = 0
	for i, item in ipairs(plan) do
		if type(item) ~= "table" then
			return nil, "plan item " .. tostring(i) .. " must be an object"
		end

		local step = trim(item.step)
		if step == "" then
			return nil, "plan item " .. tostring(i) .. " step is required"
		end

		local status = trim(item.status):lower()
		if not VALID_STATUSES[status] then
			return nil, "plan item " .. tostring(i) .. " has invalid status: " .. tostring(item.status)
		end
		if status == "in_progress" then
			in_progress_count = in_progress_count + 1
		end

		normalized[#normalized + 1] = {
			step = step,
			status = status,
		}
	end

	if in_progress_count > 1 then
		return nil, "at most one plan item may be in_progress"
	end

	return normalized
end

local function plan_text(plan)
	if #plan == 0 then
		return "Plan cleared."
	end

	local lines = {}
	for i, item in ipairs(plan) do
		lines[#lines + 1] = string.format("%d. [%s] %s", i, item.status, item.step)
	end
	return table.concat(lines, "\n")
end

function update_plan.execute(args, context)
	local normalized, err = normalize_plan(args and args.plan)
	if not normalized then
		return {
			is_error = true,
			content = err,
			summary = "invalid plan",
		}
	end

	local session = context and context.session
	if type(session) ~= "table" then
		return {
			is_error = true,
			content = "session context is required",
			summary = "missing session",
		}
	end

	session.plan = normalized

	return {
		is_error = false,
		content = plan_text(normalized),
		plan = normalized,
		summary = #normalized == 0 and "cleared plan" or ("updated " .. tostring(#normalized) .. " steps"),
	}
end

return update_plan
