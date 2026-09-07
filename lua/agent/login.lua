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
	if file_exists(credentials_path) then
		return true
	end

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
	return true
end

return login
