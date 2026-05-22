local path = {}

local function is_absolute(value)
	return value:sub(1, 1) == "/"
end

function path.resolve(value, cwd)
	if not value or value == "" then
		return cwd
	end
	if value == "~" then
		return os.getenv("HOME") or value
	end
	if value:sub(1, 2) == "~/" then
		return (os.getenv("HOME") or "~") .. value:sub(2)
	end
	if is_absolute(value) then
		return value
	end
	return cwd .. "/" .. value
end

return path
