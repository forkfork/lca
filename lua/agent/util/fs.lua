local fs = {}

function fs.read_file(path)
	local file = assert(io.open(path, "r"))
	local value = file:read("*a")
	file:close()
	return value
end

function fs.write_file(path, value)
	local file, open_err = io.open(path, "w")
	if not file then error("cannot write to " .. path .. ": " .. tostring(open_err), 2) end
	local written, write_err = file:write(value)
	-- Closing flushes buffered writes and can fail even when write succeeded.
	-- Always close, including after a write failure, and preserve the first error.
	local closed, close_err = file:close()
	if not written then error("cannot write to " .. path .. ": " .. tostring(write_err), 2) end
	if not closed then error("cannot close " .. path .. ": " .. tostring(close_err), 2) end
end

return fs
