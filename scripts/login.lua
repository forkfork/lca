#!/usr/bin/env lua

-- Codex-only login wrapper. auth.lua performs OAuth; this script stores the
-- token in LCA's credentials envelope.

local function shell_quote(value)
	return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function default_credentials_path()
	return (os.getenv("HOME") or ".") .. "/.lca-credentials.json"
end

local function read_file(path)
	local file = io.open(path, "r")
	if not file then return nil end
	local content = file:read("*a")
	file:close()
	return content
end

local function write_credentials(path, content)
	local cleaned = content:gsub("^%s+", ""):gsub("%s+$", "")
	local ok, decoded = pcall(require("cjson").decode, cleaned)
	if not ok or type(decoded) ~= "table" then
		return nil, "OpenAI login returned invalid credentials JSON"
	end

	local temp_path = path .. ".login-" .. tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999))
	local file, open_err = io.open(temp_path, "w")
	if not file then return nil, open_err end
	local wrote, write_err = file:write('{\n  "provider": "codex",\n  "providers": {\n    "codex": ')
	-- gsub returns both the new string and a replacement count. Keep the
	-- sanitized string in a local so file:write cannot append that count.
	if wrote then wrote, write_err = file:write(cleaned) end
	if wrote then wrote, write_err = file:write("\n  }\n}\n") end
	local closed, close_err = file:close()
	if not wrote or not closed then
		os.remove(temp_path)
		return nil, write_err or close_err
	end
	local chmod_ok, _, chmod_code = os.execute("chmod 600 " .. shell_quote(temp_path))
	if not (chmod_ok == true or chmod_ok == 0 or chmod_code == 0) then
		os.remove(temp_path)
		return nil, "could not secure temporary credentials file"
	end
	local renamed, rename_err = os.rename(temp_path, path)
	if not renamed then
		os.remove(temp_path)
		return nil, rename_err
	end
	return true
end

local function usage()
	io.stderr:write("usage: lua scripts/login.lua [openai] [--out path]\n")
	os.exit(2)
end

local index = 1
if arg[index] == "openai" or arg[index] == "codex" then index = index + 1 end
local out_path = default_credentials_path()
while index <= #arg do
	if arg[index] == "--out" and arg[index + 1] then
		out_path = arg[index + 1]
		index = index + 2
	elseif arg[index] == "--help" then
		usage()
	else
		usage()
	end
end

local script_dir = arg[0]:match("^(.*)/[^/]+$") or "."
local auth_script = script_dir .. "/auth.lua"
local temp_out = os.tmpname()
local auth_file = io.open(auth_script, "r")
local command
if auth_file then
	auth_file:close()
	command = "lua5.5 " .. shell_quote(auth_script) .. " login --out " .. shell_quote(temp_out)
else
	command = "lca-auth login --out " .. shell_quote(temp_out)
end

local ok, _, code = os.execute(command)
if not (ok == true or ok == 0 or code == 0) then
	os.remove(temp_out)
	io.stderr:write("error: OpenAI login failed\n")
	os.exit(1)
end
local credentials = read_file(temp_out)
os.remove(temp_out)
if not credentials or credentials == "" then
	io.stderr:write("error: OpenAI login did not write credentials\n")
	os.exit(1)
end
local wrote, write_err = write_credentials(out_path, credentials)
if not wrote then
	io.stderr:write("error: " .. tostring(write_err) .. "\n")
	os.exit(1)
end
print("Credentials written to " .. out_path)
