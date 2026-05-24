#!/usr/bin/env lua

local script_dir = arg[0]:match("^(.*)/[^/]+$") or "."
local project_dir = script_dir .. "/.."
package.path = project_dir .. "/lua/?.lua;" .. project_dir .. "/lua/?/init.lua;" .. project_dir .. "/lua/?/?.lua;" .. package.path
pcall(require, "luarocks.loader")

local job_output = require("agent.tools.job_output")
local job_start = require("agent.tools.job_start")
local job_status = require("agent.tools.job_status")
local job_stop = require("agent.tools.job_stop")
local job_wait = require("agent.tools.job_wait")
local commands = require("agent.commands")
local jobs = require("agent.jobs")
local shell = require("agent.util.shell")

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
		io.write(red("FAIL") .. " (" .. tostring(err):sub(1, 160) .. ")\n")
	end
end

local function wait_for(cwd, id, wanted, timeout_s)
	local deadline = os.time() + timeout_s
	while os.time() <= deadline do
		local job = jobs.status(cwd, id)
		if job and job.status == wanted then
			return job
		end
		os.execute("sleep 0.1")
	end
	error("timed out waiting for " .. id .. " to become " .. wanted)
end

local function extract_id(result)
	return result.content:match("started%s+(job_%d+)")
end

local tmp_dir = "/tmp/lca_jobs_test_" .. tostring(os.time()) .. "_" .. tostring(math.random(1000000))
os.execute("rm -rf " .. shell.quote(tmp_dir))
os.execute("mkdir -p " .. shell.quote(tmp_dir))

io.write("\n" .. dim("═══ Job Tool Tests ═══") .. "\n\n")

test("job_start records output and exit status", function()
	local result = job_start.execute({
		command = "printf 'one\\ntwo\\n'; printf 'warn\\n' >&2",
	}, { cwd = tmp_dir })
	if result.is_error then error(result.content) end
	local id = extract_id(result)
	if not id then error("missing job id in result") end

	local job = wait_for(tmp_dir, id, "exited", 5)
	if job.exit_code ~= 0 then
		error("unexpected exit code: " .. tostring(job.exit_code))
	end

	local out = job_output.execute({ id = id, tail = 1 }, { cwd = tmp_dir })
	if out.is_error then error(out.content) end
	if not out.content:find("two", 1, true) then
		error("tail did not include stdout")
	end

	local err = job_output.execute({ id = id, stream = "stderr", search = "warn" }, { cwd = tmp_dir })
	if err.is_error then error(err.content) end
	if not err.content:find("warn", 1, true) then
		error("search did not include stderr match")
	end
end)

test("job_status reports running job", function()
	local result = job_start.execute({
		command = "sleep 30",
	}, { cwd = tmp_dir })
	if result.is_error then error(result.content) end
	local id = extract_id(result)
	wait_for(tmp_dir, id, "running", 5)
	if #jobs.running(tmp_dir) ~= 1 then
		error("running job list did not include active job")
	end

	local status = job_status.execute({ id = id }, { cwd = tmp_dir })
	if status.is_error then error(status.content) end
	if not status.content:find("status: running", 1, true) then
		error("status output did not show running")
	end

	local stopped = job_stop.execute({ id = id }, { cwd = tmp_dir })
	if stopped.is_error then error(stopped.content) end
	if stopped.summary ~= "stopped" then
		error("unexpected stop summary: " .. tostring(stopped.summary))
	end
end)

test("job timeout marks timed_out", function()
	local result = job_start.execute({
		command = "sleep 10",
		timeout = 200,
	}, { cwd = tmp_dir })
	if result.is_error then error(result.content) end
	local id = extract_id(result)
	wait_for(tmp_dir, id, "timed_out", 5)
end)

test("job_wait returns completed job output", function()
	local result = job_start.execute({
		command = "printf 'done\\n'",
	}, { cwd = tmp_dir })
	if result.is_error then error(result.content) end
	local id = extract_id(result)

	local waited = job_wait.execute({ id = id, timeout = 3000, tail = 5 }, { cwd = tmp_dir })
	if waited.is_error then error(waited.content) end
	if waited.summary ~= "exited" then
		error("unexpected wait summary: " .. tostring(waited.summary))
	end
	if not waited.content:find("done", 1, true) then
		error("wait output did not include tail")
	end
end)

