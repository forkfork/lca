local json = require("agent.util.json")
local shell = require("agent.util.shell")
local config = require("agent.config")

local bedrock = {}

local function load_credentials(path)
	local providers = require("agent.providers")
	local body = providers.credentials_body(path)
	local region = json.field(body, "region")
	local access_key = json.field(body, "accessKeyId")
	local secret_key = json.field(body, "secretAccessKey")
	local session_token = json.field(body, "sessionToken")
	local model = json.field(body, "model")

	if not access_key or not secret_key then
		error("bedrock credentials must contain accessKeyId and secretAccessKey")
	end

	return {
		region = region or "us-west-2",
		access_key = access_key,
		secret_key = secret_key,
		session_token = session_token,
		model = model or "us.anthropic.claude-opus-4-6-v1",
	}
end

local function invalidate_credentials_cache()
	local providers = require("agent.providers")
	if providers._invalidate_cache then
		providers._invalidate_cache()
	end
end

local MAX_AUTH_RETRIES = 1
local MAX_TRANSIENT_RETRIES = 2
local INITIAL_BACKOFF_SEC = 1

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
local function is_auth_error(response_text)
	if not response_text then return false end
	return response_text:find("ExpiredToken") ~= nil
		or response_text:find("ExpiredTokenException") ~= nil
		or response_text:find("The security token included in the request is expired") ~= nil
		or response_text:find("InvalidSignatureException") ~= nil
		or response_text:find("UnrecognizedClientException") ~= nil
end

--- Detect transient/retryable errors (throttling, 5xx, service unavailable)
local function is_retryable_error(response_text)
	if not response_text then return false end
	return response_text:find("ThrottlingException") ~= nil
		or response_text:find("TooManyRequestsException") ~= nil
		or response_text:find("ServiceUnavailableException") ~= nil
		or response_text:find("InternalServerException") ~= nil
		or response_text:find("ModelTimeoutException") ~= nil
		or response_text:find("ModelStreamErrorException") ~= nil
		or response_text:find("overloaded") ~= nil
		or response_text:find("throttl") ~= nil
end

local function sha256_hex(data)
	local command = "printf %s " .. shell.quote(data) .. " | openssl dgst -sha256 -hex 2>/dev/null"
	local output = shell.capture(command)
	return output:match("=%s*(%x+)") or output:match("^(%x+)")
end

local function hmac_sha256_hex(key_hex, data)
	local command = "printf %s " .. shell.quote(data) .. " | openssl dgst -sha256 -hex -mac HMAC -macopt hexkey:" .. key_hex .. " 2>/dev/null"
	local output = shell.capture(command)
	return output:match("=%s*(%x+)") or output:match("^(%x+)")
end

local function hmac_sha256_raw_key(key, data)
	local command = "printf %s " .. shell.quote(data) .. " | openssl dgst -sha256 -hex -mac HMAC -macopt key:" .. shell.quote(key) .. " 2>/dev/null"
	local output = shell.capture(command)
	return output:match("=%s*(%x+)") or output:match("^(%x+)")
end

local function sign_request(method, uri_path, host, body, creds)
	local now = os.date("!%Y%m%dT%H%M%SZ")
	local date_stamp = os.date("!%Y%m%d")
	local service = "bedrock"
	local region = creds.region

	local payload_hash = sha256_hex(body)

	local signed_headers = "content-type;host;x-amz-date"
	local canonical_headers = "content-type:application/json\nhost:" .. host .. "\nx-amz-date:" .. now .. "\n"

	if creds.session_token then
		signed_headers = "content-type;host;x-amz-date;x-amz-security-token"
		canonical_headers = "content-type:application/json\nhost:" .. host .. "\nx-amz-date:" .. now .. "\nx-amz-security-token:" .. creds.session_token .. "\n"
	end

	local canonical_request = table.concat({
		method,
		uri_path,
		"",
		canonical_headers,
		signed_headers,
		payload_hash,
	}, "\n")

	local credential_scope = date_stamp .. "/" .. region .. "/" .. service .. "/aws4_request"
	local string_to_sign = table.concat({
		"AWS4-HMAC-SHA256",
		now,
		credential_scope,
		sha256_hex(canonical_request),
	}, "\n")

	local k_date = hmac_sha256_raw_key("AWS4" .. creds.secret_key, date_stamp)
	local k_region = hmac_sha256_hex(k_date, region)
	local k_service = hmac_sha256_hex(k_region, service)
	local k_signing = hmac_sha256_hex(k_service, "aws4_request")
	local signature = hmac_sha256_hex(k_signing, string_to_sign)

	local authorization = string.format(
		"AWS4-HMAC-SHA256 Credential=%s/%s, SignedHeaders=%s, Signature=%s",
		creds.access_key, credential_scope, signed_headers, signature
	)

	return authorization, now
end

