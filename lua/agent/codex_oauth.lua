local json = require("agent.util.json")
local transport = require("agent.net.http_transport")

local oauth = {}

local CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
local TOKEN_HOST = "auth.openai.com"
local TOKEN_PATH = "/oauth/token"

local function url_encode(value)
	return tostring(value):gsub("([^A-Za-z0-9%-_%.~])", function(char)
		return string.format("%%%02X", string.byte(char))
	end)
end

local function form_body(values)
	local fields = {}
	for _, pair in ipairs(values) do
		fields[#fields + 1] = url_encode(pair[1]) .. "=" .. url_encode(pair[2])
	end
	return table.concat(fields, "&")
end

function oauth.refresh(refresh_token)
	if not refresh_token or refresh_token == "" then
		error("Codex credentials do not contain a refresh token; run lca login")
	end
	local body = form_body({
		{ "grant_type", "refresh_token" },
		{ "refresh_token", refresh_token },
		{ "client_id", CLIENT_ID },
	})
	local chunks = {}
	local result, request_err = transport.request({
		host = TOKEN_HOST,
		path = TOKEN_PATH,
		body = body,
		user_agent = "lca-auth/refresh",
		headers = {
			{ "Content-Type", "application/x-www-form-urlencoded" },
			{ "Accept", "application/json" },
		},
		limits = { body_tail_bytes = 16384 },
		on_body_chunk = function(chunk)
			chunks[#chunks + 1] = chunk
		end,
	})
	if not result then
		error("Codex token refresh transport failed: " .. tostring(request_err and request_err.detail or request_err))
	end
	local response_body = table.concat(chunks)
	if result.status < 200 or result.status >= 300 then
		error("Codex token refresh failed (HTTP " .. tostring(result.status) .. "): " .. response_body:sub(1, 500))
	end
	local ok, response = pcall(json.decode, response_body)
	if not ok or type(response) ~= "table" then
		error("Codex token refresh returned invalid JSON")
	end
	if type(response.access_token) ~= "string" or response.access_token == ""
		or type(response.expires_in) ~= "number"
	then
		error("Codex token refresh response is missing access_token or expires_in")
	end
	return {
		access = response.access_token,
		refresh = type(response.refresh_token) == "string" and response.refresh_token ~= ""
			and response.refresh_token or refresh_token,
		expires_in = response.expires_in,
	}
end

return oauth
