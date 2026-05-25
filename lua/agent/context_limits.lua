local context_limits = {}

local DEFAULT_CONTEXT_WINDOW = 200000
local DEFAULT_RESERVE_TOKENS = 16384

local MODEL_CONTEXT_WINDOWS = {
	["gpt-5.5"] = 200000,
	["gpt-5.4"] = 400000,
	["gpt-5"] = 400000,
	["gpt-5-mini"] = 400000,
	["gpt-5-codex"] = 400000,
	["deepseek-v4-flash"] = 1000000,
	["deepseek-v4-pro"] = 1000000,
	["deepseek-chat"] = 1000000,
	["deepseek-reasoner"] = 1000000,
}

local function env_number(name)
	local value = tonumber(os.getenv(name) or "")
	if value and value > 0 then
		return math.floor(value)
	end
	return nil
end

function context_limits.context_window(model)
	local override = env_number("LCA_CONTEXT_WINDOW")
	if override then
		return override
	end
	model = tostring(model or "")
	if MODEL_CONTEXT_WINDOWS[model] then
		return MODEL_CONTEXT_WINDOWS[model]
	end
	if model:find("gpt%-5", 1) then
		return 400000
	end
	if model:find("deepseek", 1, true) then
		return 1000000
	end
	if model:find("claude", 1, true) or model:find("anthropic", 1, true) or model:match("^us%.") or model:match("^eu%.") or model:match("^ap%.") then
		return 200000
	end
	return DEFAULT_CONTEXT_WINDOW
end

function context_limits.reserve_tokens()
	return env_number("LCA_CONTEXT_RESERVE_TOKENS") or DEFAULT_RESERVE_TOKENS
end

function context_limits.auto_compact_threshold(model)
	local raw = os.getenv("LCA_AUTO_COMPACT_TOKENS")
	local explicit = tonumber(raw or "")
	if raw ~= nil and explicit then
		return math.floor(explicit)
	end
	return math.max(1, context_limits.context_window(model) - context_limits.reserve_tokens())
end

function context_limits.should_compact(tokens, model)
	return tonumber(tokens or 0) >= context_limits.auto_compact_threshold(model)
end

return context_limits