local function build_request_body(request)
	local messages = {}
	for _, msg in ipairs(request.messages or {}) do
		local prev = messages[#messages]
		if prev and prev.role == msg.role then
			prev.content[#prev.content + 1] = { text = msg.text or "" }
		else
			messages[#messages + 1] = {
				role = msg.role,
				content = { { text = msg.text or "" } },
			}
		end
	end

	local body = {
		messages = messages,
		inferenceConfig = {
			maxTokens = 16384,
			temperature = 0.3,
		},
	}

	if request.system_prompt then
		body.system = { { text = request.system_prompt } }
	end

	return json.encode(body)
end

-- AWS Event Stream binary frame parser (incremental)
local function read_uint32(data, offset)
	local b1, b2, b3, b4 = data:byte(offset, offset + 3)
	return b1 * 0x1000000 + b2 * 0x10000 + b3 * 0x100 + b4
end

local function parse_header(data, offset)
	local name_len = data:byte(offset)
	offset = offset + 1
	local name = data:sub(offset, offset + name_len - 1)
	offset = offset + name_len
	local header_type = data:byte(offset)
	offset = offset + 1

	if header_type == 7 then
		local value_len = data:byte(offset) * 256 + data:byte(offset + 1)
		offset = offset + 2
		local value = data:sub(offset, offset + value_len - 1)
		offset = offset + value_len
		return name, value, offset
	end

	return name, nil, offset
end

local function try_parse_frame(buf)
	if #buf < 12 then
		return nil, nil, buf
	end

	local total_length = read_uint32(buf, 1)
	if #buf < total_length then
		return nil, nil, buf
	end

	local headers_length = read_uint32(buf, 5)
	local headers_start = 13
	local payload_start = headers_start + headers_length
	local payload_length = total_length - headers_length - 16

	local event_type = nil
	local hdr_offset = headers_start
	local hdr_end = headers_start + headers_length
	while hdr_offset < hdr_end do
		local name, value, next_offset = parse_header(buf, hdr_offset)
		if name == ":event-type" then
			event_type = value
		end
		hdr_offset = next_offset
	end

	local payload = ""
	if payload_length > 0 then
		payload = buf:sub(payload_start, payload_start + payload_length - 1)
	end

	local remaining = buf:sub(total_length + 1)
	return event_type, payload, remaining
end

local function is_bedrock_model(model)
	if not model then return false end
	return model:match("^us%.") or model:match("^eu%.") or model:match("^ap%.") or model:match("anthropic") or model:match("amazon") or model:match("meta") or model:match("mistral") or model:match("cohere")
end

local function do_complete(request, on_token)
	local uv = require("luv")

	local creds = load_credentials(request.credentials_path or config.default_credentials_path())
	local model = (request.model and is_bedrock_model(request.model) and request.model) or creds.model
	local host = "bedrock-runtime." .. creds.region .. ".amazonaws.com"
	local uri_path = "/model/" .. model .. "/converse-stream"

	local body = build_request_body(request)
	local authorization, amz_date = sign_request("POST", uri_path, host, body, creds)

	local curl_args = {
		"-sS", "-N",
		"--max-time", "120",
		"-X", "POST",
		"-H", "Content-Type: application/json",
		"-H", "X-Amz-Date: " .. amz_date,
		"-H", "Authorization: " .. authorization,
		"--data", body,
		"https://" .. host .. uri_path,
	}
	if creds.session_token then
		table.insert(curl_args, #curl_args, "-H")
		table.insert(curl_args, #curl_args, "X-Amz-Security-Token: " .. creds.session_token)
	end

	local stdout_pipe = uv.new_pipe()
	local stderr_pipe = uv.new_pipe()
	local chunks = {}
	local buf = ""
	local exit_code = nil
	local process_done = false
	local spawn_err = nil

	local handle
	handle = uv.spawn("curl", {
		args = curl_args,
		stdio = { nil, stdout_pipe, stderr_pipe },
	}, function(code)
		exit_code = code
		process_done = true
		if not stdout_pipe:is_closing() then stdout_pipe:close() end
		if not stderr_pipe:is_closing() then stderr_pipe:close() end
		if handle and not handle:is_closing() then handle:close() end
	end)

	if not handle then
		stdout_pipe:close()
		stderr_pipe:close()
		error("failed to spawn curl")
	end

	local ui_ok, ui_mod = pcall(require, "agent.ui")
	local full_stream = ""
	local tool_call_seen = false
	local tool_call_closed = false
	local last_tool_call_end = 0
	local POST_TOOL_THRESHOLD = 40
	local stream_error = nil

	stdout_pipe:read_start(function(err, data)
		if err then
			spawn_err = err
			stdout_pipe:read_stop()
			return
		end
		if not data then
			stdout_pipe:read_stop()
			return
		end

		if ui_ok then ui_mod.suppress_spinner() end
		buf = buf .. data

		-- Check if response is a non-streaming JSON error (not binary event stream)
		if #buf > 4 and buf:sub(1, 1) == "{" then
			local msg = json.field(buf, "message") or json.field(buf, "Message") or buf:sub(1, 300)
			stream_error = msg
			return
		end

		while true do
			local event_type, payload, remaining = try_parse_frame(buf)
			if not event_type then break end
			buf = remaining

			if event_type == "contentBlockDelta" and payload ~= "" then
				local delta_json = json.field(payload, "delta")
				local text = delta_json and json.field(delta_json, "text")
				if text then
					chunks[#chunks + 1] = text
					full_stream = full_stream .. text
					if on_token then
						on_token(text)
					end

					if not tool_call_seen and full_stream:find("<tool_call") then
						tool_call_seen = true
					end
					if tool_call_seen and not tool_call_closed then
						local close_pos = full_stream:find("</tool_call>")
						if close_pos then
							local search_from = close_pos + 12
							while true do
								local next_close = full_stream:find("</tool_call>", search_from)
								if not next_close then break end
								close_pos = next_close
								search_from = next_close + 12
							end
							local after = full_stream:sub(close_pos + 12)
							if not after:find("<tool_call") then
								tool_call_closed = true
								last_tool_call_end = close_pos + 11
							end
						end
					end
					if tool_call_closed then
						local post_tool_chars = #full_stream - last_tool_call_end
						if post_tool_chars > POST_TOOL_THRESHOLD then
							if handle and not handle:is_closing() then
								handle:kill("sigterm")
							end
							process_done = true
							return
						end
					end
				end
			elseif (event_type == "modelStreamErrorException" or event_type == "internalServerException") and payload ~= "" then
				stream_error = json.field(payload, "message") or json.field(payload, "originalMessage") or payload:sub(1, 300)
			end
		end
	end)

	stderr_pipe:read_start(function(_, _)
	end)

	-- Run event loop until curl completes.
	-- Use a keepalive timer so uv.run("once") never blocks on stale handles
	-- from prior iterations. The timer fires every 100ms ensuring we can
	-- check process_done and the timeout even if no other events fire.
	local socket = require("socket")
	local loop_start = socket.gettime()
	local keepalive = uv.new_timer()
	keepalive:start(100, 100, function() end)

	local cancelled = false
	while not process_done do
		uv.run("once")
		if cancel_requested() then
			cancelled = true
			if handle and not handle:is_closing() then
				handle:kill("sigterm")
			end
			break
		end
		if socket.gettime() - loop_start > 130 then
			if handle and not handle:is_closing() then
				handle:kill("sigterm")
			end
			break
		end
	end

	keepalive:stop()
	keepalive:close()

	-- Ensure the process handle and pipes are fully closed before returning.
	-- This prevents stale handles from accumulating across multiple calls.
	for _ = 1, 100 do
		if (not handle or handle:is_closing()) and
		   stdout_pipe:is_closing() and
		   stderr_pipe:is_closing() then
			break
		end
		uv.run("nowait")
	end

	if cancelled then
		error("cancelled")
	end
	if spawn_err then
		error("Bedrock stream read error: " .. tostring(spawn_err))
	end
	if exit_code ~= 0 and not tool_call_closed then
		error("Bedrock curl failed with exit code " .. tostring(exit_code))
	end

	if stream_error then
		error("Bedrock API error: " .. tostring(stream_error))
	end

	local full_text = table.concat(chunks)
	if full_text == "" then
		error("no text content in stream response — possible input token limit exceeded or empty model response")
	end

	return {
		text = full_text,
	}
end

function bedrock.complete(request, on_token)
	local last_error = nil

	for attempt = 0, MAX_TRANSIENT_RETRIES do
		local ok, result = pcall(do_complete, request, on_token)

		if ok then
			return result
		end

		last_error = tostring(result)

		-- Auth error — invalidate credentials and retry
		if is_auth_error(last_error) then
			invalidate_credentials_cache()
			for _ = 1, MAX_AUTH_RETRIES do
				local retry_ok, retry_result = pcall(do_complete, request, on_token)
				if retry_ok then
					return retry_result
				end
				if not is_auth_error(tostring(retry_result)) then
					-- Different error after credential refresh — fall through to transient retry
					last_error = tostring(retry_result)
					break
				end
				last_error = tostring(retry_result)
			end
			-- If still auth error after retries, give up
			if is_auth_error(last_error) then
				error(last_error)
			end
		end

		-- Retryable transient error — exponential backoff
		if is_retryable_error(last_error) and attempt < MAX_TRANSIENT_RETRIES then
			local backoff = INITIAL_BACKOFF_SEC * (2 ^ attempt)
			if not cancellable_sleep(backoff) then
				error("cancelled")
			end
			-- Continue to next attempt
		elseif attempt < MAX_TRANSIENT_RETRIES and not is_retryable_error(last_error) then
			-- Non-retryable, non-auth error — fail immediately
			error(last_error)
		end
	end

	error("Bedrock request failed after " .. tostring(MAX_TRANSIENT_RETRIES + 1) .. " attempts: " .. (last_error or "unknown error"))
end

return bedrock
