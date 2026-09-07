local update_plan = {}
local json = require("agent.util.json")

local VALID_STATUSES = {
	pending = true,
	in_progress = true,
	completed = true,
}

local function trim(value)
	return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function normalize_plan(plan)
	if type(plan) == "string" then
		local ok, decoded = pcall(json.decode, plan)
		if ok then
			plan = decoded
		end
	end
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

local function normalize_wolf(value)
	if type(value) == "string" then
		local ok, decoded = pcall(json.decode, value)
		if ok then value = decoded end
	end
	if type(value) ~= "table" then return nil, "wolf status must be an object" end
	local title = trim(value.title)
	local payoff = trim(value.payoff)
	local proof = trim(value.proof)
	if title == "" then return nil, "wolf status title is required" end
	if payoff == "" then return nil, "wolf status payoff is required" end
	return {
		title = title,
		payoff = payoff,
		proof = proof ~= "" and proof or nil,
	}
end

local function normalize_journey(value)
	if value == nil then return nil end
	if type(value) == "string" then
		local ok, decoded = pcall(json.decode, value)
		if ok then value = decoded end
	end
	if type(value) ~= "table" then return nil, "journey must be an object" end
	local destination = trim(value.destination)
	local approach = trim(value.approach)
	local proof = trim(value.proof)
	if destination == "" then return nil, "journey destination is required" end
	if approach == "" then return nil, "journey approach is required" end
	if proof == "" then return nil, "journey proof is required" end
	return {
		destination = destination,
		approach = approach,
		proof = proof,
	}
end

local function plan_complete(plan)
	if #plan == 0 then return false end
	for _, item in ipairs(plan) do
		if item.status ~= "completed" then return false end
	end
	return true
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

	local previous_plan = session.plan
	local replaces_empty_plan = type(previous_plan) ~= "table" or #previous_plan == 0
	local journey, journey_err = normalize_journey(args and args.journey)
	if journey_err then
		return { is_error = true, content = journey_err, summary = "invalid journey" }
	end
	local wolf_status
	if session.flow == "insanitywolf" and #normalized > 0 then
		local cycle = tonumber(session.insanitywolf_cycle) or 1
		local supplied
		if args and args.wolf ~= nil then
			local wolf_err
			supplied, wolf_err = normalize_wolf(args.wolf)
			if not supplied then
				return { is_error = true, content = wolf_err, summary = "invalid wolf status" }
			end
		end
		local prior = session.wolf_status
		if not supplied and type(prior) == "table" and tonumber(prior.cycle) == cycle then
			supplied = { title = prior.title, payoff = prior.payoff, proof = prior.proof }
		end
		if not supplied then
			return {
				is_error = true,
				content = "the first insanitywolf plan for a cycle requires wolf {title,payoff,proof?}",
				summary = "missing wolf status",
			}
		end
		local completed = plan_complete(normalized)
		wolf_status = {
			phase = completed and "shipped" or "hunt",
			cycle = cycle,
			title = supplied.title,
			payoff = supplied.payoff,
			proof = supplied.proof,
		}
		session.wolf_status = wolf_status
		if completed and not (type(prior) == "table" and prior.phase == "shipped" and tonumber(prior.cycle) == cycle) then
			session.wolf_ledger = type(session.wolf_ledger) == "table" and session.wolf_ledger or {}
			session.wolf_ledger[#session.wolf_ledger + 1] = {
				cycle = cycle,
				title = wolf_status.title,
				payoff = wolf_status.payoff,
				proof = wolf_status.proof,
			}
		end
	end
	session.plan = normalized
	if #normalized == 0 then session.journey = nil
	elseif journey then session.journey = journey end

	return {
		is_error = false,
		content = plan_text(normalized),
		plan = normalized,
		journey = journey or session.journey,
		wolf_status = wolf_status,
		plan_fresh = replaces_empty_plan and #normalized > 0,
		summary = #normalized == 0 and "cleared plan" or ("updated " .. tostring(#normalized) .. " steps"),
	}
end

return update_plan
