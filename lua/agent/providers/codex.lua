local json = require("agent.util.json")
local config = require("agent.config")
local transport = require("agent.net.http_transport")
local websocket_transport = require("agent.net.websocket_transport")

local codex = {}

local CODEX_HOST = "chatgpt.com"
local CODEX_PATH = "/backend-api/codex/responses"

local MAX_RETRIES = tonumber(os.getenv("LCA_CODEX_MAX_RETRIES") or "") or 2
local INITIAL_BACKOFF_SEC = 1
local FIRST_BYTE_TIMEOUT_SEC = tonumber(os.getenv("LCA_CODEX_FIRST_BYTE_TIMEOUT") or "") or 45
local IDLE_TIMEOUT_SEC = tonumber(os.getenv("LCA_CODEX_IDLE_TIMEOUT") or "") or 60
local TOTAL_TIMEOUT_SEC = tonumber(os.getenv("LCA_CODEX_TOTAL_TIMEOUT") or "") or 600
local POST_TOOL_THRESHOLD = tonumber(os.getenv("LCA_CODEX_POST_TOOL_THRESHOLD") or "") or 800
local MAX_OUTPUT_TEXT_CHARS = tonumber(os.getenv("LCA_CODEX_MAX_OUTPUT_TEXT_CHARS") or "") or 200000
local MAX_SSE_LINE_BYTES = tonumber(os.getenv("LCA_CODEX_MAX_SSE_LINE_BYTES") or "") or 262144
local PROMPT_CACHE_KEY_OVERRIDE = os.getenv("LCA_CODEX_PROMPT_CACHE_KEY")
local DEFAULT_SERVICE_TIER = os.getenv("LCA_CODEX_DEFAULT_SERVICE_TIER") or "priority"
local DUMP_REQUEST_DIR = os.getenv("LCA_CODEX_DUMP_REQUEST_DIR")
local LOG_RAW_USAGE = os.getenv("LCA_CODEX_LOG_RAW_USAGE") == "1"
local WEBSOCKET_ENABLED = os.getenv("LCA_CODEX_WEBSOCKET") ~= "0"
	and os.getenv("LCA_CODEX_DISABLE_WEBSOCKET") ~= "1"
local WEBSOCKET_UPGRADE_TIMEOUT_SEC = tonumber(os.getenv("LCA_CODEX_WEBSOCKET_UPGRADE_TIMEOUT") or "") or 5
local WEBSOCKET_HTTP_FALLBACK_FIRST_BYTE_SEC = tonumber(os.getenv("LCA_CODEX_WEBSOCKET_HTTP_FALLBACK_FIRST_BYTE") or "") or 8
local WEBSOCKET_CONNECT_ATTEMPTS = tonumber(os.getenv("LCA_CODEX_WEBSOCKET_CONNECT_ATTEMPTS") or "") or 3
local WEBSOCKET_REUSE = os.getenv("LCA_CODEX_WEBSOCKET_REUSE") ~= "0"

local CLOSE_TOOL_CALL = "</tool_call>"
local CLOSE_TOOL_CALL_LEN = #CLOSE_TOOL_CALL
local RAW_CONTENT_TOOLS = {
	edit = true,
	write = true,
}
local last_prefix_hashes_by_key = {}
local websocket_connections_by_key = {}
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

