#!/usr/bin/env lua

local script_dir = arg[0]:match("^(.*)/[^/]+$") or "."
local project_dir = script_dir .. "/.."
package.path = project_dir .. "/lua/?.lua;" .. project_dir .. "/lua/?/init.lua;" .. project_dir .. "/lua/?/?.lua;" .. package.path
pcall(require, "luarocks.loader")

local update_plan = require("agent.tools.update_plan")
local registry = require("agent.tool_registry")
local session_mod = require("agent.session")
local protocol = require("agent.tool_protocol")

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
	assert_eq(result.plan_fresh, true)
	assert_eq(#s.plan, 3)
	assert_eq(s.plan[2].step, "Implement tool")
	assert_eq(s.plan[2].status, "in_progress")
	assert(result.content:find("2. %[in_progress%] Implement tool"), "missing rendered plan content")
end)

test("legacy journey metadata is ignored without changing checklist behavior", function()
	for _, legacy in ipairs({
		{ destination = "old goal", approach = "old approach", proof = "old proof" },
		{ destination = "incomplete metadata" },
		"invalid legacy metadata",
	}) do
		local s = session_mod.create({})
		s.journey = legacy
		local result = update_plan.execute({
			journey = legacy,
			plan = { { step = "Implement and verify", status = "in_progress" } },
		}, { session = s })
		assert_eq(result.is_error, false)
		assert_eq(result.plan[1].step, "Implement and verify")
		assert_eq(s.plan[1].status, "in_progress")
		assert_eq(result.journey, nil)
		assert_eq(s.journey, nil)
	end
end)

test("marks only the first plan after empty state as fresh", function()
	local s = session_mod.create({})
	local first = update_plan.execute({
		plan = {
			{ step = "Previous cycle", status = "completed" },
			{ step = "Next cycle", status = "in_progress" },
		},
	}, { session = s })
	local second = update_plan.execute({
		plan = {
			{ step = "Previous cycle", status = "completed" },
			{ step = "Next cycle", status = "completed" },
			{ step = "Verify", status = "in_progress" },
		},
	}, { session = s })

	assert_eq(first.plan_fresh, true)
	assert_eq(second.plan_fresh, false)
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

test("tool is advertised through native schema and guidance", function()
	assert_eq(registry.is_valid("update_plan"), true)
	local found = false
	for _, spec in ipairs(registry.native_tools()) do
		if spec.name == "update_plan" then
			found = true
			assert_eq(spec.parameters.properties.plan.type, "array")
			assert_eq(spec.parameters.properties.journey, nil)
			assert(not spec.description:find("journey", 1, true))
			assert(spec.description:find("how to verify", 1, true))
		end
	end
	assert_eq(found, true)
	local prompt = registry.native_system_prompt()
	assert(prompt:find("short execution plan", 1, true), "missing native planning guidance")
	assert(prompt:find("bounded initial inspection batch", 1, true), "missing evidence-before-trajectory guidance")
	assert(prompt:find("Avoid generic plan steps", 1, true), "missing generic-plan guard")
	assert(prompt:find("concrete changes and how to verify them", 1, true), "missing verification guidance")
	assert(not prompt:find("journey", 1, true), "retired journey guidance remains")
	assert(prompt:find("Do not call read and edit/write for the same file in parallel", 1, true), "missing dependency guidance")
end)
test("native prompt requests evidence-dense project orientation", function()
	local prompt = registry.native_system_prompt()
	assert(prompt:find("authoritative documentation", 1, true), "missing authoritative orientation sources")
	assert(prompt:find("repository tree", 1, true), "missing tree inspection guidance")
	assert(prompt:find("documented intent", 1, true), "missing intent-versus-code guidance")
	assert(prompt:find("components absent from the tree", 1, true), "missing absent-component guidance")
	assert(prompt:find("exactly three useful starting files", 1, true), "missing bounded starting points")
	assert(not prompt:find("Rill", 1, true), "orientation guidance must not name the eval fixture")
end)

test("multi-edit can be hidden for controlled evals", function()
	registry.set_multi_edit_enabled(true)
	assert_eq(registry.is_valid("multi_edit"), true)
	local found = false
	for _, spec in ipairs(registry.native_tools()) do
		if spec.name == "multi_edit" then found = true end
	end
	assert_eq(found, true, "native schema should advertise multi_edit")
	assert(registry.native_system_prompt():find("use multi_edit", 1, true), "missing native multi-edit guidance")

	registry.set_multi_edit_enabled(false)
	assert_eq(registry.is_valid("multi_edit"), false)
	found = false
	for _, spec in ipairs(registry.native_tools()) do
		if spec.name == "multi_edit" then found = true end
	end
	assert_eq(found, false, "control eval should hide multi_edit")
	assert(not registry.native_system_prompt():find("use multi_edit", 1, true), "control prompt should hide multi-edit guidance")
	registry.set_multi_edit_enabled(true)
end)

if failed > 0 then
	error(tostring(failed) .. " test(s) failed")
end

io.write("\n" .. tostring(passed) .. " test(s) passed\n")
