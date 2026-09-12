#!/usr/bin/env lua

local script_dir = arg[0]:match("^(.*)/[^/]+$") or "."
local project_dir = script_dir .. "/.."
package.path = project_dir .. "/lua/?.lua;" .. project_dir .. "/lua/?/init.lua;" .. project_dir .. "/lua/?/?.lua;" .. package.path
pcall(require, "luarocks.loader")

local run_tool = require("agent.tools.run")

local passed = 0
local failed = 0

local function green(s) return "\27[32m" .. s .. "\27[0m" end
local function red(s) return "\27[31m" .. s .. "\27[0m" end
local function dim(s) return "\27[2m" .. s .. "\27[0m" end

local function test(name, fn)
	io.write("  " .. name .. " ")
	io.flush()
	local ok, err = pcall(fn)
	if ok then
		passed = passed + 1
		io.write(green("PASS") .. "\n")
	else
		failed = failed + 1
		io.write(red("FAIL") .. " (" .. tostring(err):sub(1, 120) .. ")\n")
	end
end

local function process_exists(pid)
	if not pid or pid == "" then
		return false
	end
	local handle = io.popen("ps -p " .. tostring(pid) .. " -o pid= 2>/dev/null", "r")
	local output = handle:read("*a")
	handle:close()
	return output:match("%S") ~= nil
end

io.write("\n" .. dim("═══ Run Tool Tests ═══") .. "\n\n")

local shell = require("agent.util.shell")

test("local executor preserves combined streams and nonzero exit status", function()
	local result = shell:run("printf stdout; printf stderr >&2; exit 7", { cwd = project_dir })
	assert(result.output:find("stdout", 1, true))
	assert(result.output:find("stderr", 1, true))
	assert(result.code == 7)
	assert(not result.error and not result.timed_out)
	local tool = run_tool.execute({ command = "printf failure >&2; exit 7" }, { cwd = project_dir })
	assert(tool.is_error and tool.content == "failure" and tool.summary == "exit 7")
	local empty = run_tool.execute({ command = "true" }, { cwd = project_dir })
	assert(not empty.is_error and empty.content == "(no output)" and empty.summary == "exit 0")
end)

test("capture keeps stdout-only output and throws on failure", function()
	assert(shell.capture("printf captured") == "captured")
	local result = shell:run("printf captured; printf diagnostic >&2", { inherit_stderr = true })
	assert(result.output == "captured" and result.code == 0)
	local ok, err = pcall(shell.capture, "exit 9")
	assert(not ok and tostring(err):find("command failed (9)", 1, true))
end)

test("local executor respects cwd and reports spawn failure", function()
	assert(shell:run("pwd", { cwd = "/tmp" }).output == "/tmp\n")
	local result = shell:run("true", { cwd = "/this/lca/directory/does/not/exist" })
	assert(result.error and result.code == 127)
end)

test("run accepts a plain fake and keeps formatting and guards", function()
	local calls = 0
	local progress, cancelled = function() end, function() return false end
	local fake = { run = function(_, command, opts)
		calls = calls + 1
		assert(command == "pretend" and opts.cwd == "/remote")
		assert(opts.timeout == 321 and opts.progress == progress and opts.cancelled == cancelled)
		return { output = string.rep("x", 20001), code = 3 }
	end }
	local context = { cwd = "/remote", executor = fake, progress = progress, cancelled = cancelled }
	local result = run_tool.execute({ command = "pretend", timeout = 321 }, context)
	assert(result.is_error and result.summary == "exit 3, truncated")
	assert(result.content == string.rep("x", 20000) .. "\n[truncated at 20000 bytes]")
	assert(run_tool.execute({ command = "git add -A" }, context).summary == "blocked git command")
	assert(calls == 1)
end)

test("fake execution preserves cancellation and launch error formatting", function()
	local fake = { run = function() return { output = "partial", timed_out = true, cancelled = true } end }
	local result = run_tool.execute({ command = "pretend" }, { executor = fake })
	assert(result.summary == "cancelled" and result.content == "partial\n[cancelled by user]")
	fake.run = function() return { output = "", code = 127, error = "unavailable" } end
	result = run_tool.execute({ command = "pretend" }, { executor = fake })
	assert(result.is_error and result.content == "failed to start command: unavailable")
end)

