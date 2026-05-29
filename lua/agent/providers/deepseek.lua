local json = require("agent.util.json")
local config = require("agent.config")
local transport = require("agent.net.http_transport")

local deepseek = {}

local DEFAULT_HOST = "api.deepseek.com"
local DEFAULT_PATH = "/chat/completions"
local DEFAULT_MODEL = "deepseek-v4-pro"
local TOOL_PROTOCOL_PROMPT = [[

## DeepSeek tool protocol reminder
- Tools are plain XML-like tags in your assistant text, not native function calls.
- When using a tool, output only complete <tool_call ...> blocks. Do not wrap them in Markdown fences.
- The JSON argument object must be valid JSON with double-quoted keys and string values.
- For read-only tools, use this exact shape:
<tool_call name="read">
{"path":"README.md"}
</tool_call>
- For edit/write, put metadata JSON on the first line and raw file content after it, before </tool_call>.
- After </tool_call>, stop immediately. Do not explain what you are doing until tool results are returned.
]]

local FIRST_BYTE_TIMEOUT_SEC = 45
local IDLE_TIMEOUT_SEC = 60
local TOTAL_TIMEOUT_SEC = 600
local MAX_SSE_LINE_BYTES = 262144

local function debug_log(fmt, ...)
	local ok, core = pcall(require, "agent.core")
	if ok and core.debug_log then
		core.debug_log(fmt, ...)
	end
end

local function cancel_requested()
	local ok, repl = pcall(require, "agent.repl")
	return ok and repl.cancelled
end

local function load_credentials(path)
	local providers = require("agent.providers")
	local body = providers.credentials_body(path)
	local api_key = json.field(body, "apiKey") or json.field(body, "api_key") or os.getenv("DEEPSEEK_API_KEY")
	if not api_key or api_key == "" then
		error("deepseek credentials must contain apiKey, or DEEPSEEK_API_KEY must be set")
	end
	return {
		api_key = api_key,
		model = json.field(body, "model"),
		base_url = json.field(body, "baseUrl") or json.field(body, "base_url"),
	}
end

local function parse_base_url(base_url)
	base_url = tostring(base_url or "")
	if base_url == "" then
		return DEFAULT_HOST, DEFAULT_PATH
	end
	local host, path = base_url:match("^https://([^/]+)(/.*)$")
	if not host then
		host = base_url:match("^https://([^/]+)$")
		path = ""
	end
	if not host then
		error("deepseek baseUrl must be an https URL")
	end
	path = path or ""
	if path == "" or path == "/" then
		path = DEFAULT_PATH
	elseif not path:find("/chat/completions$", 1, false) then
		path = path:gsub("/$", "") .. DEFAULT_PATH
	end
	return host, path
end

local function message_table(request)
	local messages = {
		{
			role = "system",
			content = (request.system_prompt or "You are a helpful assistant.") .. TOOL_PROTOCOL_PROMPT,
		},
	}
	for _, message in ipairs(request.messages or {}) do
		if message.role ~= "user" and message.role ~= "assistant" then
			error("unsupported message role: " .. tostring(message.role))
		end
		messages[#messages + 1] = {
			role = message.role,
			content = message.text or "",
		}
	end
	return messages
end

local function normalized_reasoning_effort(value)
	if value == "xhigh" then
		return "max"
	end
	if value == "low" or value == "medium" then
		return "high"
	end
	return value
end

local function request_table(request, credentials)
	local tbl = {
		model = request.model or credentials.model or DEFAULT_MODEL,
		messages = message_table(request),
		stream = true,
	}
	if request.reasoning_effort == "none" then
		tbl.thinking = { type = "disabled" }
	elseif request.reasoning_effort then
		tbl.thinking = { type = "enabled" }
		tbl.reasoning_effort = normalized_reasoning_effort(request.reasoning_effort)
	end
	return tbl
end

local function request_body(request, credentials)
	return json.encode(request_table(request, credentials or {}))
end

local function default_deadlines(request)
	local deadlines = {
		connect = 15,
		tls = 15,
		write = 15,
		first_byte = FIRST_BYTE_TIMEOUT_SEC,
		idle = IDLE_TIMEOUT_SEC,
		total = TOTAL_TIMEOUT_SEC,
	}
	for key, value in pairs(request.deadlines or {}) do
		deadlines[key] = value
	end
	return deadlines
end

local function headers(credentials)
	return {
		{ "Authorization", "Bearer " .. credentials.api_key },
		{ "Accept", "text/event-stream" },
		{ "Content-Type", "application/json" },
	}
