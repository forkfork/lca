local uv = require("luv")

local run = {}

local MAX_OUTPUT = 20000
local DEFAULT_TIMEOUT_MS = 120000

local function truncate_output(output)
	if #output <= MAX_OUTPUT then
		return output, false
	end
	return output:sub(1, MAX_OUTPUT) .. "\n[truncated at " .. MAX_OUTPUT .. " bytes]", true
end

local function is_curl_command(command)
	return tostring(command or ""):match("^%s*curl%s") ~= nil
end

local function strip_curl_progress(output)
	output = tostring(output or ""):gsub("\r", "\n")
	local kept = {}
	for line in (output .. "\n"):gmatch("(.-)\n") do
		local is_progress = (line == "" and #kept == 0)
			or line:match("^%s*%% Total%s+%% Received")
			or line:match("^%s*Dload%s+Upload%s+Total%s+Spent")
			or (line:match("^%s*%d+%s+%d+%s+%d+%s+%d+%s+%d+%s+%d+") and line:find("%-%-:%-%-:%-%-"))
		if not is_progress then
			kept[#kept + 1] = line
		end
	end
	local cleaned = table.concat(kept, "\n")
	cleaned = cleaned:gsub("\n\n\n+", "\n\n")
	return cleaned
end

local function broad_git_command_reason(command)
	if command:match("^%s*LCA_ALLOW_BROAD_GIT=1[%s;]") then
		return nil
	end

	local checks = {
		{ "git%s+add%s+%-A[%s;&|)]", "git add -A stages every dirty file" },
		{ "git%s+add%s+%-A$", "git add -A stages every dirty file" },
		{ "git%s+add%s+%-%-all[%s;&|)]", "git add --all stages every dirty file" },
		{ "git%s+add%s+%-%-all$", "git add --all stages every dirty file" },
		{ "git%s+add%s+%-u%s*$", "git add -u stages broad tracked changes" },
		{ "git%s+add%s+%-u%s*[;&|)]", "git add -u stages broad tracked changes" },
		{ "git%s+add%s+%-%-update%s*$", "git add --update stages broad tracked changes" },
		{ "git%s+add%s+%-%-update%s*[;&|)]", "git add --update stages broad tracked changes" },
		{ "git%s+add%s+:/[%s;&|)]", "git add :/ stages the whole repository" },
		{ "git%s+add%s+:/$", "git add :/ stages the whole repository" },
		{ "git%s+commit%s+%-am[%s;&|)]", "git commit -am stages broad tracked changes" },
		{ "git%s+commit%s+%-am$", "git commit -am stages broad tracked changes" },
		{ "git%s+commit%s+%-a%s+%-m", "git commit -a -m stages broad tracked changes" },
		{ "git%s+commit%s+%-%-all[%s;&|)]", "git commit --all stages broad tracked changes" },
		{ "git%s+commit%s+%-%-all$", "git commit --all stages broad tracked changes" },
	}
	for _, check in ipairs(checks) do
		if command:find(check[1]) then
			return check[2]
		end
	end

	local pos = 1
	while true do
		local start_at, end_at = command:find("git%s+add%s+%.", pos)
		if not start_at then
			break
		end
		local next_char = command:sub(end_at + 1, end_at + 1)
		if next_char == "" or next_char:match("[%s;&|)]") then
			return "git add . stages every dirty file under the current directory"
		end
		pos = end_at + 1
	end

	return nil
end

local function kill_process_tree(pid, handle, signal)
	signal = signal or "sigterm"
	if pid then
		os.execute("pkill -" .. (signal == "sigkill" and "KILL" or "TERM") .. " -P " .. tostring(pid) .. " >/dev/null 2>&1")
	end
	if handle and not handle:is_closing() then
		pcall(uv.process_kill, handle, signal)
	end
end

function run.execute(args, context)
	if not args.command or args.command == "" then
		return {
			is_error = true,
			content = "command is required",
			summary = "missing command",
		}
	end

	local git_reason = broad_git_command_reason(args.command)
	if git_reason then
		return {
			is_error = true,
			content = table.concat({
				"BLOCKED: broad git staging is not allowed through run.",
				"",
				git_reason .. ".",
				"Stage explicit reviewed paths instead, then inspect `git diff --cached --stat` before committing.",
				"If the user explicitly asked to stage everything, rerun with LCA_ALLOW_BROAD_GIT=1.",
			}, "\n"),
			summary = "blocked git command",
		}
	end

	local timeout_ms = tonumber(args.timeout) or DEFAULT_TIMEOUT_MS

	-- Drain any pending libuv callbacks from previous operations
	uv.run("nowait")

	local stdout_pipe = uv.new_pipe(false)
	local stderr_pipe = uv.new_pipe(false)
	local chunks = {}
	local exit_code = nil
	local timed_out = false
	local done = false

	local handle, pid = uv.spawn("sh", {
		args = { "-c", args.command },
		cwd = context.cwd,
		stdio = { nil, stdout_pipe, stderr_pipe },
	}, function(code)
		exit_code = code
		done = true
	end)

	if not handle then
		stdout_pipe:close()
		stderr_pipe:close()
		return {
			is_error = true,
			content = "failed to start command: " .. tostring(pid),
			summary = "failed to start",
		}
	end

	stdout_pipe:read_start(function(_, data)
		if data then
			chunks[#chunks + 1] = data
		end
	end)

	stderr_pipe:read_start(function(_, data)
		if data then
			chunks[#chunks + 1] = data
		end
	end)

	local timer = uv.new_timer()
	timer:start(timeout_ms, 0, function()
		if not done then
			timed_out = true
			kill_process_tree(pid, handle, "sigterm")
		end
	end)

	local repl_ok, repl_mod = pcall(require, "agent.repl")
	while not done do
		uv.run("once")
		if repl_ok and repl_mod.cancelled then
			timed_out = true  -- reuse timeout path for cleanup
			kill_process_tree(pid, handle, "sigterm")
			break
		end
	end

	-- Wait for process to fully exit after kill
	if not done then
		for _ = 1, 50 do
			uv.run("nowait")
			if done then break end
		end
		if not done then
			kill_process_tree(pid, handle, "sigkill")
			for _ = 1, 50 do
				uv.run("nowait")
				if done then break end
			end
		end
	end

	timer:stop()
	timer:close()
	stdout_pipe:read_stop()
	stderr_pipe:read_stop()
	stdout_pipe:close()
	stderr_pipe:close()
	handle:close()

	local output = table.concat(chunks)
	if is_curl_command(args.command) then
		output = strip_curl_progress(output)
	end
	local truncated
	output, truncated = truncate_output(output)

	if timed_out then
		local repl2_ok, repl2_mod = pcall(require, "agent.repl")
		if repl2_ok and repl2_mod.cancelled then
			output = output .. "\n[cancelled by user]"
			return {
				is_error = true,
				content = output,
				summary = "cancelled",
			}
		end
		output = output .. "\n[killed: exceeded " .. math.floor(timeout_ms / 1000) .. "s timeout]"
		return {
			is_error = true,
			content = output,
			summary = "timed out after " .. math.floor(timeout_ms / 1000) .. "s",
		}
	end

	local summary = "exit " .. tostring(exit_code or 1)
	if truncated then
		summary = summary .. ", truncated"
	end
	if output == "" then
		output = "(no output)"
	end

	return {
		is_error = (exit_code ~= 0),
		content = output,
		summary = summary,
	}
end

run._strip_curl_progress = strip_curl_progress

return run
