#!/usr/bin/env lua

-- Unified login script: dispatches to OpenAI OAuth2, AWS Bedrock, or DeepSeek credential setup.
-- Keep this script dependency-free so it can bootstrap credentials before the
-- full LuaRocks runtime path is configured.

local function shell_quote(value)
	return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function trim(value)
	return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function default_credentials_path()
	return (os.getenv("HOME") or ".") .. "/.lca-credentials.json"
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

local function read_file(path)
	local file = io.open(path, "r")
	if not file then
		return nil
	end
	local content = file:read("*a")
	file:close()
	return content
end

local function provider_key(provider)
	if provider == "openai" then
		return "codex"
	end
	return provider
end

local function skip_json_string(text, pos)
	pos = pos + 1
	while pos <= #text do
		local char = text:sub(pos, pos)
		if char == "\\" then
			pos = pos + 2
		elseif char == '"' then
			return pos + 1
		else
			pos = pos + 1
		end
	end
	return nil
end

local function find_matching_brace(text, open_pos)
	local depth = 0
	local pos = open_pos
	while pos <= #text do
		local char = text:sub(pos, pos)
		if char == '"' then
			pos = skip_json_string(text, pos)
			if not pos then return nil end
		elseif char == "{" then
			depth = depth + 1
			pos = pos + 1
		elseif char == "}" then
			depth = depth - 1
			if depth == 0 then
				return pos
			end
			pos = pos + 1
		else
			pos = pos + 1
		end
	end
	return nil
end

local function parse_provider_entries(content)
	local entries = {}
	if not content or content == "" then
		return entries
	end
	local providers_key = content:find('"providers"%s*:')
	if not providers_key then
		return entries
	end
	local object_start = content:find("{", providers_key)
	if not object_start then
		return entries
	end
	local object_end = find_matching_brace(content, object_start)
	if not object_end then
		return entries
	end
	local pos = object_start + 1
	while pos < object_end do
		local key_start, key_end, key = content:find('"%s*([^"]-)%s*"%s*:', pos)
		if not key_start or key_start >= object_end then
			break
		end
		local value_start = content:find("{", key_end + 1)
		if not value_start or value_start >= object_end then
			break
		end
		local value_end = find_matching_brace(content, value_start)
		if not value_end then
			break
		end
		entries[key] = content:sub(value_start, value_end)
		pos = value_end + 1
	end
	return entries
end

local function ensure_provider_field(content, provider)
	content = tostring(content or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if content:find('"provider"%s*:') then
		return content
	end
	local open_pos = content:find("{", 1, true)
	if not open_pos then
		error("new credentials are not valid JSON")
	end
	return content:sub(1, open_pos) .. '\n  "provider": ' .. json_string(provider) .. "," .. content:sub(open_pos + 1)
end

local function indent_json(content, spaces)
	local prefix = string.rep(" ", spaces or 0)
	content = tostring(content or ""):gsub("^%s+", ""):gsub("%s+$", "")
	return prefix .. content:gsub("\n", "\n" .. prefix)
end

local function merge_credentials(existing_content, selected_provider, provider_content)
	local selected = provider_key(selected_provider)
	local providers = parse_provider_entries(existing_content)
	providers[selected] = ensure_provider_field(provider_content, selected)

	local keys = {}
	for key in pairs(providers) do
		keys[#keys + 1] = key
	end
	table.sort(keys)

	local lines = {
		"{",
		'  "provider": ' .. json_string(selected) .. ",",
		'  "providers": {',
	}
	for index, key in ipairs(keys) do
		local suffix = index < #keys and "," or ""
		lines[#lines + 1] = "    " .. json_string(key) .. ": " .. indent_json(providers[key], 4):gsub("^%s+", "") .. suffix
	end
	lines[#lines + 1] = "  }"
	lines[#lines + 1] = "}"
	return table.concat(lines, "\n")
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

local function deepseek_login(options)
	local api_key = options.api_key or os.getenv("DEEPSEEK_API_KEY")
	if not api_key or api_key == "" then
		error("No DeepSeek API key found. Set DEEPSEEK_API_KEY or pass --api-key")
	end

	local model = options.model or "deepseek-v4-pro"
	local base_url = options.base_url or "https://api.deepseek.com"
	return table.concat({
		"{",
		'  "provider": "deepseek",',
		'  "baseUrl": ' .. json_string(base_url) .. ",",
		'  "model": ' .. json_string(model) .. ",",
		'  "apiKey": ' .. json_string(api_key),
		"}",
	}, "\n")
end

local function openai_login(options)
	local script_dir = arg[0]:match("^(.*)/[^/]+$") or "."
	local auth_script = script_dir .. "/auth.lua"
	local temp_out = os.tmpname()

	local auth_file = io.open(auth_script, "r")
	local cmd_parts
	if auth_file then
		auth_file:close()
		cmd_parts = { "lua", shell_quote(auth_script), "login" }
	else
		cmd_parts = { "lca-auth", "login" }
	end
	cmd_parts[#cmd_parts + 1] = "--out"
	cmd_parts[#cmd_parts + 1] = shell_quote(temp_out)

	local command = table.concat(cmd_parts, " ")
	local ok = os.execute(command)
	if not ok then
		os.remove(temp_out)
		error("OpenAI login failed")
	end
	local content = read_file(temp_out)
	os.remove(temp_out)
	if not content or content == "" then
		error("OpenAI login did not write credentials")
	end
	return content
end

local function usage()
	io.stderr:write([[
Usage:
  lua scripts/login.lua bedrock [--region region] [--model model] [--profile profile] [--out path]
  lua scripts/login.lua deepseek [--api-key key] [--model model] [--base-url url] [--out path]
  lua scripts/login.lua openai [--out path]

Providers:
  bedrock   Validates AWS credentials and writes a Bedrock credentials file.
            Reads from AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY env vars,
            or from ~/.aws/credentials (default profile).

  deepseek  Writes a DeepSeek credentials file.
            Reads from DEEPSEEK_API_KEY, or from --api-key.

  openai    Runs the OpenAI OAuth2 PKCE login flow (delegates to auth.lua).

Examples:
  lua scripts/login.lua bedrock
  lua scripts/login.lua bedrock --region us-east-1 --model us.anthropic.claude-opus-4-6-v1
  lua scripts/login.lua deepseek --model deepseek-v4-pro
  lua scripts/login.lua openai

Default output: ~/.lca-credentials.json
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
	elseif arg[index] == "--api-key" then
		options.api_key = arg[index + 1]
		index = index + 2
	elseif arg[index] == "--base-url" then
		options.base_url = arg[index + 1]
		index = index + 2
	else
		usage()
	end
end

local ok, result = pcall(function()
	if provider == "bedrock" then
		return bedrock_login(options)
	elseif provider == "deepseek" then
		return deepseek_login(options)
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
	options.out_path = options.out_path or default_credentials_path()
	local existing = read_file(options.out_path)
	local merged = merge_credentials(existing, provider, result)
	write_credentials(options.out_path, merged)
	print("Credentials written to " .. options.out_path)
end
