local path = require("agent.util.path")
local shell = require("agent.util.shell")

local grep = {}

local MAX_BYTES = 20000

local function truncate(output)
	if #output <= MAX_BYTES then
		return output, false
	end
	return output:sub(1, MAX_BYTES) .. "\n[truncated at " .. MAX_BYTES .. " bytes]", true
end

function grep.execute(args, context)
	if not args.pattern or args.pattern == "" then
		return {
			is_error = true,
			content = "pattern is required",
			summary = "missing pattern",
		}
	end

	local target = path.resolve(args.path or ".", context.cwd)
	local command = "rg --line-number --color=never " .. shell.quote(args.pattern) .. " " .. shell.quote(target)
	if args.glob and args.glob ~= "" then
		command = "rg --line-number --color=never --glob " .. shell.quote(args.glob) .. " " .. shell.quote(args.pattern) .. " " .. shell.quote(target)
	end
	command = command .. " 2>&1"

	local handle = io.popen(command, "r")
	if not handle then
		return {
			is_error = true,
			content = "failed to start rg",
			summary = "failed",
		}
	end
	local output = handle:read("*a") or ""
	local ok, _, code = handle:close()
	if not ok and code ~= 1 then
		return {
			is_error = true,
			content = output,
			summary = "exit " .. tostring(code or 1),
		}
	end

	local truncated
	output, truncated = truncate(output)
	local count = 0
	for _ in output:gmatch("[^\n]+") do
		count = count + 1
	end
	local summary = tostring(count) .. " matches"
	if truncated then
		summary = summary .. ", truncated"
	end

	return {
		is_error = false,
		content = output ~= "" and output or "(no matches)",
		summary = summary,
	}
end

return grep
