#!/usr/bin/env lua

local script_dir = arg[0]:match("^(.*)/[^/]+$") or "."
local project_dir = script_dir .. "/.."
package.path = project_dir .. "/lua/?.lua;" .. project_dir .. "/lua/?/init.lua;" .. project_dir .. "/lua/?/?.lua;" .. package.path
pcall(require, "luarocks.loader")

local update_plan = require("agent.tools.update_plan")
local registry = require("agent.tool_registry")
local session_mod = require("agent.session")
local protocol = require("agent.tool_protocol")
local commands = require("agent.commands")

local passed = 0
local failed = 0

local function test(name, fn)
	io.write("  " .. name .. " ")
	io.flush()
	local ok, err = pcall(fn)
	if ok then
		passed = passed + 1
		io.write("PASS\n")
	else
		failed = failed + 1
		io.write("FAIL (" .. tostring(err) .. ")\n")
	end
end

local function assert_eq(actual, expected, msg)
	if actual ~= expected then
		error((msg or "") .. " expected: " .. tostring(expected) .. ", got: " .. tostring(actual))
	end
end

test("stores normalized plan on session", function()
	local s = session_mod.create({})
	local result = update_plan.execute({
		plan = {
			{ step = "Read files", status = "completed" },
			{ step = "Implement tool", status = "in_progress" },
			{ step = "Run tests", status = "pending" },
		},
	}, { session = s })

	assert_eq(result.is_error, false)
	assert_eq(result.summary, "updated 3 steps")
	assert_eq(#s.plan, 3)
	assert_eq(s.plan[2].step, "Implement tool")
	assert_eq(s.plan[2].status, "in_progress")
	assert(result.content:find("2. %[in_progress%] Implement tool"), "missing rendered plan content")
end)

test("accepts plan array from parsed tool call", function()
	local text = table.concat({
		'<tool_call name="update_plan">',
		'{"plan":[{"step":"Create scaffold","status":"in_progress"},{"step":"Run checks","status":"pending"}]}',
		"</tool_call>",
	}, "\n")
	local calls = protocol.extract_all_tool_calls(text)
	assert_eq(#calls, 1)

	local s = session_mod.create({})
	local result = update_plan.execute(calls[1].args, { session = s })

	assert_eq(result.is_error, false)
	assert_eq(#s.plan, 2)
	assert_eq(s.plan[1].step, "Create scaffold")
	assert_eq(s.plan[1].status, "in_progress")
end)

test("rejects multiple in progress steps", function()
	local s = session_mod.create({})
	local result = update_plan.execute({
		plan = {
			{ step = "One", status = "in_progress" },
			{ step = "Two", status = "in_progress" },
		},
	}, { session = s })

	assert_eq(result.is_error, true)
	assert(result.content:find("at most one", 1, true), "expected in_progress validation")
	assert_eq(s.plan, nil)
end)

test("clears plan with empty array", function()
	local s = session_mod.create({})
	s.plan = {
		{ step = "Existing", status = "pending" },
	}

	local result = update_plan.execute({ plan = {} }, { session = s })

	assert_eq(result.is_error, false)
	assert_eq(result.summary, "cleared plan")
	assert_eq(#s.plan, 0)
	assert_eq(result.content, "Plan cleared.")
end)

test("plan is saved and loaded with session", function()
	local path = os.tmpname()
	local s = session_mod.create({})
	s.plan = {
		{ step = "Persisted", status = "completed" },
	}

	local ok, err = s:save(path)
	if not ok then
		error(err)
	end

	local loaded = session_mod.create({})
	local loaded_ok, loaded_err = loaded:load(path)
	os.remove(path)
	if not loaded_ok then
		error(loaded_err)
	end

	assert_eq(#loaded.plan, 1)
	assert_eq(loaded.plan[1].step, "Persisted")
	assert_eq(loaded.plan[1].status, "completed")
end)

test("plan command renders current session plan", function()
	local s = session_mod.create({})
	s.plan = {
		{ step = "Inspect target", status = "completed" },
		{ step = "Implement rail view", status = "in_progress" },
	}
	local rendered = nil
	local fake_ui = {
		plan = function(plan)
			rendered = plan
		end,
	}

	commands.dispatch("/plan", s, fake_ui)

	assert_eq(rendered, s.plan)
end)

test("plan command handles empty plan", function()
	local s = session_mod.create({})
	local message = nil
	local fake_ui = {
		plan = function(plan)
			if type(plan) ~= "table" or #plan == 0 then
				message = "empty"
			end
		end,
		muted = function(text)
			message = text
		end,
	}

	commands.dispatch("/plan", s, fake_ui)

	assert_eq(message, "empty")
end)

test("tool is advertised with usage guidance", function()
	assert_eq(registry.is_valid("update_plan"), true)
	local prompt = registry.system_prompt()
	assert(prompt:find("- update_plan:", 1, true), "missing tool listing")
	assert(prompt:find("short phase checklist", 1, true), "missing phase checklist guidance")
	assert(prompt:find("3-6 short phase labels", 1, true), "missing short label guidance")
	assert(prompt:find("not user-facing explanation", 1, true), "missing internal plan guidance")
	assert(prompt:find("Be bold inside the active phase", 1, true), "missing boldness guidance")
	assert(prompt:find("fix it before finalizing", 1, true), "missing verification defect guidance")
	assert(prompt:find("10 calls or fewer", 1, true), "missing batch cap guidance")
end)

if failed > 0 then
	error(tostring(failed) .. " test(s) failed")
end

io.write("\n" .. tostring(passed) .. " test(s) passed\n")