test("job slash commands inspect and stop jobs without model", function()
	local result = job_start.execute({
		command = "sleep 30",
	}, { cwd = tmp_dir })
	if result.is_error then error(result.content) end
	local id = extract_id(result)
	wait_for(tmp_dir, id, "running", 5)

	local seen = {}
	local fake_ui = {
		block = function(text) seen[#seen + 1] = text end,
		muted = function(text) seen[#seen + 1] = text end,
		error = function(text) error(text) end,
	}
	local session = { cwd = tmp_dir }

	commands.dispatch("/jobs", session, fake_ui)
	commands.dispatch("/job " .. id, session, fake_ui)
	commands.dispatch("/job-stop " .. id, session, fake_ui)

	local body = table.concat(seen, "\n")
	if not body:find(id, 1, true) then
		error("slash commands did not include job id")
	end
	if not body:find("running", 1, true) then
		error("slash commands did not show running status")
	end
	if not body:find("stopped", 1, true) then
		error("slash commands did not stop job")
	end
end)

test("job slash commands default to single visible job", function()
	local result = job_start.execute({
		command = "printf 'single\\n'; sleep 30",
	}, { cwd = tmp_dir })
	if result.is_error then error(result.content) end
	local id = extract_id(result)
	wait_for(tmp_dir, id, "running", 5)

	local seen = {}
	local fake_ui = {
		block = function(text) seen[#seen + 1] = text end,
		muted = function(text) seen[#seen + 1] = text end,
		error = function(text) error(text) end,
	}
	local session = { cwd = tmp_dir }

	commands.dispatch("/job", session, fake_ui)
	commands.dispatch("/job-output 5", session, fake_ui)
	commands.dispatch("/job-wait 10", session, fake_ui)
	commands.dispatch("/job-stop", session, fake_ui)

	local body = table.concat(seen, "\n")
	if not body:find(id, 1, true) then
		error("default job id was not used")
	end
	if not body:find("single", 1, true) then
		error("default job output was not shown")
	end
	if not body:find("stopped", 1, true) then
		error("default job stop did not run")
	end
end)

test("job slash commands require id when multiple jobs visible", function()
	local first = job_start.execute({ command = "sleep 30" }, { cwd = tmp_dir })
	if first.is_error then error(first.content) end
	local first_id = extract_id(first)
	wait_for(tmp_dir, first_id, "running", 5)
	local second = job_start.execute({ command = "sleep 30" }, { cwd = tmp_dir })
	if second.is_error then error(second.content) end
	local second_id = extract_id(second)
	wait_for(tmp_dir, second_id, "running", 5)

	local seen_error
	local fake_ui = {
		block = function() end,
		muted = function() end,
		error = function(text) seen_error = text end,
	}
	commands.dispatch("/job-output 5", { cwd = tmp_dir }, fake_ui)
	if not seen_error or not seen_error:find("usage: /job-output <id>", 1, true) then
		error("missing ambiguous job usage error")
	end
	job_stop.execute({ id = first_id }, { cwd = tmp_dir })
	job_stop.execute({ id = second_id }, { cwd = tmp_dir })
end)

test("job prune keeps running and recent finished jobs", function()
	local now = os.time()
	local old_time = os.date("!%Y-%m-%dT%H:%M:%SZ", now - (10 * 86400))
	local recent_time = os.date("!%Y-%m-%dT%H:%M:%SZ", now - 60)
	local running_result = job_start.execute({
		command = "sleep 30",
	}, { cwd = tmp_dir })
	if running_result.is_error then error(running_result.content) end
	local running_id = extract_id(running_result)
	wait_for(tmp_dir, running_id, "running", 5)

	local old = {
		id = "job_old",
		command = "true",
		cwd = tmp_dir,
		started_at = old_time,
		finished_at = old_time,
		status = "exited",
		exit_code = 0,
		stdout = tmp_dir .. "/.lca/jobs/job_old/stdout.log",
		stderr = tmp_dir .. "/.lca/jobs/job_old/stderr.log",
	}
	local recent = {
		id = "job_recent",
		command = "true",
		cwd = tmp_dir,
		started_at = recent_time,
		finished_at = recent_time,
		status = "exited",
		exit_code = 0,
		stdout = tmp_dir .. "/.lca/jobs/job_recent/stdout.log",
		stderr = tmp_dir .. "/.lca/jobs/job_recent/stderr.log",
	}
	jobs.save(tmp_dir, old)
	jobs.save(tmp_dir, recent)

	local pruned = jobs.prune(tmp_dir, { days = 7, min_finished = 0, now = now })
	if pruned.count ~= 1 or pruned.pruned[1] ~= "job_old" then
		error("unexpected prune result")
	end
	if jobs.load(tmp_dir, "job_old") then
		error("old job still exists")
	end
	if not jobs.load(tmp_dir, "job_recent") then
		error("recent job was pruned")
	end
	if not jobs.load(tmp_dir, running_id) then
		error("live running job was pruned")
	end
	job_stop.execute({ id = running_id }, { cwd = tmp_dir })
end)

test("job-prune slash command reports cleanup", function()
	local now = os.time()
	local old_time = os.date("!%Y-%m-%dT%H:%M:%SZ", now - (10 * 86400))
	local old = {
		id = "job_slash_old",
		command = "true",
		cwd = tmp_dir,
		started_at = old_time,
		finished_at = old_time,
		status = "exited",
		exit_code = 0,
		stdout = tmp_dir .. "/.lca/jobs/job_slash_old/stdout.log",
		stderr = tmp_dir .. "/.lca/jobs/job_slash_old/stderr.log",
	}
	jobs.save(tmp_dir, old)

	local seen = {}
	local fake_ui = {
		block = function(text) seen[#seen + 1] = text end,
		muted = function(text) seen[#seen + 1] = text end,
		error = function(text) error(text) end,
	}
	commands.dispatch("/job-prune 7", { cwd = tmp_dir }, fake_ui)
	local body = table.concat(seen, "\n")
	if not body:find("pruned 1 jobs", 1, true) then
		error("slash prune did not report cleanup")
	end
end)

test("job display summarizes background command", function()
	local job = {
		id = "job_display",
		command = 'python3 -c \'HTTPServer(("127.0.0.1", 8001), Handler).serve_forever()\'',
		status = "running",
		started_at = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() - 90),
		pid = 123,
	}
	local display = jobs.display(job, os.time())
	if display.label ~= "python http server" then
		error("unexpected label: " .. tostring(display.label))
	end
	if display.port ~= ":8001" then
		error("unexpected port: " .. tostring(display.port))
	end
	if display.age ~= "1m" then
		error("unexpected age: " .. tostring(display.age))
	end
end)

test("job display detects python module http server port", function()
	local job = {
		id = "job_module_server",
		command = "python3 -m http.server 8002 --bind 127.0.0.1",
		status = "running",
		started_at = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time()),
	}
	local display = jobs.display(job, os.time())
	if display.port ~= ":8002" then
		error("unexpected port: " .. tostring(display.port))
	end
	if display.label ~= "python http server" then
		error("unexpected label: " .. tostring(display.label))
	end
end)

test("job_start defaults to no timeout and reports it", function()
	local result = job_start.execute({
		command = "printf 'quick\\n'",
	}, { cwd = tmp_dir })
	if result.is_error then error(result.content) end
	if not result.content:find("timeout: none", 1, true) then
		error("job_start did not report timeout none")
	end
	local id = extract_id(result)
	local job = wait_for(tmp_dir, id, "exited", 5)
	if job.timeout ~= nil then
		error("job unexpectedly had timeout")
	end
end)

test("job display shows explicit timeout", function()
	local job = {
		id = "job_timeout_display",
		command = "sleep 10",
		status = "running",
		started_at = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time()),
		timeout = 120000,
	}
	local display = jobs.display(job, os.time())
	if display.timeout ~= "2m" then
		error("unexpected timeout display: " .. tostring(display.timeout))
	end
end)

test("jobs visible hides finished jobs when running jobs exist", function()
	local now = os.time()
	local old_time = os.date("!%Y-%m-%dT%H:%M:%SZ", now - 120)
	local running_result = job_start.execute({
		command = "sleep 30",
	}, { cwd = tmp_dir })
	if running_result.is_error then error(running_result.content) end
	local running_id = extract_id(running_result)
	wait_for(tmp_dir, running_id, "running", 5)

	jobs.save(tmp_dir, {
		id = "job_hidden_finished",
		command = "true",
		cwd = tmp_dir,
		started_at = old_time,
		finished_at = old_time,
		status = "exited",
		exit_code = 0,
		stdout = tmp_dir .. "/.lca/jobs/job_hidden_finished/stdout.log",
		stderr = tmp_dir .. "/.lca/jobs/job_hidden_finished/stderr.log",
	})

	local visible = jobs.visible(tmp_dir)
	if #visible ~= 1 or visible[1].id ~= running_id then
		error("default visible jobs should include only running job")
	end
	local all = jobs.visible(tmp_dir, { all = true })
	local saw_finished = false
	for _, job in ipairs(all) do
		if job.id == "job_hidden_finished" then
			saw_finished = true
		end
	end
	if not saw_finished then
		error("--all visible jobs did not include finished job")
	end
	job_stop.execute({ id = running_id }, { cwd = tmp_dir })
end)

test("jobs visible keeps failed starts briefly only when no jobs run", function()
	local now = os.time()
	jobs.save(tmp_dir, {
		id = "job_recent_failed",
		command = "bad",
		cwd = tmp_dir,
		started_at = os.date("!%Y-%m-%dT%H:%M:%SZ", now - 30),
		finished_at = os.date("!%Y-%m-%dT%H:%M:%SZ", now - 30),
		status = "failed_to_start",
		stdout = tmp_dir .. "/.lca/jobs/job_recent_failed/stdout.log",
		stderr = tmp_dir .. "/.lca/jobs/job_recent_failed/stderr.log",
	})
	jobs.save(tmp_dir, {
		id = "job_old_failed",
		command = "bad",
		cwd = tmp_dir,
		started_at = os.date("!%Y-%m-%dT%H:%M:%SZ", now - 120),
		finished_at = os.date("!%Y-%m-%dT%H:%M:%SZ", now - 120),
		status = "failed_to_start",
		stdout = tmp_dir .. "/.lca/jobs/job_old_failed/stdout.log",
		stderr = tmp_dir .. "/.lca/jobs/job_old_failed/stderr.log",
	})

	local visible = jobs.visible(tmp_dir, { now = now })
	local saw_recent = false
	local saw_old = false
	for _, job in ipairs(visible) do
		if job.id == "job_recent_failed" then saw_recent = true end
		if job.id == "job_old_failed" then saw_old = true end
	end
	if not saw_recent then
		error("recent failed job should be visible")
	end
	if saw_old then
		error("old failed job should be hidden")
	end
end)

test("job activity reports a simple linux running state", function()
	local result = job_start.execute({
		command = "sleep 30",
	}, { cwd = tmp_dir })
	if result.is_error then error(result.content) end
	local id = extract_id(result)
	local job = wait_for(tmp_dir, id, "running", 5)
	local activity = jobs.activity(job)
	if activity ~= "" and activity ~= "ready" and activity ~= "active" and activity ~= "wait" then
		error("unexpected activity for sleep: " .. tostring(activity))
	end
	local display = jobs.display(job, os.time())
	if display.activity ~= activity then
		error("display activity did not match activity helper")
	end
	job_stop.execute({ id = id }, { cwd = tmp_dir })
end)

os.execute("rm -rf " .. shell.quote(tmp_dir))

io.write("\n" .. dim("─────────────────────────────────────") .. "\n")
io.write(string.format("  %s passed, %s failed\n",
	green(tostring(passed)), failed > 0 and red(tostring(failed)) or tostring(failed)))
io.write("\n")
os.exit(failed > 0 and 1 or 0)
