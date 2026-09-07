#!/usr/bin/env lua

local script_dir = arg[0]:match("^(.*)/[^/]+$") or "."
local project_dir = script_dir .. "/.."
package.path = project_dir .. "/lua/?.lua;" .. project_dir .. "/lua/?/init.lua;" .. project_dir .. "/lua/?/?.lua;" .. package.path
pcall(require, "luarocks.loader")

local shell = require("agent.util.shell")
local native_fixture = dofile(project_dir .. "/tests/native_fixture.lua")
local provider_calls, reply = 0, nil
package.loaded["agent.providers"] = {
	load = function()
		return { complete = function(request)
			provider_calls = provider_calls + 1
			for _, message in ipairs(request.messages or {}) do
				assert(not tostring(message.text or ""):find("Read-only loop guard", 1, true),
					"read-only guard must not impersonate the user")
			end
			return native_fixture.response(reply(request, provider_calls))
		end }
	end,
}
local core = require("agent.core")
local session_module = require("agent.session")
local tmp_dir = os.tmpname() .. "_lca_read_loop_guard_tests"
os.execute("mkdir -p " .. shell.quote(tmp_dir))
local f = assert(io.open(tmp_dir .. "/loop.txt", "w"))
for i = 1, 12 do f:write("line " .. i .. "\n") end
f:close()

local function read_call(offset)
	return '<tool_call name="read">\n{"path":"loop.txt","offset":' .. offset
		.. ',"limit":1}\n</tool_call>'
end
local function new_session()
	provider_calls = 0
	local session = session_module.create({})
	session.cwd = tmp_dir
	session:add_user("Explain the contents of this file. Do not change anything.")
	return session
end
local passed, failed = 0, 0
local function test(name, fn)
	local ok, err = pcall(fn)
	if ok then passed = passed + 1 else failed = failed + 1 end
	print((ok and "PASS " or "FAIL ") .. name .. (ok and "" or (": " .. tostring(err))))
end

test("distinct read-only batches can finish beyond the former cutoff", function()
	reply = function(_, n)
		return n <= 8 and read_call(n) or "Here is the explanation."
	end
	local session = new_session()
	local reads = 0
	local result = core.run_session(session, nil, function(event)
		if event.name == "read" and event.result then reads = reads + 1 end
	end)
	assert(result.text == "Here is the explanation.", tostring(result.text))
	assert(provider_calls == 9, "expected eight reads and a final answer")
	assert(reads == 8, "distinct ranges must all execute")
end)

test("unchanged repeated reads retain duplicate protection and reach the general budget", function()
	local saw_budget = false
	reply = function(request, n)
		assert(n <= 60, "repetition escaped the general budget")
		for _, message in ipairs(request.messages or {}) do
			if tostring(message.text or ""):find("Implementation closure allowance exhausted.", 1, true) then
				saw_budget = true
				return "Partial answer from the available evidence."
			end
		end
		return read_call(1)
	end
	local session = new_session()
	local reads = 0
	local result = core.run_session(session, nil, function(event)
		if event.name == "read" and event.result then reads = reads + 1 end
	end)
	assert(saw_budget, "expected the general tool budget to end repetition")
	assert(provider_calls > 6 and provider_calls <= 60, "unexpected model-call budget")
	assert(reads == 1, "unchanged duplicate ranges should not execute again")
	assert(result.text == "Partial answer from the available evidence.", tostring(result.text))
end)

os.execute("rm -rf " .. shell.quote(tmp_dir))
print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed > 0 and 1 or 0)
