#!/usr/bin/env lua

-- Unified login script: dispatches to OpenAI OAuth2 or AWS Bedrock credential setup

local function shell_quote(value)
	return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function trim(value)
	return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function json_string(value)
	local escaped = tostring(value):gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
	return '"' .. escaped .. '"'
end

local function write_credentials(path, content)
	local file = assert(io.open(path, "w"))
	file:write(content, "\n")
	file:close()
	os.execute("chmod 600 " .. shell_quote(path))
end

local function read_aws_credentials_file(profile)
	profile = profile or "default"
	local home = os.getenv("HOME")
	local f = io.open(home .. "/.aws/credentials", "r")
	if not f then
		return nil, nil, nil
	end

	local access_key, secret_key, session_token
	local in_profile = false
	for line in f:lines() do
		if line:match("^%[" .. profile .. "%]") then
			in_profile = true
		elseif line:match("^%[") then
			if in_profile then break end
			in_profile = false
		elseif in_profile then
			local k, v = line:match("^(%S+)%s*=%s*(.+)$")
			if k == "aws_access_key_id" then access_key = v end
			if k == "aws_secret_access_key" then secret_key = v end
			if k == "aws_session_token" then session_token = v end
		end
	end
	f:close()
	return access_key, secret_key, session_token
end

local function read_aws_region()
	local region = os.getenv("AWS_REGION") or os.getenv("AWS_DEFAULT_REGION")
	if region then return region end

	local home = os.getenv("HOME")
	local f = io.open(home .. "/.aws/config", "r")
	if not f then return "us-west-2" end

	local in_default = false
	for line in f:lines() do
		if line:match("^%[default%]") or line:match("^%[profile default%]") then
			in_default = true
		elseif line:match("^%[") then
			in_default = false
		elseif in_default then
			local v = line:match("^%s*region%s*=%s*(.+)$")
			if v then
				f:close()
				return trim(v)
			end
		end
	end
	f:close()
	return "us-west-2"
end

local function bedrock_login(options)
	local access_key = os.getenv("AWS_ACCESS_KEY_ID")
	local secret_key = os.getenv("AWS_SECRET_ACCESS_KEY")
	local session_token = os.getenv("AWS_SESSION_TOKEN")

	if not access_key or not secret_key then
		access_key, secret_key, session_token = read_aws_credentials_file(options.profile)
	end

	if not access_key or not secret_key then
		error("No AWS credentials found. Set AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY or configure ~/.aws/credentials")
	end

	local region = options.region or read_aws_region()
	local model = options.model or "us.anthropic.claude-opus-4-6-v1"

	local parts = {
		"{",
		'  "provider": "bedrock",',
		'  "region": ' .. json_string(region) .. ",",
		'  "model": ' .. json_string(model) .. ",",
		'  "accessKeyId": ' .. json_string(access_key) .. ",",
		'  "secretAccessKey": ' .. json_string(secret_key),
	}

	if session_token then
		parts[#parts] = parts[#parts] .. ","
		parts[#parts + 1] = '  "sessionToken": ' .. json_string(session_token)
	end

	parts[#parts + 1] = "}"
	return table.concat(parts, "\n")
end

local function openai_login(options)
	local script_dir = arg[0]:match("^(.*)/[^/]+$") or "."
	local auth_script = script_dir .. "/auth.lua"

	local cmd_parts = { "lua", shell_quote(auth_script), "login" }
	if options.out_path then
		cmd_parts[#cmd_parts + 1] = "--out"
		cmd_parts[#cmd_parts + 1] = shell_quote(options.out_path)
	end

	local command = table.concat(cmd_parts, " ")
	local ok = os.execute(command)
	if not ok then
		error("OpenAI login failed")
	end
	return nil
end

local function usage()
	io.stderr:write([[
Usage:
  lua scripts/login.lua bedrock [--region region] [--model model] [--profile profile] [--out path]
  lua scripts/login.lua openai [--out path]

Providers:
  bedrock   Validates AWS credentials and writes a Bedrock credentials file.
            Reads from AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY env vars,
            or from ~/.aws/credentials (default profile).

  openai    Runs the OpenAI OAuth2 PKCE login flow (delegates to auth.lua).

Examples:
  lua scripts/login.lua bedrock --out credentials.json
  lua scripts/login.lua bedrock --region us-east-1 --model us.anthropic.claude-opus-4-6-v1
  lua scripts/login.lua openai --out credentials.json
]])
	os.exit(2)
end

-- Parse arguments
local provider = arg[1]
if not provider or provider == "--help" then
	usage()
end

local options = {}
local index = 2
while index <= #arg do
	if arg[index] == "--out" then
		options.out_path = arg[index + 1]
		index = index + 2
	elseif arg[index] == "--region" then
		options.region = arg[index + 1]
		index = index + 2
	elseif arg[index] == "--model" then
		options.model = arg[index + 1]
		index = index + 2
	elseif arg[index] == "--profile" then
		options.profile = arg[index + 1]
		index = index + 2
	else
		usage()
	end
end

local ok, result = pcall(function()
	if provider == "bedrock" then
		return bedrock_login(options)
	elseif provider == "openai" then
		return openai_login(options)
	end
	usage()
end)

if not ok then
	io.stderr:write("error: " .. tostring(result) .. "\n")
	os.exit(1)
end

if result then
	if options.out_path then
		write_credentials(options.out_path, result)
		print("Credentials written to " .. options.out_path)
	else
		print(result)
	end
end
