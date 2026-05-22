local json = require("agent.util.json")
local shell = require("agent.util.shell")
local config = require("agent.config")

local codex = {}

local CODEX_RESPONSES_URL = "https://chatgpt.com/backend-api/codex/responses"

-- Retry configuration
local MAX_RETRIES = 2
local INITIAL_BACKOFF_SEC = 1
local TIMEOUT_SEC = 120

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

local function invalidate_credentials_cache()
	local providers = require("agent.providers")
	if providers._invalidate_cache then
		providers._invalidate_cache()
	end
end

local function input_json(messages)
	-- Merge consecutive same-role messages to avoid API issues
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
	return table.concat({
		"{",
		'"model":' .. json.string(request.model or "gpt-5.4-mini") .. ",",
		'"store":false,',
		'"stream":true,',
		'"max_output_tokens":16384,',
		'"instructions":' .. json.string(request.system_prompt or "You are a helpful assistant.") .. ",",
		'"input":' .. input_json(request.messages or {}) .. ",",
		'"text":{"verbosity":"low"},',
		'"include":["reasoning.encrypted_content"]',
		"}",
	})
end

--- Detect if a response indicates an auth error (401 / token expired)
local function is_auth_error(response_text)
	if not response_text then return false end
	return response_text:find('"error_code"%s*:%s*"token_expired"') ~= nil
		or response_text:find('"code"%s*:%s*"token_expired"') ~= nil
		or response_text:find('"code"%s*:%s*"invalid_api_key"') ~= nil
		or response_text:find("unauthorized") ~= nil
		or response_text:find("Unauthorized") ~= nil
		or response_text:find('"status"%s*:%s*401') ~= nil
end

--- Detect if a response indicates a transient/retryable error (429 or 5xx)
local function is_retryable_error(response_text)
	if not response_text then return false end
	return response_text:find('"status"%s*:%s*429') ~= nil
		or response_text:find("rate_limit") ~= nil
		or response_text:find("Rate limit") ~= nil
		or response_text:find('"status"%s*:%s*5%d%d') ~= nil
		or response_text:find("server_error") ~= nil
		or response_text:find("internal_error") ~= nil
		or response_text:find("overloaded") ~= nil
end

local function do_complete(request, on_token)
	local uv = require("luv")

	local credentials = load_credentials(request.credentials_path or config.default_credentials_path())

	local curl_args = {
		"-sS", "-N",
		"--max-time", tostring(TIMEOUT_SEC),
		"-X", "POST",
		"-H", "Authorization: Bearer " .. credentials.access,
		"-H", "chatgpt-account-id: " .. credentials.account_id,
		"-H", "originator: pi",
		"-H", "OpenAI-Beta: responses=experimental",
		"-H", "accept: text/event-stream",
		"-H", "content-type: application/json",
		"--data", request_body(request),
		CODEX_RESPONSES_URL,
	}

	local stdout_pipe = uv.new_pipe()
	local stderr_pipe = uv.new_pipe()
	local chunks = {}
	local line_buf = ""
	local exit_code = nil
	local process_done = false
	local spawn_err = nil
	local stderr_output = ""

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
		line_buf = line_buf .. data

		while true do
			local newline_pos = line_buf:find("\n")
			if not newline_pos then break end

			local line = line_buf:sub(1, newline_pos - 1)
			line_buf = line_buf:sub(newline_pos + 1)

			local payload = line:match("^data:%s*(.+)$")
			if payload then
				local event_type = json.field(payload, "type")
				if event_type == "response.output_text.delta" then
					local delta = json.field(payload, "delta")
					if delta and delta ~= "" then
						chunks[#chunks + 1] = delta
						if on_token then
							on_token(delta)
						end
					end
				end
			end
		end
	end)

	stderr_pipe:read_start(function(_, data)
		if data then
			stderr_output = stderr_output .. data
		end
	end)

	-- Run event loop until curl completes with timeout
	local socket_ok, socket = pcall(require, "socket")
	local loop_start
	if socket_ok then
		loop_start = socket.gettime()
	else
		loop_start = os.time()
	end
	local keepalive = uv.new_timer()
	keepalive:start(100, 100, function() end)

	while not process_done do
		uv.run("once")
		local elapsed
		if socket_ok then
			elapsed = socket.gettime() - loop_start
		else
			elapsed = os.time() - loop_start
		end
		if elapsed > (TIMEOUT_SEC + 10) then
			if handle and not handle:is_closing() then
				handle:kill("sigterm")
			end
			break
		end
	end

	keepalive:stop()
	keepalive:close()

	-- Ensure the process handle and pipes are fully closed before returning.
	for _ = 1, 100 do
		if (not handle or handle:is_closing()) and
		   stdout_pipe:is_closing() and
		   stderr_pipe:is_closing() then
			break
		end
		uv.run("nowait")
	end

	if spawn_err then
		error("Codex stream read error: " .. tostring(spawn_err))
	end
	if exit_code ~= 0 then
		local full_output = table.concat(chunks) .. stderr_output
		error("Codex curl failed (exit " .. tostring(exit_code) .. "): " .. full_output:sub(1, 500))
	end

	local full_text = table.concat(chunks)

	-- Check for error responses in the streamed data
	if full_text == "" and line_buf ~= "" then
		-- The response might be a non-streaming error JSON
		error("Codex error response: " .. line_buf:sub(1, 500))
	end

	return {
		text = full_text,
		_raw_response = full_text,  -- Expose for error detection
	}
end

function codex.complete(request, on_token)
	local last_error = nil

	for attempt = 0, MAX_RETRIES do
		local ok, result = pcall(do_complete, request, on_token)

		if ok then
			-- Check if the response itself contains an error indicator
			local raw = result._raw_response or result.text
			if is_auth_error(raw) then
				-- Token expired — invalidate cache and retry once
				invalidate_credentials_cache()
				local retry_ok, retry_result = pcall(do_complete, request, on_token)
				if retry_ok then
					retry_result._raw_response = nil
					return retry_result
				end
				error("Codex auth error after credential refresh: " .. tostring(retry_result))
			end
			if is_retryable_error(raw) and attempt < MAX_RETRIES then
				-- Retryable error in response body — wait and retry
				last_error = "Retryable error in response: " .. raw:sub(1, 200)
				local backoff = INITIAL_BACKOFF_SEC * (2 ^ attempt)
				local socket_ok, socket = pcall(require, "socket")
				if socket_ok then
					socket.sleep(backoff)
				else
					os.execute("sleep " .. tostring(backoff))
				end
			else
				result._raw_response = nil
				return result
			end
		else
			last_error = tostring(result)

			-- Auth error — invalidate credentials and retry
			if is_auth_error(last_error) then
				invalidate_credentials_cache()
				-- Fall through to retry
			elseif not is_retryable_error(last_error) and last_error:find("exit") then
				-- Non-retryable hard failure (e.g., curl can't connect at all)
				-- Still retry once in case it's transient
				if attempt >= 1 then
					error(last_error)
				end
			end

			-- Exponential backoff before retry
			if attempt < MAX_RETRIES then
				local backoff = INITIAL_BACKOFF_SEC * (2 ^ attempt)
				local socket_ok, socket = pcall(require, "socket")
				if socket_ok then
					socket.sleep(backoff)
				else
					os.execute("sleep " .. tostring(backoff))
				end
			end
		end
	end

	error("Codex request failed after " .. tostring(MAX_RETRIES + 1) .. " attempts: " .. (last_error or "unknown error"))
end

return codex
