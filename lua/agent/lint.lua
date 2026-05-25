local shell = require("agent.util.shell")

local lint = {}

local CHECKERS = {
	py = { cmd = "python3", args = "-m py_compile" },
	js = { cmd = "node", args = "--check" },
	rb = { cmd = "ruby", args = "-c" },
	sh = { cmd = "bash", args = "-n" },
}

local cached_lua

local function which(cmd)
	local handle = io.popen("command -v " .. shell.quote(cmd) .. " 2>/dev/null", "r")
	if not handle then return false end
	local result = handle:read("*l")
	handle:close()
	return result and result ~= ""
end

local function executable_exists(value)
	if not value or value == "" then return false end
	if value:find("/", 1, true) then
		local file = io.open(value, "r")
		if file then
			file:close()
			return true
		end
		return false
	end
	return which(value)
end

local function lua_can_parse(candidate)
	local probe = "assert(load('local x = 1 ~ 2'))"
	local command = shell.quote(candidate) .. " -e " .. shell.quote(probe) .. " >/dev/null 2>&1"
	local ok, reason, code = os.execute(command)
	return ok == true or ok == 0 or code == 0 or (reason == "exit" and code == 0)
end

local function lua_checker()
	if cached_lua ~= nil then
		return cached_lua
	end

	local candidates = {}
	for _, candidate in ipairs({
		os.getenv("LCA_LUA"),
		os.getenv("LUA"),
		arg and arg[-1] or nil,
	}) do
		if candidate and candidate ~= "" then
			candidates[#candidates + 1] = candidate
		end
	end
	for _, candidate in ipairs({ "lua5.5", "lua5.4", "lua5.3", "lua5.2", "lua5.1", "lua", "luajit" }) do
		candidates[#candidates + 1] = candidate
	end

	local seen = {}
	for _, candidate in ipairs(candidates) do
		if candidate and candidate ~= "" and not seen[candidate] and executable_exists(candidate) then
			seen[candidate] = true
			if lua_can_parse(candidate) then
				cached_lua = candidate
				return cached_lua
			end
		end
	end

	cached_lua = false
	return nil
end

local function checker_command(ext, file_path)
	if ext == "lua" then
		local lua = lua_checker()
		if not lua then return nil end
		return shell.quote(lua) .. " -e " .. shell.quote("assert(loadfile(arg[1]))") .. " " .. shell.quote(file_path) .. " 2>&1"
	end

	local checker = CHECKERS[ext]
	if not checker then return nil end
	if not which(checker.cmd) then return nil end
	return checker.cmd .. " " .. checker.args .. " " .. shell.quote(file_path) .. " 2>&1"
end

function lint.check(file_path)
	local ext = file_path:match("%.([^%.]+)$")
	if not ext then return nil end

	local command = checker_command(ext, file_path)
	if not command then return nil end
	local handle = io.popen(command, "r")
	if not handle then return nil end
	local output = handle:read("*a")
	local _, _, code = handle:close()

	if code == 0 or (output and output:match("^%s*$")) then
		return nil
	end

	return output
end

function lint.check_content(file_path, content)
	local ext = file_path:match("%.([^%.]+)$")
	if not ext then return nil end

	local tmp = os.tmpname() .. "." .. ext
	local f = io.open(tmp, "w")
	if not f then return nil end
	f:write(content)
	f:close()

	local command = checker_command(ext, tmp)
	if not command then
		os.remove(tmp)
		return nil
	end
	local handle = io.popen(command, "r")
	if not handle then
		os.remove(tmp)
		return nil
	end
	local output = handle:read("*a")
	local _, _, code = handle:close()
	os.remove(tmp)

	if code == 0 or (output and output:match("^%s*$")) then
		return nil
	end

	return output
end

return lint