test("discovery tools and batches use a run-only fake", function()
	local calls = {}
	local fake = { run = function(_, command)
		calls[#calls + 1] = command
		if command:find("command -v rg", 1, true) then return { output = "", code = 0 } end
		if command:find("rg ", 1, true) then return { output = "", code = 1 } end
		return { output = "a.lua\nb.lua\n", code = 0 }
	end }
	local context = { cwd = "/remote", executor = fake }
	local registry = require("agent.tool_registry")
	assert(registry.execute("ls", {}, context).summary == "2 entries")
	assert(registry.execute("find", {}, context).summary == "2 files")
	assert(registry.execute("grep", { pattern = "absent" }, context).content == "(no matches)")
	local results = require("agent.parallel").execute_batch({
		{ name = "ls", args = {} }, { name = "find", args = {} },
		{ name = "grep", args = { pattern = "absent" } },
	}, context)
	assert(results[1].summary == "2 entries" and results[2].summary == "2 files")
	assert(results[3].content == "(no matches)")
	assert(#calls == 7, "all commands and one cached capability probe must use the fake")
	local fallback = { run = function(_, command)
		if command:find("command -v rg", 1, true) then return { output = "", code = 1 } end
		assert(command:find("grep -R", 1, true), "capability cache must be per executor")
		return { output = "", code = 1 }
	end }
	assert(registry.execute("grep", { pattern = "absent" }, { cwd = "/remote", executor = fallback }).summary == "0 matches")
end)

test("session stores execution capability without serializing it", function()
	local fake = { run = function() error("unexpected execution") end }
	local session = require("agent.session").create({ executor = fake })
	assert(session.executor == fake and session:serialize().executor == nil)
	assert(require("agent.session").create().executor == shell)
end)

test("timeout kills child process", function()
	local pid_file = "/tmp/lca_run_timeout_child_" .. tostring(os.time()) .. "_" .. tostring(math.random(1000000))
	local result = run_tool.execute({
		command = "sleep 20 & echo $! > " .. pid_file .. "; wait",
		timeout = 200,
	}, { cwd = project_dir })

	if not result.is_error then
		error("expected timeout")
	end
	if result.summary ~= "timed out after 0s" then
		error("unexpected summary: " .. tostring(result.summary))
	end

	os.execute("sleep 0.2")
	local f = io.open(pid_file, "r")
	local child_pid = f and f:read("*l") or nil
	if f then f:close() end
	os.remove(pid_file)
	if process_exists(child_pid) then
		os.execute("kill -KILL " .. tostring(child_pid) .. " >/dev/null 2>&1")
		error("child process survived timeout")
	end
end)

test("long foreground commands emit bounded progress heartbeats", function()
	local heartbeats = {}
	local result = run_tool.execute({
		command = "printf started; sleep 0.25; printf finished",
	}, {
		cwd = project_dir,
		progress_interval_ms = 100,
		progress = function(progress) heartbeats[#heartbeats + 1] = progress end,
	})
	if result.is_error then error("command failed: " .. tostring(result.summary)) end
	if #heartbeats < 1 then error("expected at least one progress heartbeat") end
	if (heartbeats[1].elapsed_ms or 0) < 90 then error("heartbeat elapsed time was not measured") end
	if (heartbeats[1].output_bytes or 0) < 7 then error("heartbeat did not expose output growth") end
end)

test("blocks broad git staging", function()
	local result = run_tool.execute({
		command = "git add -A && git commit -m nope",
	}, { cwd = project_dir })

	if not result.is_error then
		error("expected broad git command to be blocked")
	end
	if result.summary ~= "blocked git command" then
		error("unexpected summary: " .. tostring(result.summary))
	end
	if not result.content:find("Stage explicit reviewed paths", 1, true) then
		error("missing explicit staging guidance")
	end
end)

test("allows explicit git path staging syntax", function()
	local result = run_tool.execute({
		command = "git add lua/agent/tools/run.lua --dry-run",
	}, { cwd = project_dir })

	if result.summary == "blocked git command" then
		error("explicit path staging should not be blocked")
	end
end)

test("allows explicit root-relative git path staging", function()
	local result = run_tool.execute({
		command = "git add :/lua/agent/tools/run.lua --dry-run",
	}, { cwd = project_dir })

	if result.summary == "blocked git command" then
		error("explicit root-relative path staging should not be blocked")
	end
end)

test("requires broad git override at command start", function()
	local result = run_tool.execute({
		command = "echo LCA_ALLOW_BROAD_GIT=1; git add -A",
	}, { cwd = project_dir })

	if result.summary ~= "blocked git command" then
		error("override marker in command body should not bypass guard")
	end
end)

test("allows explicit broad git override", function()
	local result = run_tool.execute({
		command = "LCA_ALLOW_BROAD_GIT=1 git add -A --dry-run",
	}, { cwd = project_dir })

	if result.summary == "blocked git command" then
		error("explicit override should bypass guard")
	end
end)

test("strips curl progress meter", function()
	local cleaned = run_tool._strip_curl_progress(table.concat({
		"  % Total    % Received % Xferd  Average Speed   Time    Time     Time  Current",
		"                                 Dload  Upload   Total   Spent    Left  Speed",
		"\r  0     0    0     0    0     0      0      0 --:--:-- --:--:-- --:--:--     0",
		"\r100    12  100    12    0     0  21015      0 --:--:-- --:--:-- --:--:-- 12000",
		"HTTP/1.0 200 OK",
		"Content-Length: 12",
		"",
		"hello world",
	}, "\n"))

	if cleaned:find("%% Total", 1, true) or cleaned:find("Dload", 1, true) or cleaned:find("%-%-:%-%-:%-%-") then
		error("curl progress was not stripped: " .. cleaned)
	end
	if not cleaned:find("HTTP/1.0 200 OK", 1, true) or not cleaned:find("hello world", 1, true) then
		error("curl response content was lost: " .. cleaned)
	end
end)


io.write("\n" .. dim("─────────────────────────────────────") .. "\n")
io.write(string.format("  %s passed, %s failed\n",
	green(tostring(passed)), failed > 0 and red(tostring(failed)) or tostring(failed)))
io.write("\n")
os.exit(failed > 0 and 1 or 0)