end

local function usage_number(value)
	if type(value) == "number" then return value end
	if type(value) == "string" then return tonumber(value) end
	return nil
end

local function usage_from_event(event)
	local usage = type(event) == "table" and event.usage or nil
	if type(usage) ~= "table" then
		return nil
	end
	local details = usage.prompt_tokens_details or {}
	local prompt_tokens = usage_number(usage.prompt_tokens)
	local cached_tokens = usage_number(details.cached_tokens) or 0
	local output_tokens = usage_number(usage.completion_tokens) or 0
	local total_tokens = usage_number(usage.total_tokens)
	return {
		prompt_tokens = prompt_tokens,
		cached_tokens = cached_tokens,
		output_tokens = output_tokens,
		total_tokens = total_tokens or ((prompt_tokens or 0) + output_tokens),
		raw_usage = usage,
	}
end

local function sse_parser(on_delta, on_reasoning, on_usage)
	local line_buffer = ""
	return function(chunk)
		line_buffer = line_buffer .. chunk
		if #line_buffer > MAX_SSE_LINE_BYTES then
			error("DeepSeek SSE line exceeded " .. tostring(MAX_SSE_LINE_BYTES) .. " bytes")
		end
		while true do
			local pos = line_buffer:find("\n", 1, true)
			if not pos then
				return
			end
			local line = line_buffer:sub(1, pos - 1):gsub("\r$", "")
			line_buffer = line_buffer:sub(pos + 1)
			local payload = line:match("^data:%s*(.+)$")
			if payload and payload ~= "[DONE]" then
				local ok, event = pcall(json.decode, payload)
				if ok and type(event) == "table" then
					local usage = usage_from_event(event)
					if usage and on_usage then
						on_usage(usage)
					end
					local choice = type(event.choices) == "table" and event.choices[1] or nil
					local delta = type(choice) == "table" and choice.delta or nil
					if type(delta) == "table" then
						if type(delta.reasoning_content) == "string" and delta.reasoning_content ~= "" and on_reasoning then
							on_reasoning(delta.reasoning_content)
						end
						if type(delta.content) == "string" and delta.content ~= "" then
							if on_delta(delta.content) == false then
								return false
							end
						end
					end
				end
			end
		end
	end
end

local function do_complete(request, credentials, body, on_token)
	local host, path = parse_base_url(credentials.base_url)
	local chunks = {}
	local reasoning_chunks = {}
	local usage = nil
	local result, err = transport.request({
		host = request.host or host,
		port = request.port or 443,
		path = request.path or path,
		user_agent = "lca-deepseek/lowlevel",
		body = body,
		deadlines = default_deadlines(request),
		headers = headers(credentials),
		cancelled = function()
			return request.cancelled and request.cancelled() or cancel_requested()
		end,
		on_body_chunk = sse_parser(function(delta)
			chunks[#chunks + 1] = delta
			if on_token then
				on_token(delta)
			end
		end, function(delta)
			reasoning_chunks[#reasoning_chunks + 1] = delta
		end, function(next_usage)
			usage = next_usage
		end),
	})
	if err then
		return nil, err
	end
	result.text = table.concat(chunks)
	result.reasoning_text = table.concat(reasoning_chunks)
	result.usage = usage
	return result
end

function deepseek.complete(request, on_token)
	local credentials_path = request.credentials_path or config.default_credentials_path()
	local credentials = load_credentials(credentials_path)
	local body = request_body(request, credentials)
	local result, err = do_complete(request, credentials, body, on_token)
	if err then
		error("DeepSeek transport error: " .. tostring(err.kind or "unknown") .. " " .. tostring(err.detail or ""))
	end
	debug_log("[deepseek] model=%s messages=%d response_chars=%d reasoning_chars=%d status=%s",
		tostring((request.model or credentials.model or DEFAULT_MODEL)),
		#(request.messages or {}),
		#(result.text or ""),
		#(result.reasoning_text or ""),
		tostring(result.status or "unknown")
	)
	if result.status >= 400 then
		error("DeepSeek HTTP error " .. tostring(result.status) .. ": " .. (result.body_tail or ""):sub(1, 500))
	end
	return {
		text = result.text,
		_usage = result.usage,
		_usage_status = result.usage and "available" or "missing_usage_event",
		_http_status = result.status,
		_timings = result.timings,
		_response_bytes = result.response_bytes,
	}
end

deepseek._request_body = request_body
deepseek._parse_base_url = parse_base_url
deepseek._sse_parser = sse_parser

return deepseek
