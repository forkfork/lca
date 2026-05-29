local session = {}
session.__index = session

local json = require("agent.util.json")
local config = require("agent.config")

local DEFAULT_SESSION_FILE = ".lca-session.json"
local DEFAULT_HANDOFF_FILE = "HANDOFF.txt"
local USAGE_HISTORY_LIMIT = 50
local SYSTEM_PROMPT_VERSION = 11

local function fnv1a32(text)
	local hash = 2166136261
	for i = 1, #text do
		hash = hash ~ text:byte(i)
		hash = (hash * 16777619) % 4294967296
	end
	return string.format("%08x", hash)
end

local function current_dir()
	local uv = require("luv")
	return uv.cwd() or "."
end

local function create_session_id(cwd)
	local uv = require("luv")
	local seed = table.concat({
		tostring(cwd or current_dir()),
		tostring(os.time()),
		tostring(uv.hrtime()),
		tostring(math.random(0, 0x7fffffff)),
	}, "\0")
	return "lca-" .. fnv1a32(seed) .. "-" .. fnv1a32(seed:reverse())
end

local function resolve_model(options)
	if options.model and options.model ~= "gpt-5.5" then
		return options.model
	end
	local providers = require("agent.providers")
	local path = options.credentials_path or config.default_credentials_path()
	local ok, body = pcall(providers.credentials_body, path)
	if not ok then return options.model or "gpt-5.5" end
	local provider = json.field(body, "provider")
	if provider == "bedrock" then
		local model = json.field(body, "model")
		return model or "us.anthropic.claude-opus-4-6-v1"
	end
	if provider == "deepseek" then
		local model = json.field(body, "model")
		return model or "deepseek-v4-pro"
	end
	return options.model or "gpt-5.5"
end

local function model_for_credentials(credentials_path, current_model)
	local providers = require("agent.providers")
	local path = credentials_path or config.default_credentials_path()
	local ok, body = pcall(providers.credentials_body, path)
	if not ok then return current_model or "gpt-5.5" end
	local provider = json.field(body, "provider")
	local configured_model = json.field(body, "model")
	current_model = current_model or "gpt-5.5"
	if provider == "bedrock" then
		if current_model:match("^us%.") or current_model:match("^eu%.") or current_model:match("^ap%.") or current_model:find("anthropic", 1, true) then
			return current_model
		end
		return configured_model or "us.anthropic.claude-opus-4-6-v1"
	end
	if provider == "deepseek" then
		if current_model:find("deepseek", 1, true) then
			return current_model
		end
		return configured_model or "deepseek-v4-pro"
	end
	if provider == "codex" then
		if current_model:find("deepseek", 1, true) or current_model:match("^us%.") or current_model:match("^eu%.") or current_model:match("^ap%.") or current_model:find("anthropic", 1, true) then
			return configured_model or "gpt-5.5"
		end
	end
	return current_model
end

local VALID_REASONING_EFFORTS = {
	none = true,
	low = true,
	medium = true,
	high = true,
	xhigh = true,
}

local VALID_SERVICE_TIERS = {
	auto = true,
	default = true,
	flex = true,
	priority = true,
}

local VALID_FLOW_MODES = {
	off = true,
	insanitywolf = true,
}

local function resolve_flow(value)
	if not value or value == "" then
		return "off"
	end
	value = tostring(value):lower()
	if not VALID_FLOW_MODES[value] then
		error("invalid mode: " .. tostring(value))
	end
	return value
end

local function resolve_reasoning_effort(value)
	if not value or value == "" then
		return nil
	end
	value = tostring(value):lower()
	if not VALID_REASONING_EFFORTS[value] then
		error("invalid reasoning effort: " .. tostring(value))
	end
	return value
end

local function resolve_service_tier(value)
	if not value or value == "" then
		return nil
	end
	value = tostring(value):lower()
	if not VALID_SERVICE_TIERS[value] then
		error("invalid service tier: " .. tostring(value))
	end
	return value
end

function session.create(options)
	local cwd = current_dir()
	return setmetatable({
		id = options.session_id or create_session_id(cwd),
		credentials_path = options.credentials_path or config.default_credentials_path(),
		model = resolve_model(options),
		reasoning_effort = resolve_reasoning_effort(options.reasoning_effort),
		service_tier = resolve_service_tier(options.service_tier),
		flow = resolve_flow(options.flow),
		cwd = cwd,
		messages = {},
		system_prompt = nil,
		system_prompt_version = nil,
		compaction_summary = nil,
		compaction_details = nil,
		plan = nil,
		last_usage = nil,
		usage_history = {},
		last_turn_ast_summary = nil,
		last_turn_ast_snapshot = nil,
	}, session)
