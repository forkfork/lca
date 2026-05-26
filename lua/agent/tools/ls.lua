local path = require("agent.util.path")
local shell = require("agent.util.shell")

local ls = {}

function ls.execute(args, context)
	local target = path.resolve(args.path or ".", context.cwd)
	local command = "ls -1 " .. shell.quote(target) .. " 2>/dev/null"
	local ok, output = pcall(shell.capture, command)
	if not ok then
		local exists_ok, _, exists_code = os.execute("test -e " .. shell.quote(target))
		if not (exists_ok == true or exists_ok == 0 or exists_code == 0) then
			return {
				is_error = false,
				content = target .. " does not exist",
				summary = "missing",
			}
		end
		return {
			is_error = true,
			content = tostring(output),
			summary = "failed",
		}
	end

	local count = 0
	for _ in output:gmatch("[^\n]+") do
		count = count + 1
	end

	return {
		is_error = false,
		content = output ~= "" and output or "(empty directory)",
		summary = tostring(count) .. " entries",
	}
end

return ls
