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
