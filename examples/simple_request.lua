#!/usr/bin/env lua

local function shell_quote(value)
	return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function read_file(path)
	local file = assert(io.open(path, "r"))
	local value = file:read("*a")
	file:close()
	return value
end

local function json_field(body, name)
	return body:match('"' .. name .. '"%s*:%s*"([^"]+)"')
end

local function json_string(value)
	local escaped = tostring(value):gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
	return '"' .. escaped .. '"'
end

local function json_array(strings)
	local values = {}
	for index, value in ipairs(strings) do
		values[index] = json_string(value)
	end
	return "[" .. table.concat(values, ",") .. "]"
end

local function usage()
	io.stderr:write([[
Usage:
  lua examples/simple_request.lua [~/.lca-credentials.json] [prompt] [--model model]

Example:
  lua examples/simple_request.lua ~/.lca-credentials.json "Reply with exactly: oauth works"
]])
	os.exit(2)
end

local credentials_path = arg[1] or ((os.getenv("HOME") or ".") .. "/.lca-credentials.json")
local prompt = arg[2] or "Reply with exactly: oauth works"
local model = "gpt-5.5"

local index = 3
while index <= #arg do
	if arg[index] == "--model" then
		model = arg[index + 1]
		index = index + 2
	else
		usage()
	end
end

local credentials = read_file(credentials_path)
local access = json_field(credentials, "access")
local account_id = json_field(credentials, "accountId")
if not access or not account_id then
	error("credentials file must contain access and accountId fields")
end

local body = table.concat({
	"{",
	'  "model": ' .. json_string(model) .. ",",
	'  "store": false,',
	'  "stream": true,',
	'  "instructions": "You are a helpful assistant.",',
	'  "input": [{',
	'    "role": "user",',
	'    "content": [{ "type": "input_text", "text": ' .. json_string(prompt) .. " }]",
	"  }],",
	'  "text": { "verbosity": "low" },',
	'  "include": ' .. json_array({ "reasoning.encrypted_content" }),
	"}",
}, "\n")

local response_path = os.tmpname()
local command = table.concat({
	"curl -sS -N",
	"-o " .. shell_quote(response_path),
	"-w '%{http_code}'",
	"-X POST",
	"-H " .. shell_quote("Authorization: Bearer " .. access),
	"-H " .. shell_quote("chatgpt-account-id: " .. account_id),
	"-H " .. shell_quote("originator: lca"),
	"-H " .. shell_quote("OpenAI-Beta: responses=experimental"),
	"-H " .. shell_quote("accept: text/event-stream"),
	"-H " .. shell_quote("content-type: application/json"),
	"--data " .. shell_quote(body),
	shell_quote("https://chatgpt.com/backend-api/codex/responses"),
}, " ")

local handle = assert(io.popen(command, "r"))
local status = tonumber(handle:read("*a"))
handle:close()

local response = read_file(response_path)
os.remove(response_path)

if not status or status < 200 or status >= 300 then
	io.stderr:write(response .. "\n")
	error("request failed with HTTP status " .. tostring(status))
end

local printed = false
for data in response:gmatch("\ndata:%s*([^\n]+)") do
	local event_type = data:match('"type"%s*:%s*"([^"]+)"')
	local text = nil
	if event_type == "response.output_text.delta" then
		text = data:match('"delta"%s*:%s*"([^"]*)"')
	end
	if text and text ~= "" then
		text = text:gsub("\\n", "\n"):gsub('\\"', '"'):gsub("\\\\", "\\")
		io.write(text)
		printed = true
	end
end

if printed then
	io.write("\n")
else
	print(response)
end
