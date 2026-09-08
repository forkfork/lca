local shell = require("agent.util.shell")
local json = require("agent.util.json")
local config = require("agent.config")

local login = {}

local function file_exists(path)
	local file = io.open(path, "r")
	if file then
		file:close()
		return true
	end
	return false
end

local function provider_name(path)
	local file = io.open(path, "r")
	if not file then return nil end
	local body = file:read("*a")
	file:close()
	local ok, root = pcall(json.decode, body or "")
	if not ok or type(root) ~= "table" then return nil end
	if root.provider == "bedrock" then
		local selected = type(root.providers) == "table" and root.providers.bedrock or root
		if type(selected) == "table" then
			local has_key = type(selected.apiKey) == "string" and selected.apiKey ~= ""
			local has_aws = type(selected.accessKeyId) == "string" and selected.accessKeyId ~= ""
				and type(selected.secretAccessKey) == "string" and selected.secretAccessKey ~= ""
			local has_isengard = type(selected.isengardAccount) == "string" and selected.isengardAccount ~= ""
			if has_key or has_aws or has_isengard then return "bedrock" end
		end
		return nil
	end
	local selected = type(root.providers) == "table" and (root.providers.codex or root.providers.openai) or root
	if type(selected) == "table" and type(selected.access) == "string" and selected.access ~= ""
		and type(selected.accountId) == "string" and selected.accountId ~= ""
	then
		return "codex"
	end
	return nil
end

local function resolve_existing(credentials_path)
	local default_path = config.default_credentials_path()
	if credentials_path ~= default_path then
		return provider_name(credentials_path) and credentials_path or nil
	end
	if provider_name(default_path) == "codex" then return default_path end
	local bedrock_path = config.bedrock_credentials_path()
	if provider_name(bedrock_path) == "bedrock" then return bedrock_path end
	if provider_name(default_path) == "bedrock" then return default_path end
	return nil
end

local function local_login_script()
	local source = debug.getinfo(1, "S").source:gsub("^@", "")
	local lua_dir = source:match("^(.*)/lua/agent/login%.lua$")
	if lua_dir then
		local path = lua_dir .. "/scripts/login.lua"
		local file = io.open(path, "r")
		if file then
			file:close()
			return path
		end
	end
	return nil
end

local function run_login(credentials_path)
	local login_script = local_login_script()
	local command
	if login_script then
		command = table.concat({
			"lua5.5",
			shell.quote(login_script),
			"openai",
			"--out",
			shell.quote(credentials_path),
		}, " ")
	else
		command = table.concat({
			"lca-login",
			"openai",
			"--out",
			shell.quote(credentials_path),
		}, " ")
	end
	local ok, reason, code = os.execute(command)
	if ok == true or ok == 0 then
		return true
	end
	if type(ok) == "number" and ok == 0 then
		return true
	end
	return nil, reason or code or ok
end

local function confirm_login(credentials_path)
	io.stderr:write("No credentials found at " .. credentials_path .. ".\n")
	io.stderr:write("Press Enter to sign in with Codex / OpenAI OAuth, or q to quit.\n")
	io.stderr:write("> ")
	io.stderr:flush()

	local answer = io.read("*l")
	answer = answer and answer:gsub("^%s+", ""):gsub("%s+$", ""):lower() or ""
	return answer ~= "q" and answer ~= "quit"
end

function login.ensure_credentials(credentials_path)
	local resolved = resolve_existing(credentials_path)
	if resolved then return true, resolved end

	if not confirm_login(credentials_path) then
		return nil, "credentials setup cancelled"
	end

	local ok, err = run_login(credentials_path)
	if not ok then
		return nil, "login failed: " .. tostring(err)
	end
	if not file_exists(credentials_path) then
		return nil, "login did not create " .. credentials_path
	end
	return true, credentials_path
end

login._provider_name = provider_name
login._resolve_existing = resolve_existing

return login