end

function session:add_user(text)
	self.messages[#self.messages + 1] = {
		role = "user",
		text = text,
	}
end

function session:add_assistant(text)
	self.messages[#self.messages + 1] = {
		role = "assistant",
		text = text,
	}
end

function session:add_tool_result(name, text)
	self.messages[#self.messages + 1] = {
		role = "user",
		text = text,
		tool_name = name,
	}
end

function session:clear()
	self.messages = {}
	self.system_prompt = nil
	self.system_prompt_version = nil
	self.compaction_summary = nil
	self.compaction_details = nil
	self.plan = nil
	self.last_usage = nil
	self.usage_history = {}
	self.last_turn_ast_summary = nil
	self.last_turn_ast_snapshot = nil
end

function session:record_turn_ast(state)
	if type(state) ~= "table" then
		self.last_turn_ast_summary = nil
		self.last_turn_ast_snapshot = nil
		return
	end
	local summary = type(state.summary) == "function" and state:summary() or nil
	local snapshot = type(state.snapshot) == "function" and state:snapshot() or nil
	self.last_turn_ast_summary = summary ~= "" and summary or nil
	self.last_turn_ast_snapshot = snapshot
end

function session:get_system_prompt()
	if type(self.system_prompt) ~= "string" or self.system_prompt == "" or self.system_prompt_version ~= SYSTEM_PROMPT_VERSION then
		local system_prompt = require("agent.system_prompt")
		self.system_prompt = system_prompt.build({ cwd = self.cwd, flow = self.flow })
		self.system_prompt_version = SYSTEM_PROMPT_VERSION
	end
	return self.system_prompt
end

local function normalize_usage(usage, message_index)
	if type(usage) ~= "table" then
		return nil
	end
	local prompt_tokens = tonumber(usage.prompt_tokens or usage.input_tokens or usage.input)
	local cached_tokens = tonumber(usage.cached_tokens or usage.cache_read or usage.cacheRead) or 0
	local output_tokens = tonumber(usage.output_tokens or usage.output) or 0
	local total_tokens = tonumber(usage.total_tokens or usage.totalTokens or usage.total)
	if not prompt_tokens and not total_tokens then
		return nil
	end
	prompt_tokens = prompt_tokens or math.max(0, (total_tokens or 0) - output_tokens)
	total_tokens = total_tokens or (prompt_tokens + output_tokens)
	return {
		prompt_tokens = prompt_tokens,
		cached_tokens = cached_tokens,
		output_tokens = output_tokens,
		total_tokens = total_tokens,
		cached_percent = prompt_tokens > 0 and (cached_tokens / prompt_tokens * 100) or 0,
		message_index = tonumber(message_index) or 0,
		timestamp = os.time(),
	}
end

