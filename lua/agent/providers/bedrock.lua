local json = require("agent.util.json")
local config = require("agent.config")
local transport = require("agent.net.http_transport")
local responses = require("agent.providers.codex")
local shell = require("agent.util.shell")
local fs = require("agent.util.fs")

local bedrock = {}

local DEFAULT_MODEL = "global.openai.gpt-5.6-sol"
local DEFAULT_REGION = "us-east-1"
local MAX_RETRIES = 2
local INITIAL_BACKOFF_SEC = 1
local MAX_OUTPUT_TEXT_CHARS = 200000
local http_request = transport.request
local command_capture = shell.capture
local getenv = os.getenv

local function debug_log(fmt, ...)
	local ok, core = pcall(require, "agent.core")
	if ok and core.debug_log then core.debug_log(fmt, ...) end
end

local function configured_credentials(path)
	local body = require("agent.providers").credentials_body(path)
	return {
		api_key = json.field(body, "apiKey"),
		access_key = json.field(body, "accessKeyId"),
		secret_key = json.field(body, "secretAccessKey"),
		session_token = json.field(body, "sessionToken"),
		expires_at = json.field(body, "expiresAt"),
		isengard_account = json.field(body, "isengardAccount"),
		isengard_role = json.field(body, "isengardRole") or "admin",
		region = json.field(body, "region") or DEFAULT_REGION,
		model = json.field(body, "model") or DEFAULT_MODEL,
	}
end

local function credentials_valid(credentials)
	if credentials.api_key and credentials.api_key ~= "" then return true end
	if not credentials.access_key or credentials.access_key == ""
		or not credentials.secret_key or credentials.secret_key == ""
	then
		return false
	end
	if credentials.expires_at and credentials.expires_at ~= "" then
		local normalized = credentials.expires_at:gsub("Z$", "+00:00")
		if normalized <= os.date("!%Y-%m-%dT%H:%M:%S+00:00") then return false end
	end
	return true
end

local function decode_exported_credentials(output, base)
	local object = tostring(output or ""):match("(%b{})")
	if not object then return nil end
	local ok, value = pcall(json.decode, object)
	if not ok or type(value) ~= "table" then return nil end
	local access_key = value.AccessKeyId or value.accessKeyId
	local secret_key = value.SecretAccessKey or value.secretAccessKey
	if not access_key or not secret_key then return nil end
	return {
		access_key = access_key,
		secret_key = secret_key,
		session_token = value.SessionToken or value.sessionToken,
		expires_at = value.Expiration or value.expiresAt,
		region = base.region,
		model = base.model,
		isengard_account = base.isengard_account,
		isengard_role = base.isengard_role,
	}
end

local function capture_credentials(command, base)
	local ok, output = pcall(command_capture, command)
	if not ok then return nil end
	return decode_exported_credentials(output, base)
end

local function persist_credentials(path, credentials)
	local body = fs.read_file(path)
	local ok, root = pcall(json.decode, body or "")
	if not ok or type(root) ~= "table" then return end
	root.providers = type(root.providers) == "table" and root.providers or {}
	local selected = type(root.providers.bedrock) == "table" and root.providers.bedrock or {}
	selected.accessKeyId = credentials.access_key
	selected.secretAccessKey = credentials.secret_key
	selected.sessionToken = credentials.session_token
	selected.expiresAt = credentials.expires_at
	selected.region = credentials.region
	selected.model = credentials.model
	selected.isengardAccount = credentials.isengard_account
	selected.isengardRole = credentials.isengard_role
	root.provider = "bedrock"
	root.providers.bedrock = selected
	local temp = path .. ".refresh-" .. tostring(require("luv").getpid())
	local file = io.open(temp, "w")
	if not file then return end
	local wrote = file:write(json.encode(root) .. "\n")
	local closed = file:close()
	if not wrote or not closed then pcall(os.remove, temp); return end
	require("luv").fs_chmod(temp, tonumber("600", 8))
	if not os.rename(temp, path) then pcall(os.remove, temp); return end
	require("agent.providers")._invalidate_cache()
end

local function load_credentials(path, skip_configured)
	local base = configured_credentials(path)
	if not skip_configured and credentials_valid(base) then return base end
	local from_environment = {
		access_key = getenv("AWS_ACCESS_KEY_ID"),
		secret_key = getenv("AWS_SECRET_ACCESS_KEY"),
		session_token = getenv("AWS_SESSION_TOKEN"),
		region = base.region,
		model = base.model,
		isengard_account = base.isengard_account,
		isengard_role = base.isengard_role,
	}
	if credentials_valid(from_environment) then return from_environment end
	local exported = capture_credentials("aws configure export-credentials --format process 2>/dev/null", base)
	if credentials_valid(exported or {}) then
		persist_credentials(path, exported)
		return exported
	end
	if base.isengard_account and base.isengard_account ~= "" then
		local inner = "aws configure export-credentials --format process; exit"
		local command = "printf '%s\\n' " .. shell.quote(inner)
			.. " | isengardcli assume --role " .. shell.quote(base.isengard_role)
			.. " --region " .. shell.quote(base.region)
			.. " " .. shell.quote(base.isengard_account) .. " 2>/dev/null"
		exported = capture_credentials(command, base)
		if credentials_valid(exported or {}) then
			persist_credentials(path, exported)
			return exported
		end
	end
	error("Bedrock credentials unavailable; configure an API key, AWS credentials, or isengardAccount")
