#!/usr/bin/env lua

pcall(require, "luarocks.loader")

local socket = require("socket")
local ssl = require("ssl")

local port_env = assert(os.getenv("LCA_FIXTURE_PORT"), "LCA_FIXTURE_PORT is required")
local port = assert(tonumber(port_env), "LCA_FIXTURE_PORT must be numeric")
local cert = assert(os.getenv("LCA_FIXTURE_CERT"), "LCA_FIXTURE_CERT is required")
local key = assert(os.getenv("LCA_FIXTURE_KEY"), "LCA_FIXTURE_KEY is required")
local response_path = assert(os.getenv("LCA_FIXTURE_RESPONSE"), "LCA_FIXTURE_RESPONSE is required")
local delay_first_byte = tonumber(os.getenv("LCA_FIXTURE_DELAY_FIRST_BYTE") or "0")
local delay_after_headers = tonumber(os.getenv("LCA_FIXTURE_DELAY_AFTER_HEADERS") or "0")
local report_request_body = os.getenv("LCA_FIXTURE_REPORT_REQUEST_BODY") == "1"

local file = assert(io.open(response_path, "rb"))
local response = file:read("*a")
file:close()

local server = assert(socket.bind("127.0.0.1", port))
server:settimeout(10)
io.stdout:write("ready\n")
io.stdout:flush()

local client = assert(server:accept())
client:settimeout(10)
local tls = assert(ssl.wrap(client, {
	mode = "server",
	protocol = "any",
	certificate = cert,
	key = key,
	verify = "none",
	options = { "all", "no_sslv2", "no_sslv3", "no_tlsv1" },
}))
assert(tls:dohandshake())

local content_length = 0
while true do
	local line, err = tls:receive("*l")
	if err == "closed" then
		break
	end
	if not line or line == "" then
		break
	end
	local value = line:match("^[Cc]ontent%-[Ll]ength:%s*(%d+)%s*$")
	if value then
		content_length = tonumber(value) or 0
	end
end

local body_bytes = 0
while body_bytes < content_length do
	local want = math.min(8192, content_length - body_bytes)
	local chunk, err, partial = tls:receive(want)
	local data = chunk or partial
	if data and #data > 0 then
		body_bytes = body_bytes + #data
	end
	if err == "closed" then
		break
	end
end

if report_request_body then
	local marker = "{REQUEST_BODY_BYTES}"
	response = response:gsub(marker, tostring(body_bytes), 1)
end

if delay_first_byte > 0 then
	socket.sleep(delay_first_byte)
end

if delay_after_headers > 0 then
	local pos = response:find("\r\n\r\n", 1, true)
	if pos then
		assert(tls:send(response:sub(1, pos + 3)))
		socket.sleep(delay_after_headers)
		assert(tls:send(response:sub(pos + 4)))
	else
		assert(tls:send(response))
	end
else
	assert(tls:send(response))
end

pcall(function() tls:close() end)
pcall(function() server:close() end)
