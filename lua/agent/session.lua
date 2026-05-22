local session = {}
session.__index = session

local json = require("agent.util.json")
local config = require("agent.config")

local DEFAULT_SESSION_FILE = ".pi-lua-session.json"

local function current_dir()
	local uv = require("luv")
	return uv.cwd() or "."
end

local function resolve_model(options)
	if options.model and options.model ~= "gpt-5.4-mini" then
		return options.model
	end
	local providers = require("agent.providers")
	local path = options.credentials_path or config.default_credentials_path()
	local ok, body = pcall(providers.credentials_body, path)
	if not ok then return options.model or "gpt-5.4-mini" end
	local provider = json.field(body, "provider")
	if provider == "bedrock" then
		local model = json.field(body, "model")
		return model or "us.anthropic.claude-opus-4-6-v1"
	end
	return options.model or "gpt-5.4-mini"
end

function session.create(options)
	return setmetatable({
		credentials_path = options.credentials_path or config.default_credentials_path(),
		model = resolve_model(options),
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

--- Serialize session state to a JSON-compatible table
function session:serialize()
	return {
		credentials_path = self.credentials_path,
		model = self.model,
		cwd = self.cwd,
		messages = self.messages,
		compaction_summary = self.compaction_summary,
	}
end

--- Save session to a JSON file
function session:save(path)
	path = path or DEFAULT_SESSION_FILE
	local cjson = require("cjson")
	local data = self:serialize()
	local encoded = cjson.encode(data)
	local f, err = io.open(path, "w")
	if not f then
		return false, "cannot write to " .. path .. ": " .. (err or "unknown error")
	end
	f:write(encoded)
	f:write("\n")
	f:close()
	return true
end

--- Load session from a JSON file, restoring messages and compaction_summary
function session:load(path)
	path = path or DEFAULT_SESSION_FILE
	local cjson = require("cjson")
	local f, err = io.open(path, "r")
	if not f then
		return false, "cannot read " .. path .. ": " .. (err or "unknown error")
	end
	local content = f:read("*a")
	f:close()
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
	return true
end

--- Default session file path
session.DEFAULT_SESSION_FILE = DEFAULT_SESSION_FILE

return session
