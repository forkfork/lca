local json = require("agent.util.json")
local config = require("agent.config")
local transport = require("agent.net.http_transport")

local codex = {}

local CODEX_HOST = "chatgpt.com"
local CODEX_PATH = "/backend-api/codex/responses"

local MAX_RETRIES = tonumber(os.getenv("LCA_CODEX_MAX_RETRIES") or "") or 2
local INITIAL_BACKOFF_SEC = 1
local FIRST_BYTE_TIMEOUT_SEC = tonumber(os.getenv("LCA_CODEX_FIRST_BYTE_TIMEOUT") or "") or 45
local IDLE_TIMEOUT_SEC = tonumber(os.getenv("LCA_CODEX_IDLE_TIMEOUT") or "") or 60
local TOTAL_TIMEOUT_SEC = tonumber(os.getenv("LCA_CODEX_TOTAL_TIMEOUT") or "") or 130
local POST_TOOL_THRESHOLD = tonumber(os.getenv("LCA_CODEX_POST_TOOL_THRESHOLD") or "") or 800
local PROMPT_CACHE_KEY_OVERRIDE = os.getenv("LCA_CODEX_PROMPT_CACHE_KEY")
local DEFAULT_SERVICE_TIER = os.getenv("LCA_CODEX_DEFAULT_SERVICE_TIER") or "priority"
local DUMP_REQUEST_DIR = os.getenv("LCA_CODEX_DUMP_REQUEST_DIR")
local LOG_RAW_USAGE = os.getenv("LCA_CODEX_LOG_RAW_USAGE") == "1"

local CLOSE_TOOL_CALL = "</tool_call>"
local CLOSE_TOOL_CALL_LEN = #CLOSE_TOOL_CALL
local last_prefix_hashes_by_key = {}
local dump_counter = 0

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

local function cancellable_sleep(seconds)
	local uv = require("luv")
	local deadline = uv.now() + math.max(0, seconds) * 1000
	local timer = uv.new_timer()
	timer:start(100, 100, function() end)
	while uv.now() < deadline do
		if cancel_requested() then
			timer:stop()
			timer:close()
			return false
		end
		uv.run("once")
	end
	timer:stop()
	timer:close()
	return true
end

local function load_credentials(path)
	local providers = require("agent.providers")
	local body = providers.credentials_body(path)
	local access = json.field(body, "access")
	local account_id = json.field(body, "accountId")
	if not access or not account_id then
		error("credentials file must contain access and accountId fields")
	end
	return {
		access = access,
		account_id = account_id,
	}
end

local function clamp_prompt_cache_key(key)
	if not key or key == "" then
		return nil
	end
	key = tostring(key):gsub("[^%w_.:-]", "-")
	if #key > 64 then
		key = key:sub(1, 64)
	end
	return key ~= "" and key or nil
end

local function prompt_cache_key(request)
	if PROMPT_CACHE_KEY_OVERRIDE ~= nil then
		return clamp_prompt_cache_key(PROMPT_CACHE_KEY_OVERRIDE)
	end
	return clamp_prompt_cache_key(request.prompt_cache_key or request.session_id)
end

local function cache_affinity_id(request)
	return prompt_cache_key(request)
end

local function service_tier(request)
	if request.service_tier ~= nil and request.service_tier ~= "" then
		return request.service_tier
	end
	if DEFAULT_SERVICE_TIER == "" or DEFAULT_SERVICE_TIER == "none" then
		return nil
	end
	return DEFAULT_SERVICE_TIER
end

