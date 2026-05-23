local session = {}
session.__index = session

local json = require("agent.util.json")
local config = require("agent.config")

local DEFAULT_SESSION_FILE = ".lca-session.json"
local DEFAULT_HANDOFF_FILE = "HANDOFF.txt"

local function current_dir()
	local uv = require("luv")
	return uv.cwd() or "."
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
	return options.model or "gpt-5.5"
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
	return setmetatable({
		credentials_path = options.credentials_path or config.default_credentials_path(),
		model = resolve_model(options),
		reasoning_effort = resolve_reasoning_effort(options.reasoning_effort),
		service_tier = resolve_service_tier(options.service_tier),
		cwd = current_dir(),
		messages = {},
		compaction_summary = nil,
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
	self.compaction_summary = nil
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

local function format_token_estimate(tokens)
	if tokens >= 1000 then
		return "~" .. math.floor((tokens + 500) / 1000) .. "k tokens"
	end
	return "~" .. tokens .. " tokens"
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
	local ok, registry = pcall(require, "agent.tool_registry")
	if not ok or not registry.mcp_prompt_section then
		return 0
	end
	return estimate_text_tokens(registry.mcp_prompt_section())
end

function session:estimated_system_prompt_tokens()
	local ok, system_prompt = pcall(require, "agent.system_prompt")
	if not ok or not system_prompt.build then
		return 0
	end
	local full_system_prompt = system_prompt.build({ cwd = self.cwd })
	return math.max(0, estimate_text_tokens(full_system_prompt) - self:estimated_mcp_prompt_tokens())
end

function session:estimated_model_input_tokens()
	return self:estimated_session_tokens() + self:estimated_system_prompt_tokens() + self:estimated_mcp_prompt_tokens()
end

function session:token_status()
	local tokens = self:estimated_model_input_tokens()
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

	local details = self:turn_count() .. " turns, " .. format_token_estimate(model_tokens) .. ", " .. format_token_estimate(session_tokens) .. " session, " .. format_token_estimate(system_tokens) .. " system"
	if mcp_tokens > 0 then
		details = details .. ", " .. format_token_estimate(mcp_tokens) .. " MCP"
	end
	if model_tokens > DUMB_MODE_TOKEN_THRESHOLD then
		details = details .. " · dumb mode"
	end

	return "session loaded from " .. (path or DEFAULT_SESSION_FILE) .. " (" .. details .. ")"
end

--- Serialize session state to a JSON-compatible table
function session:serialize()
	return {
		credentials_path = self.credentials_path,
		model = self.model,
		reasoning_effort = self.reasoning_effort,
		service_tier = self.service_tier,
		cwd = self.cwd,
		messages = self.messages,
		compaction_summary = self.compaction_summary,
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
	-- Restore messages
	if type(data.messages) == "table" then
		self.messages = data.messages
	end
	-- Restore compaction summary
	if data.compaction_summary and data.compaction_summary ~= require("cjson").null then
		self.compaction_summary = data.compaction_summary
	else
		self.compaction_summary = nil
	end
	-- Optionally restore model/credentials if present
	if data.model then
		self.model = data.model
	end
	if data.credentials_path then
		self.credentials_path = data.credentials_path
	end
	if data.reasoning_effort and data.reasoning_effort ~= require("cjson").null then
		self.reasoning_effort = resolve_reasoning_effort(data.reasoning_effort)
	end
	if data.service_tier and data.service_tier ~= require("cjson").null then
		self.service_tier = resolve_service_tier(data.service_tier)
	end
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

return session
