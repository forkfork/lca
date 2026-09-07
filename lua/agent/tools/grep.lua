local path = require("agent.util.path")
local shell = require("agent.util.shell")
local source_evidence = require("agent.tools.source_evidence")

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
			return "rg --with-filename --line-number --color=never --glob " .. shell.quote(args.glob) .. " -- " .. shell.quote(args.pattern) .. " " .. shell.quote(target) .. " 2>&1"
		end
		return "rg --with-filename --line-number --color=never -- " .. shell.quote(args.pattern) .. " " .. shell.quote(target) .. " 2>&1"
	end

	local command = "grep -R -H -n -I"
	if args.glob and args.glob ~= "" then
		command = command .. " --include=" .. shell.quote(args.glob)
	end
	return command .. " -- " .. shell.quote(args.pattern) .. " " .. shell.quote(target) .. " 2>&1"
end

-- Both direct execution and the asynchronous batch executor use these helpers.
function grep.command(args, context)
	if not args.pattern or args.pattern == "" then return nil end
	return grep_command(args, path.resolve(args.path or ".", context.cwd or "."))
end

function grep.format_result(output, code, context)
	if code ~= 0 and code ~= 1 then
		return {
			is_error = true,
			content = output,
			summary = "exit " .. tostring(code or 1),
		}
	end

	local match_count
	if context.session and context.session.grep_evidence then
		output, match_count = source_evidence.enrich_grep(output:sub(1, MAX_BYTES), context.cwd)
	end
	local truncated
	output, truncated = truncate(output)
	local count = match_count or 0
	if not match_count then
		for _ in output:gmatch("[^\n]+") do count = count + 1 end
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

function grep.execute(args, context)
	local command = grep.command(args, context)
	if not command then
		return { is_error = true, content = "pattern is required", summary = "missing pattern" }
	end
	local handle = io.popen(command, "r")
	if not handle then
		return { is_error = true, content = "failed to start grep", summary = "failed" }
	end
	local output = handle:read("*a") or ""
	local ok, _, code = handle:close()
	return grep.format_result(output, ok and 0 or (code or 2), context)
end

return grep
