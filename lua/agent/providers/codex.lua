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
	local reasoning_effort = request.reasoning_effort
	local parts = {
		"{",
		'"model":' .. json.string(request.model or "gpt-5.5") .. ",",
		'"store":false,',
		'"stream":true,',
		'"instructions":' .. json.string(request.system_prompt or "You are a helpful assistant.") .. ",",
		'"input":' .. input_json(request.messages or {}) .. ",",
		'"text":{"verbosity":"low"},',
	}
	if request.service_tier then
		parts[#parts + 1] = '"service_tier":' .. json.string(request.service_tier) .. ","
	end
	if reasoning_effort then
		parts[#parts + 1] = '"reasoning":{"effort":' .. json.string(reasoning_effort) .. "},"
	end
	parts[#parts + 1] = '"include":["reasoning.encrypted_content"]'
	parts[#parts + 1] = "}"
	return table.concat(parts)
end

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

local function append_tail(tail, data, limit)
	tail = (tail or "") .. (data or "")
	if #tail > limit then
		tail = tail:sub(#tail - limit + 1)
	end
	return tail
end

local function strip_status_marker(text)
	return (text or ""):gsub("\n?__LCA_HTTP_STATUS__:%d%d%d%s*$", "")
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
		service_tier = request.service_tier or "(default)",
		message_count = #messages,
		role_counts = table.concat(roles, ","),
		total_message_chars = total_message_chars,
		longest_message_chars = longest_message_chars,
		system_prompt_chars = #(request.system_prompt or ""),
		body_bytes = #body,
	}
end

local function log_request_summary(prefix, summary)
	debug_log(
		"%s model=%s reasoning=%s service_tier=%s messages=%d roles=%s message_chars=%d longest_message=%d system_prompt_chars=%d body_bytes=%d",
		prefix,
		tostring(summary.model),
		tostring(summary.reasoning_effort),
		tostring(summary.service_tier),
		summary.message_count,
		summary.role_counts ~= "" and summary.role_counts or "(none)",
		summary.total_message_chars,
		summary.longest_message_chars,
		summary.system_prompt_chars,
		summary.body_bytes
	)
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
	local body = request_body(request)

	local curl_args = {
		"-sS", "-N",
		"--max-time", tostring(TIMEOUT_SEC),
		"-X", "POST",
		"-H", "Authorization: Bearer " .. credentials.access,
		"-H", "chatgpt-account-id: " .. credentials.account_id,
		"-H", "originator: lca",
		"-H", "OpenAI-Beta: responses=experimental",
		"-H", "accept: text/event-stream",
		"-H", "content-type: application/json",
		"--data-binary", "@-",
		"-w", "\n__LCA_HTTP_STATUS__:%{http_code}\n",
		CODEX_RESPONSES_URL,
	}
	local summary = request_summary(request, body)

	local stdin_pipe = uv.new_pipe()
	local stdout_pipe = uv.new_pipe()
	local stderr_pipe = uv.new_pipe()
	local chunks = {}
	local line_buf = ""
	local stdout_tail = ""
	local stdout_bytes = 0
	local exit_code = nil
	local http_status = nil
	local process_done = false
	local spawn_err = nil
	local stderr_output = ""

	local handle
	local spawn_detail
	handle, spawn_detail = uv.spawn("curl", {
		args = curl_args,
		stdio = { stdin_pipe, stdout_pipe, stderr_pipe },
	}, function(code)
		exit_code = code
		process_done = true
		if not stdin_pipe:is_closing() then stdin_pipe:close() end
		if not stdout_pipe:is_closing() then stdout_pipe:close() end
		if not stderr_pipe:is_closing() then stderr_pipe:close() end
		if handle and not handle:is_closing() then handle:close() end
	end)

	if not handle then
		stdin_pipe:close()
		stdout_pipe:close()
		stderr_pipe:close()
		error("failed to spawn curl" .. (spawn_detail and (": " .. tostring(spawn_detail)) or ""))
	end

	stdin_pipe:write(body, function(err)
		if err then
			spawn_err = err
		end
		if not stdin_pipe:is_closing() then
			stdin_pipe:shutdown(function()
				if not stdin_pipe:is_closing() then stdin_pipe:close() end
			end)
		end
	end)

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
		stdout_bytes = stdout_bytes + #data
		stdout_tail = append_tail(stdout_tail, data, 20000)
		line_buf = line_buf .. data

		while true do
			local newline_pos = line_buf:find("\n")
			if not newline_pos then break end

			local line = line_buf:sub(1, newline_pos - 1)
			line_buf = line_buf:sub(newline_pos + 1)

			local status = line:match("^__LCA_HTTP_STATUS__:(%d%d%d)$")
			if status then
				http_status = tonumber(status)
			end

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

	-- Run event loop until curl completes, times out, or the user cancels.
	local socket_ok, socket = pcall(require, "socket")
	local loop_start
	if socket_ok then
		loop_start = socket.gettime()
	else
		loop_start = os.time()
	end
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
		   stdin_pipe:is_closing() and
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
		log_request_summary("[codex] stream read error request", summary)
		error("Codex stream read error: " .. tostring(spawn_err))
	end
	if exit_code ~= 0 then
		local full_output = table.concat(chunks) .. stderr_output
		log_request_summary("[codex] curl failed request", summary)
		debug_log("[codex] curl failed exit=%s http_status=%s stdout_bytes=%d stderr_bytes=%d stderr=%s",
			tostring(exit_code),
			tostring(http_status or "unknown"),
			stdout_bytes,
			#stderr_output,
			stderr_output:sub(1, 1000):gsub("\n", "\\n")
		)
		error("Codex curl failed (exit " .. tostring(exit_code) .. ", http " .. tostring(http_status or "unknown") .. "): " .. full_output:sub(1, 500))
	end

	local full_text = table.concat(chunks)

	-- Check for error responses in the streamed data
	if full_text == "" then
		-- The response might be a non-streaming error JSON.
		local error_body = strip_status_marker((line_buf ~= "" and line_buf or stdout_tail))
		if error_body ~= "" then
			log_request_summary("[codex] error response request", summary)
			debug_log("[codex] error response http_status=%s stdout_bytes=%d stderr_bytes=%d body=%s",
				tostring(http_status or "unknown"),
				stdout_bytes,
				#stderr_output,
				error_body:sub(1, 2000):gsub("\n", "\\n")
			)
			error("Codex error response (http " .. tostring(http_status or "unknown") .. "): " .. error_body:sub(1, 500))
		end
	end

	if http_status and http_status >= 400 then
		local error_body = strip_status_marker(stdout_tail)
		log_request_summary("[codex] HTTP error request", summary)
		debug_log("[codex] HTTP error status=%d stdout_bytes=%d stderr_bytes=%d body=%s",
			http_status,
			stdout_bytes,
			#stderr_output,
			error_body:sub(1, 2000):gsub("\n", "\\n")
		)
		error("Codex HTTP error " .. tostring(http_status) .. ": " .. error_body:sub(1, 500))
	end

	return {
		text = full_text,
		_raw_response = full_text,  -- Expose for error detection
		_http_status = http_status,
	}
end

function codex.complete(request, on_token)
	local last_error = nil
	local body = request_body(request)
	local summary = request_summary(request, body)

	for attempt = 0, MAX_RETRIES do
		log_request_summary("[codex] attempt " .. tostring(attempt + 1) .. "/" .. tostring(MAX_RETRIES + 1), summary)
		local ok, result = pcall(do_complete, request, on_token)

		if ok then
			debug_log("[codex] attempt %d succeeded http_status=%s response_chars=%d",
				attempt + 1,
				tostring(result._http_status or "unknown"),
				#(result.text or "")
			)

			-- Check if the response itself contains an error indicator.
			local raw = result._raw_response or result.text
			if is_auth_error(raw) then
				-- Token expired — invalidate cache and retry once.
				invalidate_credentials_cache()
				debug_log("[codex] auth error detected; invalidated credential cache and retrying once")
				local retry_ok, retry_result = pcall(do_complete, request, on_token)
				if retry_ok then
					retry_result._raw_response = nil
					retry_result._http_status = nil
					return retry_result
				end
				error("Codex auth error after credential refresh: " .. tostring(retry_result))
			end

			if is_retryable_error(raw) and attempt < MAX_RETRIES then
				-- Retryable error in response body — wait and retry.
				last_error = "Retryable error in response: " .. raw:sub(1, 200)
				local backoff = INITIAL_BACKOFF_SEC * (2 ^ attempt)
				debug_log("[codex] retrying after %ds", backoff)
				if not cancellable_sleep(backoff) then
					error("cancelled")
				end
			else
				result._raw_response = nil
				result._http_status = nil
				return result
			end
		else
			last_error = tostring(result)
			debug_log("[codex] attempt %d failed: %s", attempt + 1, last_error:sub(1, 2000):gsub("\n", "\\n"))

			-- Auth error — invalidate credentials and retry.
			if is_auth_error(last_error) then
				invalidate_credentials_cache()
				debug_log("[codex] auth error detected; invalidated credential cache")
				-- Fall through to retry.
			elseif not is_retryable_error(last_error) and last_error:find("exit") then
				-- Non-retryable hard failure (e.g., curl can't connect at all)
				-- Still retry once in case it's transient.
				if attempt >= 1 then
					error(last_error)
				end
			end

			-- Exponential backoff before retry
			if attempt < MAX_RETRIES then
				local backoff = INITIAL_BACKOFF_SEC * (2 ^ attempt)
				debug_log("[codex] retrying after %ds", backoff)
				if not cancellable_sleep(backoff) then
					error("cancelled")
				end
			end
		end
	end

	log_request_summary("[codex] final failure request", summary)
	debug_log("[codex] final failure after %d attempts: %s", MAX_RETRIES + 1, tostring(last_error or "unknown"):sub(1, 2000):gsub("\n", "\\n"))
	error("Codex request failed after " .. tostring(MAX_RETRIES + 1) .. " attempts: " .. (last_error or "unknown error"))
end

return codex
