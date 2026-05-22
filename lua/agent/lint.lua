local shell = require("agent.util.shell")

local lint = {}

local CHECKERS = {
	lua = { cmd = "luac", args = "-p" },
	py = { cmd = "python3", args = "-m py_compile" },
	js = { cmd = "node", args = "--check" },
	rb = { cmd = "ruby", args = "-c" },
	sh = { cmd = "bash", args = "-n" },
}

local function which(cmd)
	local handle = io.popen("command -v " .. shell.quote(cmd) .. " 2>/dev/null", "r")
	if not handle then return false end
	local result = handle:read("*l")
	handle:close()
	return result and result ~= ""
end

function lint.check(file_path)
	local ext = file_path:match("%.([^%.]+)$")
	if not ext then return nil end

	local checker = CHECKERS[ext]
	if not checker then return nil end
	if not which(checker.cmd) then return nil end

	local command = checker.cmd .. " " .. checker.args .. " " .. shell.quote(file_path) .. " 2>&1"
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

	local checker = CHECKERS[ext]
	if not checker then return nil end
	if not which(checker.cmd) then return nil end

	local tmp = os.tmpname() .. "." .. ext
	local f = io.open(tmp, "w")
	if not f then return nil end
	f:write(content)
	f:close()

	local command = checker.cmd .. " " .. checker.args .. " " .. shell.quote(tmp) .. " 2>&1"
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
