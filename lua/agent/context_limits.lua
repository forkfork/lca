local context_limits = {}

local DEFAULT_CONTEXT_WINDOW = 1050000
local DEFAULT_RESERVE_TOKENS = 16384

local MODEL_CONTEXT_WINDOWS = {
	["gpt-6-astra"] = 1050000,
	["gpt-5.6-sol"] = 1050000,
	["gpt-5.6-terra"] = 1050000,
	["gpt-5.6-luna"] = 1050000,
}

local MODEL_MAX_INPUT_TOKENS = {
	-- Local input budget: context window minus the 128k maximum output.
	["gpt-6-astra"] = 922000,
	["gpt-5.6-sol"] = 922000,
	["gpt-5.6-terra"] = 922000,
	["gpt-5.6-luna"] = 922000,
}

function context_limits.context_window(model)
	model = tostring(model or "")
	if MODEL_CONTEXT_WINDOWS[model] then
		return MODEL_CONTEXT_WINDOWS[model]
	end
	return DEFAULT_CONTEXT_WINDOW
end

function context_limits.reserve_tokens()
	return DEFAULT_RESERVE_TOKENS
end

function context_limits.max_input_tokens(model)
	return MODEL_MAX_INPUT_TOKENS[tostring(model or "")]
		or context_limits.context_window(model)
end

function context_limits.auto_compact_threshold(model)
	return math.max(1, context_limits.max_input_tokens(model) - context_limits.reserve_tokens())
end

function context_limits.should_compact(tokens, model)
	return tonumber(tokens or 0) >= context_limits.auto_compact_threshold(model)
end

return context_limits
