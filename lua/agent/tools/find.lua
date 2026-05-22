local path = require("agent.util.path")
local shell = require("agent.util.shell")

local find_tool = {}

local MAX_BYTES = 20000

local function truncate(output)
	if #output <= MAX_BYTES then
		return output, false
	end
	return output:sub(1, MAX_BYTES) .. "\n[truncated at " .. MAX_BYTES .. " bytes]", true
end

function find_tool.execute(args, context)
	local target = path.resolve(args.path or ".", context.cwd)
	local max_depth = math.floor(tonumber(args.maxDepth) or 3)
	local pattern = args.pattern or ""
	local command = "find " .. shell.quote(target) .. " -maxdepth " .. tostring(max_depth) .. " -type f"
	if pattern ~= "" then
		command = command .. " -name " .. shell.quote(pattern)
	end
	command = command .. " | sort"

	local ok, output = pcall(shell.capture, command)
	if not ok then
		return {
			is_error = true,
			content = tostring(output),
			summary = "failed",
		}
	end

	local truncated
	output, truncated = truncate(output)
	local count = 0
	for _ in output:gmatch("[^\n]+") do
		count = count + 1
	end
	local summary = tostring(count) .. " files"
	if truncated then
		summary = summary .. ", truncated"
	end

	return {
		is_error = false,
		content = output ~= "" and output or "(no files)",
		summary = summary,
	}
end

return find_tool