end

local crypto = require("agent.crypto")
local function hex(bytes)
	return (bytes:gsub(".", function(byte) return string.format("%02x", byte:byte()) end))
end

local function sha256_hex(data)
	return hex(crypto.sha256(data))
end

local function signed_headers(host, path, body, credentials, timestamp)
	local amz_date = timestamp or os.date("!%Y%m%dT%H%M%SZ")
	local date_stamp = amz_date:sub(1, 8)
	local names = "content-type;host;x-amz-date"
	local canonical = "content-type:application/json\nhost:" .. host .. "\nx-amz-date:" .. amz_date .. "\n"
	if credentials.session_token and credentials.session_token ~= "" then
		names = names .. ";x-amz-security-token"
		canonical = canonical .. "x-amz-security-token:" .. credentials.session_token .. "\n"
	end
	local canonical_request = table.concat({
		"POST", path, "", canonical, names, sha256_hex(body),
	}, "\n")
	local scope = table.concat({ date_stamp, credentials.region, "bedrock", "aws4_request" }, "/")
	local canonical_hash = sha256_hex(canonical_request)
	local string_to_sign = table.concat({
		"AWS4-HMAC-SHA256", amz_date, scope, canonical_hash,
	}, "\n")
	local date_key = crypto.hmac_sha256("AWS4" .. credentials.secret_key, date_stamp)
	local region_key = crypto.hmac_sha256(date_key, credentials.region)
	local service_key = crypto.hmac_sha256(region_key, "bedrock")
	local signing_key = crypto.hmac_sha256(service_key, "aws4_request")
	local signature = hex(crypto.hmac_sha256(signing_key, string_to_sign))
	local headers = {
		{ "Authorization", string.format(
			"AWS4-HMAC-SHA256 Credential=%s/%s, SignedHeaders=%s, Signature=%s",
			credentials.access_key, scope, names, signature) },
		{ "X-Amz-Date", amz_date },
		{ "Content-Type", "application/json" },
		{ "Accept", "text/event-stream" },
	}
	if credentials.session_token and credentials.session_token ~= "" then
		headers[#headers + 1] = { "X-Amz-Security-Token", credentials.session_token }
	end
	return headers, {
		canonical_hash = canonical_hash,
		signature = signature,
	}
end

function bedrock.validate_model(model)
	if model == "gpt-6-astra" or (type(model) == "string" and model:match("%.openai%.gpt%-6%-astra$")) then
		error("Astra is not supported by Bedrock; select gpt-5.6-sol or use Codex/OpenAI credentials")
	end
	return model
end

local function model_id(requested, credentials)
	local model = requested
	if not model or model == "" then model = credentials.model end
	bedrock.validate_model(model)
	if model == "gpt-5.6-sol" then return "global.openai.gpt-5.6-sol" end
	return model
end

local function request_body(request, credentials)
	if request.tool_scope == "web_only" then
		error("Bedrock Runtime does not provide LCA's server-side web search")
	end
	local parts = {
		"{",
		'"model":' .. json.string(model_id(request.model, credentials)) .. ",",
		'"store":false,',
		'"stream":true,',
		'"instructions":' .. json.string(request.system_prompt or "You are a helpful assistant.") .. ",",
		'"input":' .. responses._input_json(request.messages or {}, request.native_tool_pair_closure ~= false) .. ",",
		'"text":{"verbosity":"low"},',
	}
	if request.tool_scope ~= "none" then
		parts[#parts + 1] = '"tools":' .. json.encode(require("agent.tool_registry").native_tools()) .. ","
		parts[#parts + 1] = '"tool_choice":"auto",'
		parts[#parts + 1] = '"parallel_tool_calls":true,'
	end
	if request.reasoning_effort then
		parts[#parts + 1] = '"reasoning":{"effort":' .. json.string(request.reasoning_effort) .. "},"
	end
	parts[#parts + 1] = '"include":["reasoning.encrypted_content"]'
	parts[#parts + 1] = "}"
	return table.concat(parts)
end

local function sleep(seconds, request)
	local uv = require("luv")
	local deadline = uv.now() + seconds * 1000
	local timer = uv.new_timer()
	timer:start(100, 100, function() end)
	while uv.now() < deadline do
		if request.cancelled and request.cancelled() then
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

local function retryable(status, body)
	return status == 408 or status == 409 or status == 429 or status >= 500
		or tostring(body):find("ThrottlingException", 1, true) ~= nil
end

local function safe_error_body(body)
	body = tostring(body or "")
	body = body:gsub("([xX]%-[aA][mM][zZ]%-[sS]ecurity%-[tT]oken:)[^\\\n]+", "%1<redacted>")
	body = body:gsub("IQoJ[%w%+/%=]+", "<redacted>")
	return body
end

local function complete_once(request, credentials, body, on_token)
	local chunks, output_items = {}, {}
	local usage, abort_reason
	local streamed_bytes = 0
	local stats = responses._new_sse_stats()
	local host = request.host or ("bedrock-runtime." .. credentials.region .. ".amazonaws.com")
	local path = request.path or "/openai/v1/responses"
	local headers
	if credentials.api_key and credentials.api_key ~= "" then
		headers = {
			{ "Authorization", "Bearer " .. credentials.api_key },
			{ "Accept", "text/event-stream" },
			{ "Content-Type", "application/json" },
		}
	else
		headers = signed_headers(host, path, body, credentials)
	end
	local result, err = http_request({
		host = host,
		port = request.port or 443,
		path = path,
		user_agent = "lca-bedrock/lowlevel",
		body = body,
		deadlines = request.deadlines,
		cancelled = request.cancelled,
		on_wait = request.on_wait,
		headers = headers,
		on_body_chunk = responses._sse_parser(function(delta)
			chunks[#chunks + 1] = delta
			streamed_bytes = streamed_bytes + #delta
			if streamed_bytes > MAX_OUTPUT_TEXT_CHARS then
				abort_reason = "output_text_too_large"
				return false
			end
			if on_token then on_token(delta) end
		end, function(next_usage)
			usage = next_usage
		end, function(reason)
			abort_reason = reason
		end, stats, function(item)
			output_items[#output_items + 1] = item
		end, request.on_activity),
	})
	if err then return nil, err end
	result.text = table.concat(chunks)
	result.output_items = output_items
	result.usage = usage
	result.abort_reason = abort_reason
	return result
end

function bedrock.complete(request, on_token)
	if request.native_tool_calling == false then
		error("Bedrock XML tool fallback is unavailable; native tool calling is required")
	end
	request.native_tool_calling = true
	local credentials = load_credentials(request.credentials_path or config.default_credentials_path())
	local body = request_body(request, credentials)
	if request.on_request_body then request.on_request_body(body) end
	local last_error
	local max_retries = request.max_retries
	if max_retries == nil then max_retries = MAX_RETRIES end
	for attempt = 0, max_retries do
		local result, err = complete_once(request, credentials, body, on_token)
		if err then
			if err.kind == "cancelled" then error("cancelled") end
			last_error = string.format("Bedrock transport error (%s/%s): %s",
				tostring(err.kind), tostring(err.phase or "unknown"), tostring(err.detail))
			if attempt >= max_retries or (err.response_bytes or 0) > 0 then error(last_error) end
		elseif result.status >= 400 then
			local tail = tostring(result.body_tail or "")
			last_error = string.format("Bedrock HTTP %d (request_payload_sha256=%s): %s",
				result.status, sha256_hex(body), safe_error_body(tail):sub(1, 4000))
			local auth_error = result.status == 401 or result.status == 403
			if auth_error and attempt < max_retries and result.text == "" and not credentials.api_key then
				credentials = load_credentials(request.credentials_path or config.default_credentials_path(), true)
			elseif not retryable(result.status, tail) or attempt >= max_retries or result.text ~= "" then
				error(last_error)
			end
		elseif result.abort_reason then
			error("Bedrock stream aborted: " .. tostring(result.abort_reason))
		else
			local native_calls, parse_error = responses._native_tool_calls(result.output_items)
			if parse_error then error("Bedrock native tool call error: " .. tostring(parse_error)) end
			debug_log("[bedrock] model=%s input=%s output=%s cached=%s",
				tostring(model_id(request.model, credentials)),
				tostring(result.usage and result.usage.prompt_tokens or "unknown"),
				tostring(result.usage and result.usage.output_tokens or "unknown"),
				tostring(result.usage and result.usage.cached_tokens or "unknown"))
			return {
				text = responses._materialize_citations(result.text, result.output_items),
				_output_items = result.output_items,
				_native_tool_calls = request.native_tool_calling and native_calls or nil,
				_usage = result.usage,
				_usage_status = result.usage and "available" or "missing_usage_event",
				_http_status = result.status,
				_timings = result.timings,
				_response_bytes = result.response_bytes,
				_transport = "http",
			}
		end
		if not sleep(INITIAL_BACKOFF_SEC * (2 ^ attempt), request) then error("cancelled") end
	end
	error(last_error or "Bedrock request failed")
end

bedrock._request_body = request_body
bedrock._signed_headers = signed_headers
bedrock._load_credentials = load_credentials
bedrock._set_http_request = function(fn) http_request = fn or transport.request end
bedrock._set_command_capture = function(fn) command_capture = fn or shell.capture end
bedrock._set_getenv = function(fn) getenv = fn or os.getenv end

return bedrock
