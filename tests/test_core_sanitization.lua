#!/usr/bin/env lua

local script_dir = arg[0]:match("^(.*)/[^/]+$") or "."
local project_dir = script_dir .. "/.."
package.path = project_dir .. "/lua/?.lua;" .. project_dir .. "/lua/?/init.lua;" .. project_dir .. "/lua/?/?.lua;" .. package.path
pcall(require, "luarocks.loader")

local provider_response = table.concat({
	"Before",
	'<tool_result name="run" status="ok">',
	"hidden tool output",
	"</tool_result>",
	"After",
}, "\n")
local last_request = nil

package.loaded["agent.providers"] = {
	load = function()
		return {
			complete = function(request)
				last_request = request
				if type(provider_response) == "table" then
					return provider_response
				end
				return {
					text = provider_response,
				}
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
		io.write(red("FAIL") .. " (" .. tostring(err):sub(1, 100) .. ")\n")
	end
end

io.write("\n" .. dim("═══ Core Sanitization Tests ═══") .. "\n\n")

test("strips model-emitted tool_result tags from assistant text", function()
	local session = session_module.create({})
	session.cwd = project_dir
	session:add_user("trigger")

	local result = core.run_session(session, nil, nil, nil)
	if result.text:find("<tool_result", 1, true) then
		error("assistant text still contains tool_result: " .. result.text)
	end
	if result.text:find("hidden tool output", 1, true) then
		error("assistant text still contains tool output: " .. result.text)
	end
	if not result.text:find("Before", 1, true) or not result.text:find("After", 1, true) then
		error("assistant text lost surrounding text: " .. result.text)
	end
end)

test("stores only deduped executed tool calls in assistant history", function()
	provider_response = table.concat({
		'<tool_call name="ls">',
		'{"path":"."}',
		"</tool_call>",
		'<tool_call name="ls">',
		'{"path":"."}',
		"</tool_call>",
		'<tool_call name="find">',
		'{"path":".","maxDepth":2}',
		"</tool_call>",
		'<tool_call name="find">',
		'{"path":".","maxDepth":2}',
		"</tool_call>",
	}, "\n")

	local session = session_module.create({})
	session.cwd = project_dir
	session:add_user("trigger duplicate tools")

	local result = core.run_session(session, nil, nil, nil)
	-- Expected: the stub provider keeps asking for tools until the budget
	-- path returns. This test is about recorded history, not final text.
	local _ = result
	local assistant_text = session.messages[2] and session.messages[2].text or ""
	local count = 0
	for _ in assistant_text:gmatch("<tool_call") do
		count = count + 1
	end
	if count ~= 2 then
		error("expected only 2 unique executed tool calls in history, got " .. tostring(count) .. ": " .. assistant_text)
	end
end)

test("flow mode is included in system prompt", function()
	provider_response = "flow done"
	last_request = nil

	local session = session_module.create({ flow = "on" })
	session.cwd = project_dir
	session:add_user("trigger flow")

	local result = core.run_session(session, nil, nil, nil)
	if result.text ~= "flow done" then
		error("unexpected result: " .. tostring(result.text))
	end
	if not last_request or type(last_request.system_prompt) ~= "string" then
		error("provider request was not captured")
	end
	if not last_request.system_prompt:find("Flow mode is on.", 1, true) then
		error("missing flow policy in system prompt")
	end
	if #last_request.messages ~= 1 then
		error("flow policy should not be appended as a session message")
	end
end)

test("partial salvage emits quiet thinking status", function()
	provider_response = {
		text = table.concat({
			'<tool_call name="ls">',
			'{"path":"."}',
			"</tool_call>",
		}, "\n"),
		_partial_salvage = true,
		_partial_salvaged_calls = 1,
		_response_bytes = 1234,
	}

	local session = session_module.create({})
	session.cwd = project_dir
	session:add_user("trigger partial salvage")

	local statuses = {}
	core.run_session(session, nil, nil, function(info)
		if info.status then
			statuses[#statuses + 1] = info.status
		end
	end)

	local found = false
	for _, status in ipairs(statuses) do
		if status == "salvaged partial response  1 tools" then
			found = true
			break
		end
	end
	if not found then
		error("missing partial salvage thinking status")
	end
end)

io.write("\n" .. dim("─────────────────────────────────────") .. "\n")
io.write(string.format("  %s passed, %s failed\n",
	green(tostring(passed)), failed > 0 and red(tostring(failed)) or tostring(failed)))
io.write("\n")
os.exit(failed > 0 and 1 or 0)