local function codex_headers(credentials, request)
	local headers = {
		{ "Authorization", "Bearer " .. credentials.access },
		{ "chatgpt-account-id", credentials.account_id },
		{ "originator", "lca" },
		{ "OpenAI-Beta", "responses=experimental" },
		{ "Accept", "text/event-stream" },
		{ "Content-Type", "application/json" },
	}
	local affinity_id = cache_affinity_id(request)
	if affinity_id and affinity_id ~= "" then
		headers[#headers + 1] = { "session_id", affinity_id }
		headers[#headers + 1] = { "x-client-request-id", affinity_id }
	end
	return headers
end

local function invalidate_credentials_cache()
	local providers = require("agent.providers")
	if providers._invalidate_cache then
		providers._invalidate_cache()
	end
end

local function input_json(messages)
	local merged = {}
	for _, message in ipairs(messages) do
		if message.role ~= "user" and message.role ~= "assistant" then
			error("unsupported message role: " .. tostring(message.role))
		end
		local prev = merged[#merged]
		if prev and prev.role == message.role then
			prev.text = prev.text .. "\n\n" .. (message.text or "")
		else
			merged[#merged + 1] = { role = message.role, text = message.text or "" }
		end
	end

	local parts = {}
	for index, message in ipairs(merged) do
		local content_type = message.role == "assistant" and "output_text" or "input_text"
		parts[index] = table.concat({
			"{",
			'"role":' .. json.string(message.role) .. ",",
			'"content":[{"type":"' .. content_type .. '","text":' .. json.string(message.text) .. "}]",
			"}",
		})
	end
	return "[" .. table.concat(parts, ",") .. "]"
end

local function request_body(request)
	local request_prompt_cache_key = prompt_cache_key(request)
	local request_service_tier = service_tier(request)
	local parts = {
		"{",
		'"model":' .. json.string(request.model or "gpt-5.5") .. ",",
		'"store":false,',
		'"stream":true,',
		'"instructions":' .. json.string(request.system_prompt or "You are a helpful assistant.") .. ",",
		'"input":' .. input_json(request.messages or {}) .. ",",
		'"text":{"verbosity":"low"},',
	}
	if request_prompt_cache_key and request_prompt_cache_key ~= "" then
		parts[#parts + 1] = '"prompt_cache_key":' .. json.string(request_prompt_cache_key) .. ","
	end
	if request_service_tier then
		parts[#parts + 1] = '"service_tier":' .. json.string(request_service_tier) .. ","
	end
	if request.reasoning_effort then
		parts[#parts + 1] = '"reasoning":{"effort":' .. json.string(request.reasoning_effort) .. "},"
	end
	parts[#parts + 1] = '"include":["reasoning.encrypted_content"]'
	parts[#parts + 1] = "}"
	return table.concat(parts)
end

local function shell_quote(value)
	return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function dump_request_body(body, summary)
	if not DUMP_REQUEST_DIR or DUMP_REQUEST_DIR == "" then
		return nil
	end
	os.execute("mkdir -p " .. shell_quote(DUMP_REQUEST_DIR) .. " >/dev/null 2>&1")
	dump_counter = dump_counter + 1
	local name = string.format(
		"%s/%s-%03d-%s.json",
		DUMP_REQUEST_DIR,
		os.date("!%Y%m%dT%H%M%SZ"),
		dump_counter,
		(summary.prompt_cache_key ~= "" and summary.prompt_cache_key or "no-cache-key"):gsub("[^%w_.:-]", "-")
	)
	local f, err = io.open(name, "w")
	if not f then
		debug_log("[codex] request dump failed path=%s error=%s", name, tostring(err))
		return nil
	end
	f:write(body)
	f:close()
	debug_log("[codex] request dumped path=%s bytes=%d", name, #body)
	return name
end

local function fnv1a32(text)
	local hash = 2166136261
	for i = 1, #text do
		hash = hash ~ text:byte(i)
		hash = (hash * 16777619) % 4294967296
	end
	return string.format("%08x", hash)
end

local function prefix_fingerprints(body)
	local sizes = { 4096, 16384, 32768, 65536 }
	local parts = {}
	for _, size in ipairs(sizes) do
		if #body >= size then
			parts[#parts + 1] = tostring(size) .. "=" .. fnv1a32(body:sub(1, size))
		end
	end
	parts[#parts + 1] = "full=" .. fnv1a32(body)
	return table.concat(parts, " ")
end

local function parse_prefix_fingerprints(value)
	local out = {}
	for size, hash in tostring(value or ""):gmatch("(%w+)=([%x]+)") do
		out[size] = hash
	end
	return out
end

local function request_summary(request, body)
	local messages = request.messages or {}
	local role_counts = {}
	local total_message_chars = 0
	local longest_message_chars = 0
	for _, message in ipairs(messages) do
		local role = tostring(message.role or "unknown")
		local text = message.text or ""
		role_counts[role] = (role_counts[role] or 0) + 1
		total_message_chars = total_message_chars + #text
		if #text > longest_message_chars then
			longest_message_chars = #text
		end
	end

	local roles = {}
	for role, count in pairs(role_counts) do
		roles[#roles + 1] = role .. "=" .. tostring(count)
	end
	table.sort(roles)

	return {
		model = request.model or "gpt-5.5",
		reasoning_effort = request.reasoning_effort or "(default)",
		service_tier = service_tier(request) or "(default)",
		prompt_cache_key = prompt_cache_key(request) or "",
		message_count = #messages,
		role_counts = table.concat(roles, ","),
		total_message_chars = total_message_chars,
		longest_message_chars = longest_message_chars,
		system_prompt_chars = #(request.system_prompt or ""),
		body_bytes = #body,
		prefix_fingerprints = prefix_fingerprints(body),
	}
end

local function log_request_summary(prefix, summary)
	debug_log(
		"%s model=%s reasoning=%s service_tier=%s cache_key=%s messages=%d roles=%s message_chars=%d longest_message=%d system_prompt_chars=%d body_bytes=%d prefix_hashes=\"%s\"",
		prefix,
		tostring(summary.model),
		tostring(summary.reasoning_effort),
		tostring(summary.service_tier),
		summary.prompt_cache_key ~= "" and "(set:" .. summary.prompt_cache_key .. ")" or "(none)",
		summary.message_count,
		summary.role_counts ~= "" and summary.role_counts or "(none)",
		summary.total_message_chars,
		summary.longest_message_chars,
		summary.system_prompt_chars,
		summary.body_bytes,
		tostring(summary.prefix_fingerprints)
	)
end

local function log_prefix_stability(summary)
	local cache_key = summary.prompt_cache_key ~= "" and summary.prompt_cache_key or "(none)"
	local current = parse_prefix_fingerprints(summary.prefix_fingerprints)
	local previous = last_prefix_hashes_by_key[cache_key]
	local sizes = { "4096", "16384", "32768", "65536", "full" }
	local parts = {}
	for _, size in ipairs(sizes) do
		local now = current[size]
		local before = previous and previous[size] or nil
		local status
		if not now then
			status = "missing"
		elseif not before then
			status = "new"
		elseif before == now then
			status = "same"
		else
			status = "changed"
		end
		parts[#parts + 1] = size .. "=" .. status
	end
	debug_log("[codex] prefix stability cache_key=%s %s",
		cache_key ~= "(none)" and ("(set:" .. cache_key .. ")") or "(none)",
		table.concat(parts, " ")
	)
	last_prefix_hashes_by_key[cache_key] = current
end

local function is_auth_error(text)
	if not text then return false end
	return text:find('"error_code"%s*:%s*"token_expired"') ~= nil
		or text:find('"code"%s*:%s*"token_expired"') ~= nil
		or text:find('"code"%s*:%s*"invalid_api_key"') ~= nil
		or text:find("unauthorized") ~= nil
		or text:find("Unauthorized") ~= nil
		or text:find('"status"%s*:%s*401') ~= nil
end

local function is_retryable_http(status, body)
	if status == 429 then
		return true
	end
	if status and status >= 500 and status <= 599 then
		return true
	end
	body = body or ""
	return body:find("rate_limit") ~= nil
		or body:find("Rate limit") ~= nil
		or body:find("server_error") ~= nil
		or body:find("internal_error") ~= nil
		or body:find("overloaded") ~= nil
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

local function usage_number(value)
	if type(value) == "number" then return value end
	if type(value) == "string" then return tonumber(value) end
	return nil
end

local function usage_from_payload(payload)
	local ok, event = pcall(json.decode, payload)
	if not ok or type(event) ~= "table" then
		return nil
	end
	local usage = event.usage
	if type(usage) ~= "table" and type(event.response) == "table" then
		usage = event.response.usage
	end
	if type(usage) ~= "table" then
		return nil
	end
	local details = usage.prompt_tokens_details or usage.input_tokens_details or {}
	local prompt_tokens = usage_number(usage.prompt_tokens) or usage_number(usage.input_tokens)
	local cached_tokens = usage_number(details.cached_tokens) or 0
	local output_tokens = usage_number(usage.completion_tokens) or usage_number(usage.output_tokens) or 0
	local total_tokens = usage_number(usage.total_tokens) or usage_number(usage.totalTokens)
	if not prompt_tokens and cached_tokens == 0 then
		return nil
	end
	return {
		prompt_tokens = prompt_tokens,
		cached_tokens = cached_tokens,
		output_tokens = output_tokens,
		total_tokens = total_tokens or ((prompt_tokens or 0) + output_tokens),
		raw_usage = usage,
	}
end

local function sse_parser(on_delta, on_usage)
	local line_buffer = ""
	return function(chunk)
		line_buffer = line_buffer .. chunk
		while true do
			local pos = line_buffer:find("\n", 1, true)
			if not pos then
				return
			end
			local line = line_buffer:sub(1, pos - 1):gsub("\r$", "")
			line_buffer = line_buffer:sub(pos + 1)
			local payload = line:match("^data:%s*(.+)$")
			if payload then
				local event_type = json.field(payload, "type")
				if on_usage then
					local usage = usage_from_payload(payload)
					if usage then
						on_usage(usage)
					end
				end
				if event_type == "response.output_text.delta" then
					local delta = json.field(payload, "delta")
					if delta and delta ~= "" then
						if on_delta(delta) == false then
							return false
						end
					end
				end
			end
		end
	end
end

local function timing_summary(timings)
	if not timings then
		return "(none)"
	end
	return string.format(
		"connect=%.3f tls=%.3f write=%.3f first_byte=%s headers=%s total=%s",
		timings.connect or 0,
		timings.tls or 0,
		timings.write or 0,
		timings.first_byte and string.format("%.3f", timings.first_byte) or "never",
		timings.headers and string.format("%.3f", timings.headers) or "unknown",
		timings.total and string.format("%.3f", timings.total) or "unknown"
	)
end

local function post_tool_tail_kind(text)
	text = tostring(text or "")
	local pos = 1
	while true do
		local non_ws = text:find("%S", pos)
		if not non_ws then
			return pos == 1 and "whitespace" or "extra_close"
		end
		local tail = text:sub(non_ws)
		if CLOSE_TOOL_CALL:sub(1, #tail) == tail then
			return "partial_extra_close"
		end
		if tail:sub(1, CLOSE_TOOL_CALL_LEN) == CLOSE_TOOL_CALL then
			pos = non_ws + CLOSE_TOOL_CALL_LEN
		else
			if ("<tool_call"):sub(1, #tail) == tail then
				return "partial_next_tool"
			end
			if tail:find("^<tool_call%s") then
				return "next_tool"
			end
			return pos == 1 and "prose" or "extra_close_then_prose"
		end
	end
end

local function should_cut_after_tool(tail_kind, post_tool_chars)
	if tail_kind == "next_tool" or tail_kind == "partial_next_tool" then
		return false
	end
	return (tonumber(post_tool_chars) or 0) > POST_TOOL_THRESHOLD
end

local function canonical_tool_text(text)
	local ok, protocol = pcall(require, "agent.tool_protocol")
	if not ok or not protocol.extract_only_tool_calls_text then
		return text
	end
	local only_tools = protocol.extract_only_tool_calls_text(text or "")
	if only_tools ~= "" then
		return only_tools
	end
	return text
end

local function do_complete(request, credentials, body, on_token)
	local chunks = {}
	local full_stream = ""
	local tool_call_seen = false
	local tool_call_closed = false
	local last_tool_call_end = 0
	local cutoff = false
	local usage = nil
	local result, err = transport.request({
		host = request.host or CODEX_HOST,
		port = request.port or 443,
		path = request.path or CODEX_PATH,
		user_agent = "lca-codex/lowlevel",
		body = body,
		deadlines = default_deadlines(request),
		cancelled = function()
			return request.cancelled and request.cancelled() or cancel_requested()
		end,
		headers = codex_headers(credentials, request),
		on_body_chunk = sse_parser(function(delta)
			chunks[#chunks + 1] = delta
			full_stream = full_stream .. delta
			if on_token then
				on_token(delta)
			end
			if not tool_call_seen and full_stream:find("<tool_call") then
				tool_call_seen = true
			end
				if tool_call_seen then
					local close_pos = full_stream:find(CLOSE_TOOL_CALL, last_tool_call_end + 1, true)
					while close_pos do
						last_tool_call_end = close_pos + CLOSE_TOOL_CALL_LEN - 1
						tool_call_closed = true
						close_pos = full_stream:find(CLOSE_TOOL_CALL, last_tool_call_end + 1, true)
					end
				end
				if tool_call_closed then
					local after = full_stream:sub(last_tool_call_end + 1)
					local tail_kind = post_tool_tail_kind(after)
					if should_cut_after_tool(tail_kind, #after) then
						cutoff = true
						debug_log("[codex] early tool-call cutoff reason=%s post_tool_chars=%d response_chars=%d threshold=%d",
							tail_kind,
							#after,
							#full_stream,
							POST_TOOL_THRESHOLD
						)
						return false
					end
				end
		end, function(next_usage)
			usage = next_usage
		end),
	})

	if err then
		err.text_chunks = chunks
		return nil, err
	end
	result.text = table.concat(chunks)
	if cutoff or tool_call_seen then
		local canonical = canonical_tool_text(result.text)
		if canonical ~= result.text then
			debug_log("[codex] canonicalized tool response chars=%d->%d",
				#result.text,
				#canonical
			)
			result.text = canonical
		end
	end
	result.usage = usage
	result.early_cutoff = cutoff
	return result
end

function codex.complete(request, on_token)
	local credentials_path = request.credentials_path or config.default_credentials_path()
	local credentials = load_credentials(credentials_path)
	local body = request_body(request)
	local summary = request_summary(request, body)
	dump_request_body(body, summary)
	local max_retries = request.max_retries
	if max_retries == nil then
		max_retries = MAX_RETRIES
	end

	local last_error = nil
	for attempt = 0, max_retries do
		log_request_summary("[codex] attempt " .. tostring(attempt + 1) .. "/" .. tostring(max_retries + 1), summary)
		if attempt == 0 then
			log_prefix_stability(summary)
		end
		local result, err = do_complete(request, credentials, body, on_token)
		if result then
			debug_log("[codex] attempt %d succeeded http_status=%s response_chars=%d response_bytes=%d timing=%s",
				attempt + 1,
				tostring(result.status or "unknown"),
				#(result.text or ""),
				result.response_bytes or 0,
				timing_summary(result.timings)
			)
			if result.usage then
				local prompt_tokens = tonumber(result.usage.prompt_tokens) or 0
				local cached_tokens = tonumber(result.usage.cached_tokens) or 0
				local pct = prompt_tokens > 0 and (cached_tokens / prompt_tokens * 100) or 0
				debug_log("[codex] prompt cache prompt_tokens=%d cached_tokens=%d cached=%.1f%%",
					prompt_tokens,
					cached_tokens,
					pct
				)
				if LOG_RAW_USAGE and cached_tokens == 0 and result.usage.raw_usage then
					local ok, encoded = pcall(json.encode, result.usage.raw_usage)
					if ok and encoded then
						debug_log("[codex] prompt cache raw_usage=%s", encoded:sub(1, 1200):gsub("\n", "\\n"))
					end
				end
			else
				debug_log("[codex] prompt cache usage unavailable reason=%s",
					result.early_cutoff and "early_cutoff" or "missing_usage_event"
				)
			end

			local body_tail = result.body_tail or ""
			if result.status >= 400 then
				debug_log("[codex] HTTP error status=%d body=%s",
					result.status,
					body_tail:sub(1, 2000):gsub("\n", "\\n")
				)
				if is_auth_error(body_tail) then
					invalidate_credentials_cache()
					last_error = "Codex auth error: " .. body_tail:sub(1, 500)
					if attempt < max_retries and result.text == "" then
						credentials = load_credentials(credentials_path)
					else
						error(last_error)
					end
				end
				if is_retryable_http(result.status, body_tail) and attempt < max_retries and result.text == "" then
					last_error = "Codex HTTP error " .. tostring(result.status) .. ": " .. body_tail:sub(1, 200)
				else
					error("Codex HTTP error " .. tostring(result.status) .. ": " .. body_tail:sub(1, 500))
				end
			elseif result.text == "" and body_tail ~= "" then
				if is_auth_error(body_tail) then
					invalidate_credentials_cache()
					last_error = "Codex auth error: " .. body_tail:sub(1, 500)
					if attempt < max_retries then
						credentials = load_credentials(credentials_path)
					else
						error(last_error)
					end
				else
					error("Codex empty stream: " .. body_tail:sub(1, 500))
				end
			else
				return {
					text = result.text,
					_usage = result.usage,
					_usage_status = result.usage and "available" or (result.early_cutoff and "early_cutoff" or "missing_usage_event"),
					_http_status = result.status,
					_timings = result.timings,
					_response_bytes = result.response_bytes,
				}
			end
		else
			local streamed_chunks = err.text_chunks or {}
			local no_streamed_text = #streamed_chunks == 0
			last_error = string.format(
				"Codex transport error (%s/%s): %s",
				tostring(err.kind),
				tostring(err.phase or "unknown"),
				tostring(err.detail)
			)
			debug_log("[codex] attempt %d failed: %s response_bytes=%d timing=%s",
				attempt + 1,
				last_error,
				err.response_bytes or 0,
				timing_summary(err.timings)
			)

			if err.kind == "cancelled" then
				error("cancelled")
			end

			local retryable_no_bytes = err.kind == "timeout"
				and err.phase == "first_byte"
				and (err.response_bytes or 0) == 0
				and no_streamed_text
			if not retryable_no_bytes or attempt >= max_retries then
				error(last_error)
			end
		end

		if attempt < max_retries then
			local backoff = INITIAL_BACKOFF_SEC * (2 ^ attempt)
			debug_log("[codex] retrying after %ds", backoff)
			if not cancellable_sleep(backoff) then
				error("cancelled")
			end
		end
	end

	log_request_summary("[codex] final failure request", summary)
	error("Codex request failed after " .. tostring(max_retries + 1) .. " attempts: " .. tostring(last_error or "unknown error"))
end

codex._request_body = request_body
codex._input_json = input_json
codex._canonical_tool_text = canonical_tool_text
codex._post_tool_tail_kind = post_tool_tail_kind
codex._should_cut_after_tool = should_cut_after_tool
codex._prompt_cache_key = prompt_cache_key
codex._usage_from_payload = usage_from_payload
codex._headers = codex_headers

return codex
