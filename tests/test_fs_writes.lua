local script_dir = arg[0]:match("^(.*)/[^/]+$") or "."
package.path = script_dir .. "/../lua/?.lua;" .. script_dir .. "/../lua/?/init.lua;" .. package.path
pcall(require, "luarocks.loader")

local fs = require("agent.util.fs")
local session = require("agent.session").create({})
local write = require("agent.tools.write")
local target = os.tmpname()
local operations = {
	fs = function() return pcall(fs.write_file, target, "hello") end,
	session = function() return session:save(target) end,
	tool = function()
		local result = write.execute({ path = target, content = "hello" }, {})
		return not result.is_error, result.content
	end,
}

for name, operation in pairs(operations) do
	for _, failure in ipairs({ "open", "write", "close", "write_and_close" }) do
		local original_open = io.open
		local closed = false
		io.open = function(path, mode)
			if path ~= target or mode ~= "w" then return original_open(path, mode) end
			if failure == "open" then return nil, "injected open failure" end
			return {
				write = function(self)
					if failure == "write" or failure == "write_and_close" then return nil, "injected write failure" end
					return self
				end,
				close = function()
					closed = true
					if failure == "close" or failure == "write_and_close" then return nil, "injected close failure" end
					return true
				end,
			}
		end
		local ran, ok, err = pcall(operation)
		io.open = original_open
		assert(ran, ok)
		assert(not ok, name .. " falsely succeeded on " .. failure)
		local expected = failure == "write_and_close" and "write" or failure
		assert(tostring(err):find("injected " .. expected .. " failure", 1, true), tostring(err))
		assert(closed == (failure ~= "open"), name .. " did not close after " .. failure)
	end
end

-- Real buffered I/O failure, in addition to deterministic injected failures.
local full = io.open("/dev/full", "w")
if full then
	full:close()
	local ok, err = pcall(fs.write_file, "/dev/full", "hello\n")
	assert(not ok and tostring(err):find("/dev/full", 1, true))
	local saved, save_err = session:save("/dev/full")
	assert(not saved and tostring(save_err):find("/dev/full", 1, true))
end

fs.write_file(target, "hello")
assert(fs.read_file(target) == "hello")
assert(session:save(target))
assert(fs.read_file(target):sub(-1) == "\n")
os.remove(target)
print("file, tool and session write failure propagation: PASS")
