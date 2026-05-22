#!/usr/bin/env lua

local socket = require("socket")

local CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
local AUTHORIZE_URL = "https://auth.openai.com/oauth/authorize"
local TOKEN_URL = "https://auth.openai.com/oauth/token"
local REDIRECT_URI = "http://localhost:1455/auth/callback"
local SCOPE = "openid profile email offline_access"
local JWT_CLAIM_PATH = "https://api.openai.com/auth"
local CALLBACK_HOST = os.getenv("PI_OAUTH_CALLBACK_HOST") or "127.0.0.1"
local CALLBACK_TIMEOUT_SECONDS = tonumber(os.getenv("PI_OAUTH_CALLBACK_TIMEOUT_SECONDS") or "120")

local function shell_quote(value)
	return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function run_capture(command)
	local handle = assert(io.popen(command, "r"))
	local output = handle:read("*a")
	local ok, _, code = handle:close()
	if not ok then
		error("command failed (" .. tostring(code) .. "): " .. command)
	end
	return output
end

local function trim(value)
	return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function base64url(value)
	return trim(value):gsub("+", "-"):gsub("/", "_"):gsub("=", "")
end

local function random_base64url(bytes)
	return base64url(run_capture("openssl rand -base64 " .. tonumber(bytes)))
end

local function sha256_base64url(value)
	local command = "printf %s " .. shell_quote(value) .. " | openssl dgst -binary -sha256 | openssl base64 -A"
	return base64url(run_capture(command))
end

local function url_encode(value)
	return tostring(value):gsub("([^A-Za-z0-9%-_%.~])", function(char)
		return string.format("%%%02X", string.byte(char))
	end)
end

