#!/usr/bin/env lua

local script_dir = arg[0]:match("^(.*)/[^/]+$") or "."
local project_dir = script_dir .. "/.."
package.path = project_dir .. "/lua/?.lua;" .. project_dir .. "/lua/?/init.lua;" .. project_dir .. "/lua/?/?.lua;" .. package.path
pcall(require, "luarocks.loader")

local calls = 0
local command = "printf started; sleep 2.1; printf finished"
local expected_output = "startedfinished"
local json = require("agent.util.json")
local native_fixture = dofile(project_dir .. "/tests/native_fixture.lua")

package.loaded["agent.providers"] = {
	load = function()
		return {
			complete = function(request)
				calls = calls + 1
				if calls == 2 then
					local operational = request.messages[#request.messages].text
					assert(operational:find("Command evidence", 1, true), "core must record tool outcomes before the next request")
					assert(operational:find(command, 1, true), "command evidence must identify its command")
					local result = request.messages[#request.messages - 1]
					assert(result.native_call_id, "tool result must return to model with its call ID")
					assert(result.text:find(expected_output, 1, true), "model must receive command output")
					return native_fixture.response({text="Task finished after inspecting tool output.",
						_usage={prompt_tokens=100,cached_tokens=50,cache_available=true}})
				end
				assert(calls == 1, "unexpected extra model call")
				return native_fixture.response({
					text = table.concat({
						'<tool_call name="run">',
						json.encode({command=command,timeout=120000}),
						"</tool_call>",
					}, "\n"),
					_usage = { prompt_tokens = 2048, cached_tokens = 1024, cache_available = true },
				})
			end,
		}
	end,
}

local core = require("agent.core")
local session_module = require("agent.session")

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

io.write("\n" .. dim("═══ Core Direct Return Tests ═══") .. "\n\n")

test("curl prompt still lets the model inspect the result and finish", function()
	local session = session_module.create({})
	session.cwd = project_dir
	session:add_user("curl it")

	local events = {}
	local result = core.run_session(session, nil, function(event) events[#events + 1] = event end, nil)
	if result.text ~= "Task finished after inspecting tool output." then
		error("unexpected direct result: " .. tostring(result.text))
	end
	if calls ~= 2 then
		error("expected two provider calls, got " .. tostring(calls))
	end
	if not result._usage or result._usage.cached_tokens ~= 50 then
		error("final result lost exact provider usage")
	end
	local progress, finish
	for _, event in ipairs(events) do
		if event.phase == "progress" then progress = event end
		if event.phase == "finish" then finish = event end
	end
	if not progress or (progress.progress.elapsed_ms or 0) < 1900 then
		error("core did not forward a measured run heartbeat")
	end
	if not finish or (finish.duration_ms or 0) < 2000 then
		error("core did not retain measured tool duration")
	end
end)

test("curl command inside a build must not end the task with stdout", function()
	calls = 0
	-- Exercise a real curl command offline; the old shortcut matched its prefix.
	command = "curl --version"
	expected_output = "libcurl"
	local session = session_module.create({})
	session.cwd = project_dir
	session:add_user("Build the terminal Bach braille player with synchronized audio.")
	local result = core.run_session(session, nil, nil, nil)
	assert(calls == 2, "curl stdout ended the task before the model could continue")
	assert(result.text == "Task finished after inspecting tool output.", "raw stdout became the final answer")
end)

io.write("\n" .. dim("─────────────────────────────────────") .. "\n")
io.write(string.format("  %s passed, %s failed\n",
	green(tostring(passed)), failed > 0 and red(tostring(failed)) or tostring(failed)))
io.write("\n")
os.exit(failed > 0 and 1 or 0)
