local path = require("agent.util.path")
local shell = require("agent.util.shell")

local grep = {}

local MAX_BYTES = 20000
local cached_has_rg

local function truncate(output)
	if #output <= MAX_BYTES then
		return output, false
	end
	return output:sub(1, MAX_BYTES) .. "\n[truncated at " .. MAX_BYTES .. " bytes]", true
end

local function has_rg()
	if cached_has_rg ~= nil then
		return cached_has_rg
	end
	local ok, why, code = os.execute("command -v rg >/dev/null 2>&1")
	cached_has_rg = ok == true or ok == 0 or (why == "exit" and code == 0)
	return cached_has_rg
end

local function grep_command(args, target)
	if has_rg() then
		if args.glob and args.glob ~= "" then
			return "rg --line-number --color=never --glob " .. shell.quote(args.glob) .. " " .. shell.quote(args.pattern) .. " " .. shell.quote(target) .. " 2>&1"
		end
		return "rg --line-number --color=never " .. shell.quote(args.pattern) .. " " .. shell.quote(target) .. " 2>&1"
	end

	local command = "grep -R -n -I"
	if args.glob and args.glob ~= "" then
		command = command .. " --include=" .. shell.quote(args.glob)
	end
	return command .. " -- " .. shell.quote(args.pattern) .. " " .. shell.quote(target) .. " 2>&1"
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
	local command = grep_command(args, target)

	local handle = io.popen(command, "r")
	if not handle then
		return {
			is_error = true,
			content = "failed to start grep",
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
