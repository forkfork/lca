local session = {}
session.__index = session

local config = require("agent.config")
local fs = require("agent.util.fs")
local operational_state = require("agent.operational_state")

local DEFAULT_SESSION_FILE = ".lca-session.json"
local SESSION_ARCHIVE_DIR = ".lca-sessions"
local DEFAULT_MODEL = config.default_model()
local USAGE_HISTORY_LIMIT = 50
local SYSTEM_PROMPT_VERSION = 30

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
	local model = options.model or DEFAULT_MODEL
	if model ~= "gpt-6-astra" and model ~= "gpt-5.6-sol" and model ~= "gpt-5.6-terra" and model ~= "gpt-5.6-luna" then
		error("unsupported model: " .. tostring(model) .. " (LCA supports GPT-6 Astra and Codex GPT-5.6)")
	end
	return model
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

local function resolve_reasoning_effort(value, model)
	if not value or value == "" then
		return nil
	end
	value = tostring(value):lower()
	if (model or DEFAULT_MODEL) == "gpt-6-astra" then
		if value == "none" or value == "minimal" then return "low" end
		if value == "max" then return value end
	end
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
	options = options or {}
	for _, key in ipairs({ "delegate_readonly_enabled", "tool_dag_enabled", "readonly_fork_join_enabled", "delegate_readonly_profile" }) do
		if options[key] ~= nil and options[key] ~= false then
			error("retired experiment option: " .. key .. "; see research/archive/README.md")
		end
	end
	local cwd = current_dir()
	local resolved_model = resolve_model(options)
	return setmetatable({
		id = options.session_id or create_session_id(cwd),
		executor = options.executor or require("agent.util.shell"),
		credentials_path = options.credentials_path or config.default_credentials_path(),
		model = resolved_model,
			reasoning_effort = resolve_reasoning_effort(options.reasoning_effort, resolved_model),
			service_tier = resolve_service_tier(options.service_tier),
			tool_scope = options.tool_scope,
			native_tool_calling = true,
			native_tool_pair_closure = options.native_tool_pair_closure ~= false,
			read_only_batch_cap = tonumber(options.read_only_batch_cap),
			read_batch_bytes = tonumber(options.read_batch_bytes),
			grep_evidence = options.grep_evidence ~= false,
			stale_edit_evidence = options.stale_edit_evidence ~= false,
			intra_turn_compaction = options.intra_turn_compaction,
			context_compaction_threshold = tonumber(options.context_compaction_threshold),
			context_hard_limit = tonumber(options.context_hard_limit),
			compaction_keep_recent_tokens = tonumber(options.compaction_keep_recent_tokens),
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

function session:add_assistant(text, provider_items)
	local message = {
		role = "assistant",
		text = text,
	}
	if type(provider_items) == "table" and #provider_items > 0 then
		message.provider_items = provider_items
	end
	self.messages[#self.messages + 1] = message
end

function session:add_tool_result(name, text, native_call_id)
	local message = {
		role = "user",
		text = text,
		tool_name = name,
	}
	if native_call_id then message.native_call_id = native_call_id end
	self.messages[#self.messages + 1] = message
end

function session:clear()
	self.messages = {}
	self.system_prompt = nil
	self.system_prompt_version = nil
	self.compaction_summary = nil
	self.compaction_details = nil
	self.operational_state = nil
	self.operational_prompt_tokens = nil
	self.operational_checkpoint_pending = nil
	self.plan = nil
	self.journey = nil
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
	if type(self.system_prompt) ~= "string" or self.system_prompt == "" or self.system_prompt_version ~= SYSTEM_PROMPT_VERSION
		or self.system_prompt_native_tools ~= true then
		local system_prompt = require("agent.system_prompt")
		self.system_prompt = system_prompt.build({
			cwd = self.cwd,
			model = self.model,
		})
		self.system_prompt_version = SYSTEM_PROMPT_VERSION
		self.system_prompt_native_tools = true
	end
	return self.system_prompt
end

local function normalize_usage(usage, message_index)
	if type(usage) ~= "table" then
		return nil
	end
	local prompt_tokens = tonumber(usage.prompt_tokens or usage.input_tokens or usage.input)
	local cached_tokens = tonumber(usage.cached_tokens or usage.cache_read or usage.cacheRead) or 0
	local cache_write_tokens = tonumber(usage.cache_write_tokens or usage.cache_write or usage.cacheWrite) or 0
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
		cache_available = usage.cache_available == true or cached_tokens > 0,
		cache_write_tokens = cache_write_tokens,
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
		normalized.operational_tokens = self.operational_prompt_tokens or 0
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
		+ operational_state.tokens(self)
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
	local state_growth = math.max(0, operational_state.tokens(self) - (tonumber(usage.operational_tokens) or 0))
	return (tonumber(usage.total_tokens) or 0) + trailing + state_growth, {
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
	local model_tokens = session_tokens + system_tokens + mcp_tokens + operational_state.tokens(self)

	local details = self:turn_count() .. " turns, " .. format_token_estimate(model_tokens) .. ", " .. format_token_count(session_tokens) .. " session, " .. format_token_count(system_tokens) .. " system"
	if mcp_tokens > 0 then
		details = details .. ", " .. format_token_count(mcp_tokens) .. " MCP"
	end
	if model_tokens > DUMB_MODE_TOKEN_THRESHOLD then
		details = details .. " · dumb mode"
	end

	local repaired = tonumber(self.native_history_repairs) or 0
	local repair_note = repaired > 0 and (" · repaired " .. tostring(repaired) .. " orphaned tool call" .. (repaired == 1 and "" or "s")) or ""
	return "session loaded from " .. (path or DEFAULT_SESSION_FILE) .. " (" .. details .. ")" .. repair_note
end

--- Serialize session state to a JSON-compatible table
function session:serialize()
	return {
		id = self.id,
		credentials_path = self.credentials_path,
		model = self.model,
		reasoning_effort = self.reasoning_effort,
		service_tier = self.service_tier,
		read_only_batch_cap = self.read_only_batch_cap,
		read_batch_bytes = self.read_batch_bytes,
		native_tool_pair_closure = self.native_tool_pair_closure,
		cwd = self.cwd,
		messages = self.messages,
		system_prompt = self.system_prompt,
		system_prompt_version = self.system_prompt_version,
		system_prompt_native_tools = self.system_prompt_native_tools,
		compaction_summary = self.compaction_summary,
		compaction_details = self.compaction_details,
		operational_state = self.operational_state,
		plan = self.plan,
		pending_inputs = self.pending_inputs,
		test_command = self.test_command,
		continuation_options = { tool_scope=self.tool_scope, grep_evidence=self.grep_evidence, stale_edit_evidence=self.stale_edit_evidence, intra_turn_compaction=self.intra_turn_compaction, context_compaction_threshold=self.context_compaction_threshold, context_hard_limit=self.context_hard_limit, compaction_keep_recent_tokens=self.compaction_keep_recent_tokens },
		last_usage = self.last_usage,
		usage_history = self.usage_history,
		last_turn_ast_summary = self.last_turn_ast_summary,
		last_turn_ast_snapshot = self.last_turn_ast_snapshot,
	}
end

local function write_text_file(path, content)
	if content:sub(-1) ~= "\n" then
		content = content .. "\n"
	end
	local ok, err = pcall(fs.write_file, path, content)
	if not ok then return false, err end
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

local function archive_dir_for(path)
	local parent = tostring(path):match("^(.*)/[^/]+$")
	return parent and parent ~= "" and (parent .. "/" .. SESSION_ARCHIVE_DIR) or SESSION_ARCHIVE_DIR
end

local function archive_previous_session(path, next_id)
	local content = read_text_file(path)
	if not content then return true end
	local cjson = require("cjson")
	local ok, previous = pcall(cjson.decode, content)
	if not ok or type(previous) ~= "table" or type(previous.id) ~= "string"
		or previous.id == "" or previous.id == next_id
	then
		return true
	end
	local archive_dir = archive_dir_for(path)
	local uv = require("luv")
	local made, mkdir_err = uv.fs_mkdir(archive_dir, tonumber("755", 8))
	if not made and not tostring(mkdir_err):find("EEXIST", 1, true) then
		return false, "cannot archive previous session: " .. tostring(mkdir_err)
	end
	local safe_id = previous.id:gsub("[^%w._-]", "_")
	return write_text_file(archive_dir .. "/" .. safe_id .. ".json", content)
end

local function repair_orphan_native_calls(messages)
	local outputs = {}
	for _, message in ipairs(messages or {}) do
		if message.native_call_id then outputs[tostring(message.native_call_id)] = true end
		for _, item in ipairs(type(message.provider_items) == "table" and message.provider_items or {}) do
			if item.type == "function_call_output" and item.call_id then outputs[tostring(item.call_id)] = true end
		end
	end
	local repaired, normalized = 0, {}
	for _, message in ipairs(messages or {}) do
		local items = message.provider_items
		if type(items) == "table" and #items > 0 then
			local kept = {}
			for _, item in ipairs(items) do
				if item.type == "function_call" and item.call_id and not outputs[tostring(item.call_id)] then
					repaired = repaired + 1
				else
					kept[#kept + 1] = item
				end
			end
			if #kept > 0 then
				message.provider_items = kept
				normalized[#normalized + 1] = message
			elseif repaired == 0 then
				normalized[#normalized + 1] = message
			end
		else
			normalized[#normalized + 1] = message
		end
	end
	return normalized, repaired
end

--- Save session to a JSON file
function session:save(path)
	path = path or DEFAULT_SESSION_FILE
	local cjson = require("cjson")
	local data = self:serialize()
	local encoded = cjson.encode(data)
	if path == DEFAULT_SESSION_FILE then
		local archived, archive_err = archive_previous_session(path, self.id)
		if not archived then return false, archive_err end
	end
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
	require("agent.background").assert_local(self)
	self.pending_inputs = type(data.pending_inputs) == "table" and data.pending_inputs or {}
	self.test_command = data.test_command
	-- Restore messages
	if type(data.messages) == "table" then
		self.messages, self.native_history_repairs = repair_orphan_native_calls(data.messages)
	end
	self.read_only_batch_cap = tonumber(data.read_only_batch_cap) or self.read_only_batch_cap
	self.read_batch_bytes = tonumber(data.read_batch_bytes) or self.read_batch_bytes
	self.native_tool_pair_closure = data.native_tool_pair_closure ~= false
	self.native_tool_calling = true
	if data.system_prompt_version == SYSTEM_PROMPT_VERSION and type(data.system_prompt) == "string" and data.system_prompt ~= ""
		and data.system_prompt_native_tools == true and data.model == self.model then
		self.system_prompt = data.system_prompt
		self.system_prompt_version = data.system_prompt_version
		self.system_prompt_native_tools = data.system_prompt_native_tools
	else
		self.system_prompt = nil
		self.system_prompt_version = nil
		self.system_prompt_native_tools = nil
	end
	-- Restore compaction summary
	self.operational_state = type(data.operational_state) == "table" and data.operational_state.version == 1
		and data.operational_state or nil
	if self.operational_state then
		-- Work may have changed outside this process while the session was closed.
		self.operational_state.resumed = true
		self.operational_checkpoint_pending = true
	end
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
	-- Model, provider credentials, and native-tool mode are launch policy, not
	-- resumable conversation state. Old sessions can restore their messages but
	-- cannot switch this process back to a retired runtime.
	if data.reasoning_effort and data.reasoning_effort ~= require("cjson").null then
		self.reasoning_effort = resolve_reasoning_effort(data.reasoning_effort, self.model)
	end
	if data.service_tier and data.service_tier ~= require("cjson").null then
		self.service_tier = resolve_service_tier(data.service_tier)
	end
	return true
end

--- Default session file path
session.DEFAULT_SESSION_FILE = DEFAULT_SESSION_FILE
session.SESSION_ARCHIVE_DIR = SESSION_ARCHIVE_DIR
session.resolve_reasoning_effort = resolve_reasoning_effort
session.resolve_service_tier = resolve_service_tier
session.SYSTEM_PROMPT_VERSION = SYSTEM_PROMPT_VERSION
return session