function session:record_usage(usage, message_index)
	local normalized = normalize_usage(usage, message_index)
	if normalized then
		self.last_usage = normalized
		self.usage_history = self.usage_history or {}
		self.usage_history[#self.usage_history + 1] = normalized
		local limit = math.max(0, tonumber(USAGE_HISTORY_LIMIT) or 50)
		while limit > 0 and #self.usage_history > limit do
			table.remove(self.usage_history, 1)
		end
		if limit == 0 then
			self.usage_history = {}
		end
	end
	return normalized
end

function session:turn_count()
	return math.floor(#self.messages / 2)
end

local DUMB_MODE_TOKEN_THRESHOLD = 120000

local function estimate_text_tokens(value)
	if type(value) ~= "string" then
		return 0
	end
	return math.ceil(#value / 4)
end

local function format_token_count(tokens)
	if tokens >= 1000 then
		return "~" .. math.floor((tokens + 500) / 1000) .. "k"
	end
	return "~" .. tokens
end

local function format_token_estimate(tokens)
	return format_token_count(tokens) .. " tokens"
end

function session:estimated_tokens()
	local tokens = 0
	for _, message in ipairs(self.messages) do
		tokens = tokens + estimate_text_tokens(message.role)
		tokens = tokens + estimate_text_tokens(message.tool_name)
		tokens = tokens + estimate_text_tokens(message.text)
		tokens = tokens + 6
	end
	tokens = tokens + estimate_text_tokens(self.compaction_summary)
	return tokens
end

function session:estimated_mcp_tokens()
	local tokens = 0
	for _, message in ipairs(self.messages) do
		local tool_name = message.tool_name
		if type(tool_name) == "string" and tool_name:match("^mcp__") then
			tokens = tokens + estimate_text_tokens(message.role)
			tokens = tokens + estimate_text_tokens(tool_name)
			tokens = tokens + estimate_text_tokens(message.text)
			tokens = tokens + 6
		end
	end
	return tokens
end

function session:estimated_session_tokens()
	return self:estimated_tokens()
end

function session:estimated_mcp_prompt_tokens()
	local _ = self
	local ok, registry = pcall(require, "agent.tool_registry")
	if not ok or not registry.mcp_prompt_section then
		return 0
	end
	return estimate_text_tokens(registry.mcp_prompt_section())
end

function session:estimated_system_prompt_tokens()
	local ok, full_system_prompt = pcall(function()
		return self:get_system_prompt()
	end)
	if not ok or type(full_system_prompt) ~= "string" then
		return 0
	end
	return math.max(0, estimate_text_tokens(full_system_prompt) - self:estimated_mcp_prompt_tokens())
end

function session:estimated_model_input_tokens()
	return self:estimated_session_tokens() + self:estimated_system_prompt_tokens() + self:estimated_mcp_prompt_tokens()
end

function session:estimated_model_input_tokens_usage_aware()
	local usage = self.last_usage
	if type(usage) ~= "table" or not usage.total_tokens or not usage.message_index then
		return self:estimated_model_input_tokens(), nil
	end
	local trailing = 0
	local start = math.max(1, math.floor(tonumber(usage.message_index) or 0) + 1)
	for i = start, #self.messages do
		local message = self.messages[i]
		trailing = trailing + estimate_text_tokens(message.role)
		trailing = trailing + estimate_text_tokens(message.tool_name)
		trailing = trailing + estimate_text_tokens(message.text)
		trailing = trailing + 6
	end
	return (tonumber(usage.total_tokens) or 0) + trailing, {
		usage_tokens = tonumber(usage.total_tokens) or 0,
		trailing_tokens = trailing,
		message_index = usage.message_index,
	}
end

function session:token_status()
	local tokens = self:estimated_model_input_tokens_usage_aware()
	local text = format_token_estimate(tokens) .. " model input"
	if tokens > DUMB_MODE_TOKEN_THRESHOLD then
		text = text .. " · dumb mode"
	end
	return text, tokens
end

function session:load_message(path)
	local session_tokens = self:estimated_session_tokens()
	local system_tokens = self:estimated_system_prompt_tokens()
	local mcp_tokens = self:estimated_mcp_prompt_tokens()
	local model_tokens = session_tokens + system_tokens + mcp_tokens

	local details = self:turn_count() .. " turns, " .. format_token_estimate(model_tokens) .. ", " .. format_token_count(session_tokens) .. " session, " .. format_token_count(system_tokens) .. " system"
	if mcp_tokens > 0 then
		details = details .. ", " .. format_token_count(mcp_tokens) .. " MCP"
	end
	if model_tokens > DUMB_MODE_TOKEN_THRESHOLD then
		details = details .. " · dumb mode"
	end

	return "session loaded from " .. (path or DEFAULT_SESSION_FILE) .. " (" .. details .. ")"
end

--- Serialize session state to a JSON-compatible table
function session:serialize()
	return {
		id = self.id,
		credentials_path = self.credentials_path,
		model = self.model,
		reasoning_effort = self.reasoning_effort,
		service_tier = self.service_tier,
		cwd = self.cwd,
		messages = self.messages,
		system_prompt = self.system_prompt,
		system_prompt_version = self.system_prompt_version,
		compaction_summary = self.compaction_summary,
		compaction_details = self.compaction_details,
		plan = self.plan,
		last_usage = self.last_usage,
		usage_history = self.usage_history,
		last_turn_ast_summary = self.last_turn_ast_summary,
		last_turn_ast_snapshot = self.last_turn_ast_snapshot,
	}
end

local function write_text_file(path, content)
	local f, err = io.open(path, "w")
	if not f then
		return false, "cannot write to " .. path .. ": " .. (err or "unknown error")
	end
	f:write(content)
	if content:sub(-1) ~= "\n" then
		f:write("\n")
	end
	f:close()
	return true
end

local function read_text_file(path)
	local f, err = io.open(path, "r")
	if not f then
		return nil, "cannot read " .. path .. ": " .. (err or "unknown error")
	end
	local content = f:read("*a")
	f:close()
	return content
end

--- Save session to a JSON file
function session:save(path)
	path = path or DEFAULT_SESSION_FILE
	local cjson = require("cjson")
	local data = self:serialize()
	local encoded = cjson.encode(data)
	return write_text_file(path, encoded)
end

--- Load session from a JSON file, restoring messages and compaction_summary
function session:load(path)
	path = path or DEFAULT_SESSION_FILE
	local cjson = require("cjson")
	local content, err = read_text_file(path)
	if not content then
		return false, err
	end
	local ok, data = pcall(cjson.decode, content)
	if not ok or type(data) ~= "table" then
		return false, "invalid session file: " .. path
	end
	if type(data.id) == "string" and data.id ~= "" then
		self.id = data.id
	elseif not self.id or self.id == "" then
		self.id = create_session_id(self.cwd)
	end
	-- Restore messages
	if type(data.messages) == "table" then
		self.messages = data.messages
	end
	if data.system_prompt_version == SYSTEM_PROMPT_VERSION and type(data.system_prompt) == "string" and data.system_prompt ~= "" then
		self.system_prompt = data.system_prompt
		self.system_prompt_version = data.system_prompt_version
	else
		self.system_prompt = nil
		self.system_prompt_version = nil
	end
	-- Restore compaction summary
	if data.compaction_summary and data.compaction_summary ~= require("cjson").null then
		self.compaction_summary = data.compaction_summary
	else
		self.compaction_summary = nil
	end
	if type(data.compaction_details) == "table" then
		self.compaction_details = data.compaction_details
	else
		self.compaction_details = nil
	end
	if type(data.plan) == "table" then
		self.plan = data.plan
	else
		self.plan = nil
	end
	if type(data.last_usage) == "table" then
		self.last_usage = data.last_usage
	else
		self.last_usage = nil
	end
	if type(data.usage_history) == "table" then
		self.usage_history = data.usage_history
	else
		self.usage_history = {}
	end
	if type(data.last_turn_ast_summary) == "string" and data.last_turn_ast_summary ~= "" then
		self.last_turn_ast_summary = data.last_turn_ast_summary
	else
		self.last_turn_ast_summary = nil
	end
	if type(data.last_turn_ast_snapshot) == "table" then
		self.last_turn_ast_snapshot = data.last_turn_ast_snapshot
	else
		self.last_turn_ast_snapshot = nil
	end
	-- Optionally restore model/credentials if present
	if data.model then
		self.model = data.model
	end
	if data.credentials_path then
		self.credentials_path = data.credentials_path
	end
	self.model = model_for_credentials(self.credentials_path, self.model)
	if data.reasoning_effort and data.reasoning_effort ~= require("cjson").null then
		self.reasoning_effort = resolve_reasoning_effort(data.reasoning_effort)
	end
	if data.service_tier and data.service_tier ~= require("cjson").null then
		self.service_tier = resolve_service_tier(data.service_tier)
	end
	self.flow = "off"
	return true
end

--- Save an explicit handoff summary for the next startup
function session:save_handoff(path)
	path = path or DEFAULT_HANDOFF_FILE

	local content
	if #self.messages == 0 then
		content = "# Handoff\n\n(no conversation yet)"
	else
		local compaction = require("agent.compaction")
		content = compaction.generate_summary(self.messages, self.compaction_summary, self)
		self.compaction_summary = content
	end

	return write_text_file(path, content)
end

--- Load HANDOFF.txt into an empty session as startup context
function session:load_handoff(path)
	path = path or DEFAULT_HANDOFF_FILE
	if #self.messages > 0 then
		return false, nil, 0
	end

	local content, err = read_text_file(path)
	if not content then
		return false, err, 0
	end
	if content == "" then
		return false, "handoff file is empty: " .. path, 0
	end

	self.compaction_summary = content
	self.messages[1] = {
		role = "user",
		text = "[Handoff loaded from " .. path .. "]\n\n" .. content,
	}
	self.messages[2] = {
		role = "assistant",
		text = "Understood. I have loaded the handoff context.",
	}

	return true, nil, #content
end

--- Default session file path
session.DEFAULT_SESSION_FILE = DEFAULT_SESSION_FILE
session.DEFAULT_HANDOFF_FILE = DEFAULT_HANDOFF_FILE
session.resolve_reasoning_effort = resolve_reasoning_effort
session.resolve_service_tier = resolve_service_tier
session.resolve_flow = resolve_flow
session.SYSTEM_PROMPT_VERSION = SYSTEM_PROMPT_VERSION
return session