local function query(params)
	local parts = {}
	for _, pair in ipairs(params) do
		parts[#parts + 1] = url_encode(pair[1]) .. "=" .. url_encode(pair[2])
	end
	return table.concat(parts, "&")
end

local function html_response(title, message)
	return "<!doctype html><html><head><meta charset=\"utf-8\"><title>"
		.. title
		.. "</title></head><body><h1>"
		.. title
		.. "</h1><p>"
		.. message
		.. "</p></body></html>"
end

local function send_response(client, status, body)
	client:send(
		"HTTP/1.1 "
			.. status
			.. "\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: "
			.. #body
			.. "\r\nConnection: close\r\n\r\n"
			.. body
	)
end

local function parse_query(raw)
	local params = {}
	for key, value in raw:gmatch("([^&=?]+)=([^&]*)") do
		value = value:gsub("+", " "):gsub("%%(%x%x)", function(hex)
			return string.char(tonumber(hex, 16))
		end)
		params[key] = value
	end
	return params
end

local function wait_for_callback(expected_state)
	local server = assert(socket.bind(CALLBACK_HOST, 1455))
	server:settimeout(0.2)
	print("Waiting for callback on http://" .. CALLBACK_HOST .. ":1455/auth/callback")
	print("If the browser callback cannot connect, paste the final redirect URL/code after the callback wait expires.")

	local deadline = socket.gettime() + CALLBACK_TIMEOUT_SECONDS
	while true do
		if socket.gettime() >= deadline then
			server:close()
			io.write("Paste the authorization code or full redirect URL: ")
			local input = trim(io.read("*l") or "")
			if input == "" then
				error("missing authorization code")
			end
			return input:match("[?&]code=([^&#]+)") or input:match("^([^#]+)#" .. expected_state .. "$") or input
		end

		local readable = socket.select({ server }, nil, 0.2)
		for _, ready in ipairs(readable) do
			if ready == server then
				local client = server:accept()
				if client then
					client:settimeout(2)
					local request = client:receive("*l") or ""
					while true do
						local line = client:receive("*l")
						if not line or line == "" then
							break
						end
					end

					local path = request:match("^GET%s+([^%s]+)")
					local route, raw_query = (path or ""):match("^([^?]*)%??(.*)$")
					local params = parse_query(raw_query or "")
					if route ~= "/auth/callback" then
						send_response(client, "404 Not Found", html_response("Authentication failed", "Callback route not found."))
					elseif params.state ~= expected_state then
						send_response(client, "400 Bad Request", html_response("Authentication failed", "State mismatch."))
					elseif not params.code or params.code == "" then
						send_response(client, "400 Bad Request", html_response("Authentication failed", "Missing authorization code."))
					else
						send_response(
							client,
							"200 OK",
							html_response("Authentication successful", "OpenAI authentication completed. You can close this window.")
						)
						client:close()
						server:close()
						return params.code
					end
					client:close()
				end
			end
		end
	end
end

local function curl_post(form)
	local body = query(form)
	local response_path = os.tmpname()
	local status_path = os.tmpname()
	local command = table.concat({
		"curl -sS",
		"-o " .. shell_quote(response_path),
		"-w '%{http_code}'",
		"-X POST",
		"-H 'Content-Type: application/x-www-form-urlencoded'",
		"--data " .. shell_quote(body),
		shell_quote(TOKEN_URL),
		"> " .. shell_quote(status_path),
	}, " ")
	os.execute(command)

	local response_file = assert(io.open(response_path, "r"))
	local response = response_file:read("*a")
	response_file:close()
	local status_file = assert(io.open(status_path, "r"))
	local status = tonumber(status_file:read("*a"))
	status_file:close()
	os.remove(response_path)
	os.remove(status_path)

	if not status or status < 200 or status >= 300 then
		error("token request failed (" .. tostring(status) .. "): " .. response)
	end
	return response
end

local function json_string(value)
	local escaped = tostring(value):gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
	return '"' .. escaped .. '"'
end

local function json_field(body, name)
	return body:match('"' .. name .. '"%s*:%s*"([^"]+)"')
end

local function json_number_field(body, name)
	local value = body:match('"' .. name .. '"%s*:%s*([%d%.]+)')
	return value and tonumber(value) or nil
end

local function base64url_decode(value)
	local normalized = value:gsub("-", "+"):gsub("_", "/")
	normalized = normalized .. string.rep("=", (4 - #normalized % 4) % 4)
	local command = "printf %s " .. shell_quote(normalized) .. " | openssl base64 -d -A"
	return run_capture(command)
end

local function account_id_from_access_token(access_token)
	local payload_part = access_token:match("^[^.]+%.([^.]+)%.[^.]+$")
	if not payload_part then
		error("access token is not a JWT")
	end
	local payload = base64url_decode(payload_part)
	local escaped_path = JWT_CLAIM_PATH:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
	local account_id = payload:match('"' .. escaped_path .. '"%s*:%s*{%s*"chatgpt_account_id"%s*:%s*"([^"]+)"')
		or payload:match('"chatgpt_account_id"%s*:%s*"([^"]+)"')
	if not account_id then
		error("failed to extract accountId from token")
	end
	return account_id
end

local function credentials_json(access, refresh, expires)
	local account_id = account_id_from_access_token(access)
	return table.concat({
		"{",
		'  "access": ' .. json_string(access) .. ",",
		'  "refresh": ' .. json_string(refresh) .. ",",
		'  "expires": ' .. tostring(expires) .. ",",
		'  "accountId": ' .. json_string(account_id),
		"}",
	}, "\n")
end

local function write_credentials(path, json)
	local file = assert(io.open(path, "w"))
	file:write(json, "\n")
	file:close()
	os.execute("chmod 600 " .. shell_quote(path))
end

local function exchange_code(code, verifier)
	local response = curl_post({
		{ "grant_type", "authorization_code" },
		{ "client_id", CLIENT_ID },
		{ "code", code },
		{ "code_verifier", verifier },
		{ "redirect_uri", REDIRECT_URI },
	})
	local access = json_field(response, "access_token")
	local refresh = json_field(response, "refresh_token")
	local expires_in = json_number_field(response, "expires_in")
	if not access or not refresh or not expires_in then
		error("token exchange response missing fields: " .. response)
	end
	return credentials_json(access, refresh, math.floor(os.time() * 1000 + expires_in * 1000))
end

local function refresh_token(refresh)
	local response = curl_post({
		{ "grant_type", "refresh_token" },
		{ "refresh_token", refresh },
		{ "client_id", CLIENT_ID },
	})
	local access = json_field(response, "access_token")
	local next_refresh = json_field(response, "refresh_token")
	local expires_in = json_number_field(response, "expires_in")
	if not access or not next_refresh or not expires_in then
		error("token refresh response missing fields: " .. response)
	end
	return credentials_json(access, next_refresh, math.floor(os.time() * 1000 + expires_in * 1000))
end

local function login(originator)
	local verifier = random_base64url(32)
	local challenge = sha256_base64url(verifier)
	local state = run_capture("openssl rand -hex 16"):gsub("%s+", "")
	local url = AUTHORIZE_URL
		.. "?"
		.. query({
			{ "response_type", "code" },
			{ "client_id", CLIENT_ID },
			{ "redirect_uri", REDIRECT_URI },
			{ "scope", SCOPE },
			{ "code_challenge", challenge },
			{ "code_challenge_method", "S256" },
			{ "state", state },
			{ "id_token_add_organizations", "true" },
			{ "codex_cli_simplified_flow", "true" },
			{ "originator", originator or "lca" },
		})

	print("Open this URL:")
	print(url)
	os.execute("(xdg-open " .. shell_quote(url) .. " >/dev/null 2>&1 &) || true")
	local code = wait_for_callback(state)
	return exchange_code(code, verifier)
end

local function usage()
	io.stderr:write([[
Usage:
  lua scripts/auth.lua login [--out path] [--originator value]
  lua scripts/auth.lua refresh <refresh-token> [--out path]

Outputs credentials JSON compatible with the TypeScript OpenAI Codex OAuth shape.
]])
	os.exit(2)
end

local command = arg[1]
if not command then
	usage()
end

local out_path
local originator = "lca"
local positional = {}
local index = 2
while index <= #arg do
	if arg[index] == "--out" then
		out_path = arg[index + 1]
		index = index + 2
	elseif arg[index] == "--originator" then
		originator = arg[index + 1]
		index = index + 2
	else
		positional[#positional + 1] = arg[index]
		index = index + 1
	end
end

local ok, result = pcall(function()
	if command == "login" then
		return login(originator)
	elseif command == "refresh" and positional[1] then
		return refresh_token(positional[1])
	end
	usage()
end)

if not ok then
	io.stderr:write("error: " .. tostring(result) .. "\n")
	os.exit(1)
end

if out_path then
	write_credentials(out_path, result)
end
print(result)
