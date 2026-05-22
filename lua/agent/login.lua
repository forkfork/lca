local shell = require("agent.util.shell")

local login = {}

local function file_exists(path)
	local file = io.open(path, "r")
	if file then
		file:close()
		return true
	end
	return false
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

local function run_login(provider, credentials_path)
	local login_script = local_login_script()
	local command
	if login_script then
		command = table.concat({
			"lua",
			shell.quote(login_script),
			shell.quote(provider),
			"--out",
			shell.quote(credentials_path),
		}, " ")
	else
		command = table.concat({
			"lca-login",
			shell.quote(provider),
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

local function prompt_provider(credentials_path)
	io.stderr:write("No credentials found at " .. credentials_path .. ".\n")
	io.stderr:write("Choose a provider:\n")
	io.stderr:write("  1) Codex / OpenAI OAuth\n")
	io.stderr:write("  2) Bedrock / AWS\n")
	io.stderr:write("  q) Quit\n")
	io.stderr:write("> ")
	io.stderr:flush()

	local answer = io.read("*l")
	answer = answer and answer:gsub("^%s+", ""):gsub("%s+$", ""):lower() or ""
	if answer == "1" or answer == "codex" or answer == "openai" then
		return "openai"
	end
	if answer == "2" or answer == "bedrock" or answer == "aws" then
		return "bedrock"
	end
	return nil
end

function login.ensure_credentials(credentials_path)
	if file_exists(credentials_path) then
		return true
	end

	local provider = prompt_provider(credentials_path)
	if not provider then
		return nil, "credentials setup cancelled"
	end

	local ok, err = run_login(provider, credentials_path)
	if not ok then
		return nil, "login failed: " .. tostring(err)
	end
	if not file_exists(credentials_path) then
		return nil, "login did not create " .. credentials_path
	end
	return true
end

return login
