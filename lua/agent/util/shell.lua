local shell = {}

function shell.quote(value)
	return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

function shell.capture(command)
	local handle = assert(io.popen(command, "r"))
	local output = handle:read("*a")
	local ok, _, code = handle:close()
	if not ok then
		error("command failed (" .. tostring(code) .. "): " .. command)
	end
	return output
end

return shell