local function codex_websocket_headers(credentials, request)
	local headers = {
		{ "Authorization", "Bearer " .. credentials.access },
		{ "chatgpt-account-id", credentials.account_id },
		{ "originator", "lca" },
		{ "OpenAI-Beta", "responses_websockets=2026-02-06" },
	}
	local affinity_id = cache_affinity_id(request)
	if affinity_id and affinity_id ~= "" then
		headers[#headers + 1] = { "session-id", affinity_id }
		headers[#headers + 1] = { "thread-id", affinity_id }
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

local function compact_sample(text, max_len)
	text = tostring(text or "")
	text = text:gsub("\r", "\\r"):gsub("\n", "\\n")
	text = text:gsub("[%z\1-\8\11\12\14-\31\127]", "?")
	max_len = max_len or 1200
	if #text > max_len then
		return text:sub(1, max_len) .. "...[" .. tostring(#text) .. " chars]"
	end
	return text
end

local function new_sse_stats()
	return {
		body_chunks = 0,
		body_bytes = 0,
		lines = 0,
		data_lines = 0,
		output_deltas = 0,
		output_delta_bytes = 0,
		usage_events = 0,
		json_type_missing = 0,
		json_payload_errors = 0,
		non_data_lines = 0,
		line_buffer_bytes = 0,
		max_line_bytes = 0,
		event_types = {},
		sample_types = {},
		last_payload_sample = "",
	}
end

local function note_event_type(stats, event_type)
	event_type = tostring(event_type or "(missing)")
	stats.event_types[event_type] = (stats.event_types[event_type] or 0) + 1
	if #stats.sample_types < 8 then
		for _, seen in ipairs(stats.sample_types) do
			if seen == event_type then
				return
			end
		end
		stats.sample_types[#stats.sample_types + 1] = event_type
	end
end

local function format_event_type_counts(stats)
	local pairs_list = {}
	for event_type, count in pairs(stats.event_types or {}) do
		pairs_list[#pairs_list + 1] = { event_type = event_type, count = count }
	end
	table.sort(pairs_list, function(a, b)
		if a.count == b.count then
			return a.event_type < b.event_type
		end
		return a.count > b.count
	end)
	local limit = math.min(#pairs_list, 10)
	local parts = {}
	for i = 1, limit do
		parts[#parts + 1] = pairs_list[i].event_type .. "=" .. tostring(pairs_list[i].count)
	end
	if #pairs_list > limit then
		parts[#parts + 1] = "+" .. tostring(#pairs_list - limit) .. " more"
	end
	return #parts > 0 and table.concat(parts, ",") or "(none)"
end

local function process_event_payload(payload, on_delta, on_usage, stats)
	stats.last_payload_sample = compact_sample(payload, 500)
	local event_type = json.field(payload, "type")
	if event_type then
		note_event_type(stats, event_type)
	else
		stats.json_type_missing = stats.json_type_missing + 1
		local ok = pcall(json.decode, payload)
		if not ok then
			stats.json_payload_errors = stats.json_payload_errors + 1
		end
		note_event_type(stats, "(missing)")
	end
	if on_usage then
		local usage = usage_from_payload(payload)
		if usage then
			stats.usage_events = stats.usage_events + 1
			on_usage(usage)
		end
	end
	if event_type == "response.output_text.delta" then
		local delta = json.field(payload, "delta")
		if delta and delta ~= "" then
			stats.output_deltas = stats.output_deltas + 1
			stats.output_delta_bytes = stats.output_delta_bytes + #delta
			if on_delta(delta) == false then
				return false
			end
		end
	end
	return event_type
end

local function sse_parser(on_delta, on_usage, on_abort, stats)
	local line_buffer = ""
	stats = stats or new_sse_stats()
	return function(chunk)
		stats.body_chunks = stats.body_chunks + 1
		stats.body_bytes = stats.body_bytes + #chunk
		line_buffer = line_buffer .. chunk
		stats.line_buffer_bytes = #line_buffer
		if #line_buffer > MAX_SSE_LINE_BYTES then
			if on_abort then
				on_abort("sse_line_too_large", #line_buffer)
			end
			return false
		end
		while true do
			local pos = line_buffer:find("\n", 1, true)
			if not pos then
				stats.line_buffer_bytes = #line_buffer
				return
			end
			local line = line_buffer:sub(1, pos - 1):gsub("\r$", "")
			line_buffer = line_buffer:sub(pos + 1)
			stats.lines = stats.lines + 1
			stats.max_line_bytes = math.max(stats.max_line_bytes, #line)
				local payload = line:match("^data:%s*(.+)$")
				if payload then
					stats.data_lines = stats.data_lines + 1
					local processed = process_event_payload(payload, on_delta, on_usage, stats)
					if processed == false then
						return false
					end
				elseif line ~= "" then
					stats.non_data_lines = stats.non_data_lines + 1
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

local function transport_diagnostics_summary(diag)
	if not diag then
		return "(none)"
	end
	local function seconds(value)
		return value and string.format("%.3f", tonumber(value) or 0) or "unknown"
	end
	return string.format(
		"elapsed=%s since_last_progress=%s first_byte=%s deadline=%s wait_phase=%s wait_mode=%s read_buffer=%d body_chunks=%d last_body_chunk_bytes=%d last_body_chunk_age=%s http_chunk_index=%d last_http_chunk_size=%d transfer=%s content_length_remaining=%s",
		seconds(diag.elapsed),
		seconds(diag.since_last_progress),
		tostring(diag.first_byte_seen == true),
		tostring(diag.wait_deadline_kind or "unknown"),
		tostring(diag.wait_phase or "unknown"),
		tostring(diag.wait_mode or "unknown"),
		tonumber(diag.read_buffer_bytes) or 0,
		tonumber(diag.body_chunks) or 0,
		tonumber(diag.last_body_chunk_bytes) or 0,
		seconds(diag.last_body_chunk_at),
		tonumber(diag.http_chunk_index) or 0,
		tonumber(diag.last_http_chunk_size) or 0,
		tostring(diag.transfer_encoding or "unknown"),
		tostring(diag.content_length_remaining or "unknown")
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

local function complete_tool_calls_prefix(text)
	text = tostring(text or "")
	local parts = {}
	local search_from = 1

	while true do
		local tag_start, tag_end, name = text:find('<tool_call%s+name="([^"]+)"%s*>', search_from)
		if not tag_start then
			break
		end
		local close = nil
		if RAW_CONTENT_TOOLS[name] then
			local next_open = text:find("<tool_call%s+name", tag_end + 1)
			local boundary = next_open or (#text + 1)
			local close_search_from = tag_end + 1
			while true do
				local candidate = text:find(CLOSE_TOOL_CALL, close_search_from, true)
				if not candidate or candidate >= boundary then
					break
				end
				local suffix = text:sub(candidate + CLOSE_TOOL_CALL_LEN, boundary - 1)
				if suffix:gsub(CLOSE_TOOL_CALL, ""):match("^%s*$") then
					close = candidate
					break
				end
				close_search_from = candidate + CLOSE_TOOL_CALL_LEN
			end
		else
			close = text:find(CLOSE_TOOL_CALL, tag_end + 1, true)
		end
		if not close then
			break
		end
		parts[#parts + 1] = text:sub(tag_start, close + CLOSE_TOOL_CALL_LEN - 1)
		search_from = close + CLOSE_TOOL_CALL_LEN
	end

	return table.concat(parts, "\n")
end

local function valid_complete_tool_calls_text(text)
	local ok, protocol = pcall(require, "agent.tool_protocol")
	if not ok or not protocol.extract_all_tool_calls or not protocol.validate_tool_calls then
		return nil, 0, "tool protocol unavailable"
	end

	local calls = protocol.extract_all_tool_calls(text or "")
	if #calls == 0 then
		return nil, 0, "no complete tool calls"
	end
	local valid, validation_err = protocol.validate_tool_calls(calls)
	if not valid then
		return nil, #calls, validation_err or "invalid tool calls"
	end
	return text, #calls, nil
end

local function salvage_partial_tool_response(chunks, transport_err)
	local partial = table.concat(chunks or {})
	if partial == "" then
		return nil
	end

	local complete = complete_tool_calls_prefix(partial)
	local valid_text, call_count, validation_err = valid_complete_tool_calls_text(complete)
	if not valid_text then
		if complete ~= "" then
			debug_log("[codex] partial tool salvage rejected calls=%d reason=%s chars=%d",
				tonumber(call_count) or 0,
				tostring(validation_err),
				#complete
			)
		end
		return nil
	end

	local trailing_chars = math.max(0, #partial - #valid_text)
	debug_log("[codex] salvaged partial tool response chars=%d->%d calls=%d trailing_chars=%d after %s/%s",
		#partial,
		#valid_text,
		call_count,
		trailing_chars,
		tostring(transport_err and transport_err.kind or "unknown"),
		tostring(transport_err and transport_err.phase or "unknown")
	)
	if transport_err and transport_err.diagnostics then
		debug_log("[codex] partial salvage transport diagnostics %s",
			transport_diagnostics_summary(transport_err.diagnostics)
		)
	end
	return valid_text, call_count
end

local function log_sse_stats(prefix, stats, body_tail)
	if not stats then return end
	debug_log("[codex] stream stats %s chunks=%d body_bytes=%d lines=%d data_lines=%d non_data_lines=%d output_deltas=%d output_delta_bytes=%d usage_events=%d type_missing=%d json_errors=%d line_buffer=%d max_line=%d event_types=\"%s\" sample_types=\"%s\" last_payload=\"%s\" body_tail=\"%s\"",
		prefix or "",
		tonumber(stats.body_chunks) or 0,
		tonumber(stats.body_bytes) or 0,
		tonumber(stats.lines) or 0,
		tonumber(stats.data_lines) or 0,
		tonumber(stats.non_data_lines) or 0,
		tonumber(stats.output_deltas) or 0,
		tonumber(stats.output_delta_bytes) or 0,
		tonumber(stats.usage_events) or 0,
		tonumber(stats.json_type_missing) or 0,
		tonumber(stats.json_payload_errors) or 0,
		tonumber(stats.line_buffer_bytes) or 0,
		tonumber(stats.max_line_bytes) or 0,
		format_event_type_counts(stats),
		table.concat(stats.sample_types or {}, ","),
		compact_sample(stats.last_payload_sample or "", 700),
		compact_sample(body_tail or "", 700)
	)
end

local function websocket_body(body)
	return body:gsub("^{", '{"type":"response.create",', 1)
end

local function websocket_deadlines(request)
	local deadlines = default_deadlines(request)
	deadlines.first_byte = WEBSOCKET_UPGRADE_TIMEOUT_SEC
	return deadlines
end

local function websocket_http_fallback_request(request)
	local fallback = {}
	for key, value in pairs(request) do
		fallback[key] = value
	end
	local deadlines = {}
	for key, value in pairs(request.deadlines or {}) do
		deadlines[key] = value
	end
	if not deadlines.first_byte or deadlines.first_byte > WEBSOCKET_HTTP_FALLBACK_FIRST_BYTE_SEC then
		deadlines.first_byte = WEBSOCKET_HTTP_FALLBACK_FIRST_BYTE_SEC
	end
	fallback.deadlines = deadlines
	return fallback
end

local function websocket_connection_key(request)
	local affinity_id = cache_affinity_id(request) or "no-affinity"
	return table.concat({
		tostring(request.host or CODEX_HOST),
		tostring(request.port or 443),
		tostring(request.path or CODEX_PATH),
		affinity_id,
	}, "|")
end

local function close_websocket_connection(key)
	local conn = websocket_connections_by_key[key]
	websocket_connections_by_key[key] = nil
	if conn and conn.close then
		pcall(function() conn:close() end)
	end
end

local function do_complete_websocket(request, credentials, body, on_token)
	local chunks = {}
	local sse_stats = new_sse_stats()
	local full_stream = ""
	local tool_call_seen = false
	local tool_call_closed = false
	local last_tool_call_end = 0
	local cutoff = false
	local abort_reason = nil
	local usage = nil
	local completed = false

	local function on_delta(delta)
		chunks[#chunks + 1] = delta
		full_stream = full_stream .. delta
		if #full_stream > MAX_OUTPUT_TEXT_CHARS then
			abort_reason = "output_text_too_large"
			debug_log("[codex] websocket stream cutoff reason=%s response_chars=%d threshold=%d",
				abort_reason,
				#full_stream,
				MAX_OUTPUT_TEXT_CHARS
			)
			return false
		end
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
				debug_log("[codex] websocket early tool-call cutoff reason=%s post_tool_chars=%d response_chars=%d threshold=%d",
					tail_kind,
					#after,
					#full_stream,
					POST_TOOL_THRESHOLD
				)
				return false
			end
		end
	end

	local function websocket_options()
		return {
			host = request.host or CODEX_HOST,
			port = request.port or 443,
			path = request.path or CODEX_PATH,
			user_agent = "lca-codex/websocket",
			body = websocket_body(body),
			deadlines = websocket_deadlines(request),
			cancelled = function()
				return request.cancelled and request.cancelled() or cancel_requested()
			end,
			headers = codex_websocket_headers(credentials, request),
		}
	end

	local function on_websocket_text(payload)
				sse_stats.body_chunks = sse_stats.body_chunks + 1
				sse_stats.body_bytes = sse_stats.body_bytes + #payload
				sse_stats.lines = sse_stats.lines + 1
				sse_stats.data_lines = sse_stats.data_lines + 1
				sse_stats.max_line_bytes = math.max(sse_stats.max_line_bytes, #payload)
				local event_type = process_event_payload(payload, on_delta, function(next_usage)
					usage = next_usage
				end, sse_stats)
				if event_type == "response.completed" then
					completed = true
					return false
				end
				if abort_reason or cutoff then
					return false
				end
	end

	local function websocket_request(use_reuse)
		local opts = websocket_options()
		opts.on_text = on_websocket_text
		if not use_reuse then
			return websocket_transport.request(opts)
		end

		local key = websocket_connection_key(request)
		local conn = websocket_connections_by_key[key]
		local reused = conn ~= nil
		if not conn then
			local connect_err
			conn, connect_err = websocket_transport.connect(opts)
			if not conn then
				return nil, connect_err
			end
			websocket_connections_by_key[key] = conn
		end

		local ok, result = pcall(function()
			return conn:request(websocket_body(body), on_websocket_text)
		end)
		if ok then
			if reused then
				result.websocket_reused = true
			end
			return result
		end
		close_websocket_connection(key)
		if type(result) == "table" and result._transport_error then
			result.websocket_reused = reused
			return nil, result
		end
		error(result)
	end

	local result, err
	local connect_attempts = math.max(1, WEBSOCKET_CONNECT_ATTEMPTS)
	for ws_attempt = 1, connect_attempts do
		result, err = websocket_request(WEBSOCKET_REUSE)
		if result then
			err = nil
			break
		end
		local retryable_upgrade_timeout = err
			and err.kind == "timeout"
			and err.phase == "headers"
			and (err.response_bytes or 0) == 0
			and #chunks == 0
		local retryable_stale_reused_socket = err
			and err.websocket_reused
			and #chunks == 0
			and (err.kind == "stream" or err.kind == "write" or err.kind == "timeout")
		if not (retryable_upgrade_timeout or retryable_stale_reused_socket) or ws_attempt >= connect_attempts then
			break
		end
		debug_log("[codex] websocket attempt %d/%d failed: %s/%s %s; retrying",
			ws_attempt,
			connect_attempts,
			tostring(err.kind),
			tostring(err.phase or "unknown"),
			tostring(err.detail)
		)
	end

	if err then
		local salvaged_text, salvaged_calls = salvage_partial_tool_response(chunks, err)
		if salvaged_text then
			return {
				status = err.status or 101,
				text = salvaged_text,
				response_bytes = err.response_bytes or 0,
				body_tail = err.body_tail or "",
				timings = err.timings,
				usage = usage,
				early_cutoff = true,
				partial_salvage = true,
				partial_salvaged_calls = salvaged_calls,
				sse_stats = sse_stats,
				transport = "websocket",
			}
		end
		err.text_chunks = chunks
		err.sse_stats = sse_stats
		return nil, err
	end
	result.sse_stats = sse_stats
	result.text = table.concat(chunks)
	if cutoff or tool_call_seen then
		local canonical = canonical_tool_text(result.text)
		if canonical ~= result.text then
			debug_log("[codex] websocket canonicalized tool response chars=%d->%d",
				#result.text,
				#canonical
			)
			result.text = canonical
		end
	end
	result.usage = usage
	result.early_cutoff = cutoff
	result.abort_reason = abort_reason
	result.transport = "websocket"
	if not completed and not cutoff and not abort_reason then
		result.abort_reason = "websocket_closed_before_completed"
	end
	if result.websocket_reused then
		debug_log("[codex] websocket reused cached connection")
	end
	return result
end

local function do_complete(request, credentials, body, on_token)
	local chunks = {}
	local sse_stats = new_sse_stats()
	local full_stream = ""
	local tool_call_seen = false
	local tool_call_closed = false
	local last_tool_call_end = 0
	local cutoff = false
	local abort_reason = nil
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
			if #full_stream > MAX_OUTPUT_TEXT_CHARS then
				abort_reason = "output_text_too_large"
				debug_log("[codex] stream cutoff reason=%s response_chars=%d threshold=%d",
					abort_reason,
					#full_stream,
					MAX_OUTPUT_TEXT_CHARS
				)
				return false
			end
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
		end, function(reason, size)
			abort_reason = reason
			debug_log("[codex] stream cutoff reason=%s buffered_bytes=%d threshold=%d",
				tostring(reason),
				tonumber(size) or 0,
				MAX_SSE_LINE_BYTES
			)
		end, sse_stats),
	})

	if err then
		local salvaged_text, salvaged_calls = salvage_partial_tool_response(chunks, err)
		if salvaged_text then
			return {
				status = err.status or 200,
				text = salvaged_text,
				response_bytes = err.response_bytes or 0,
				body_tail = err.body_tail or "",
				timings = err.timings,
				usage = usage,
				early_cutoff = true,
				partial_salvage = true,
				partial_salvaged_calls = salvaged_calls,
				sse_stats = sse_stats,
			}
		end
		err.text_chunks = chunks
		err.sse_stats = sse_stats
		return nil, err
	end
	result.sse_stats = sse_stats
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
	result.abort_reason = abort_reason
	result.transport = "http"
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
		local result, err
		if WEBSOCKET_ENABLED then
			debug_log("[codex] attempt %d using websocket transport", attempt + 1)
			result, err = do_complete_websocket(request, credentials, body, on_token)
			if err then
				debug_log("[codex] attempt %d websocket failed; falling back to http: %s/%s %s",
					attempt + 1,
					tostring(err.kind),
					tostring(err.phase or "unknown"),
					tostring(err.detail)
				)
				result, err = do_complete(websocket_http_fallback_request(request), credentials, body, on_token)
				if result then
					result.websocket_fallback = true
				end
			end
		else
			result, err = do_complete(request, credentials, body, on_token)
		end
		if result then
			debug_log("[codex] attempt %d succeeded transport=%s http_status=%s response_chars=%d response_bytes=%d timing=%s",
				attempt + 1,
				tostring(result.transport or "http"),
				tostring(result.status or "unknown"),
				#(result.text or ""),
				result.response_bytes or 0,
				timing_summary(result.timings)
			)
			if result.partial_salvage then
				debug_log("[codex] attempt %d used salvaged partial tool response calls=%d",
					attempt + 1,
					tonumber(result.partial_salvaged_calls) or 0
				)
			end
			if result.sse_stats and ((result.sse_stats.output_deltas or 0) == 0 or LOG_RAW_USAGE) then
				log_sse_stats("success", result.sse_stats, result.body_tail)
			end
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
			elseif result.abort_reason then
				error("Codex stream aborted: " .. tostring(result.abort_reason))
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
					_partial_salvage = result.partial_salvage or nil,
					_partial_salvaged_calls = result.partial_salvaged_calls,
					_transport = result.transport,
					_transport_reused = result.websocket_reused or nil,
					_transport_fallback = result.websocket_fallback or nil,
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
			local body_tail = tostring(err.body_tail or "")
			debug_log("[codex] attempt %d failed: %s response_bytes=%d streamed_text_chunks=%d body_tail_bytes=%d timing=%s transport=%s",
				attempt + 1,
				last_error,
				err.response_bytes or 0,
				#streamed_chunks,
				#body_tail,
				timing_summary(err.timings),
				transport_diagnostics_summary(err.diagnostics)
			)
			log_sse_stats("failure", err.sse_stats, body_tail)

			if err.kind == "cancelled" then
				error("cancelled")
			end

			local retryable_timeout_without_text = err.kind == "timeout"
				and no_streamed_text
			if not retryable_timeout_without_text or attempt >= max_retries then
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
codex._complete_tool_calls_prefix = complete_tool_calls_prefix
codex._salvage_partial_tool_response = salvage_partial_tool_response
codex._post_tool_tail_kind = post_tool_tail_kind
codex._should_cut_after_tool = should_cut_after_tool
codex._default_deadlines = default_deadlines
codex._prompt_cache_key = prompt_cache_key
codex._usage_from_payload = usage_from_payload
codex._headers = codex_headers

return codex
