local context_limits = {}

local DEFAULT_CONTEXT_WINDOW = 272000
local DEFAULT_RESERVE_TOKENS = 16384
local DEFAULT_AUTO_COMPACT_TOKENS = 150000

local MODEL_CONTEXT_WINDOWS = {
	["gpt-6-astra"] = 272000,
	["gpt-5.6-sol"] = 272000,
	["gpt-5.6-terra"] = 272000,
	["gpt-5.6-luna"] = 272000,
}

local MODEL_MAX_INPUT_TOKENS = {
	-- Local hard input budget: the Codex window with 16k reserved headroom.
	["gpt-6-astra"] = 255616,
	["gpt-5.6-sol"] = 255616,
	["gpt-5.6-terra"] = 255616,
	["gpt-5.6-luna"] = 255616,
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
		or math.max(1, context_limits.context_window(model) - context_limits.reserve_tokens())
end

function context_limits.auto_compact_threshold(model)
	return math.min(DEFAULT_AUTO_COMPACT_TOKENS, context_limits.max_input_tokens(model))
end

function context_limits.should_compact(tokens, model)
	return tonumber(tokens or 0) >= context_limits.auto_compact_threshold(model)
end

return context_limits
