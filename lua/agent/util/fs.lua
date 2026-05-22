local fs = {}

function fs.read_file(path)
	local file = assert(io.open(path, "r"))
	local value = file:read("*a")
	file:close()
	return value
end

function fs.write_file(path, value)
	local file = assert(io.open(path, "w"))
	file:write(value)
	file:close()
end

return fs
