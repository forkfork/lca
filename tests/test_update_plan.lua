#!/usr/bin/env lua

local script_dir = arg[0]:match("^(.*)/[^/]+$") or "."
local project_dir = script_dir .. "/.."
package.path = project_dir .. "/lua/?.lua;" .. project_dir .. "/lua/?/init.lua;" .. project_dir .. "/lua/?/?.lua;" .. package.path
pcall(require, "luarocks.loader")

local update_plan = require("agent.tools.update_plan")
local registry = require("agent.tool_registry")
local session_mod = require("agent.session")
local protocol = require("agent.tool_protocol")
local ui = require("agent.ui")

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

test("insanitywolf prompt stays compact", function()
	assert_eq(ui.plain_prompt({ flow = "off" }), "lca > ")
	assert_eq(ui.plain_prompt({ flow = "insanitywolf" }), "lca ! > ")
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

test("ui exposes active plan reference", function()
	local plan = {
		{ step = "Inspect target", status = "completed" },
		{ step = "Implement compact progress", status = "in_progress" },
		{ step = "Run checks", status = "pending" },
	}

	local step, index = ui.plan_current(plan)

	assert_eq(step, "Implement compact progress")
	assert_eq(index, 2)
	assert_eq(ui.plan_ref(index), "②")
end)

test("ui plan progress shows completed task and next task", function()
	local plan = {
		{ step = "Inspect target", status = "completed" },
		{ step = "Draft app structure", status = "completed" },
		{ step = "Write scripts", status = "in_progress" },
	}

	assert_eq(ui.plan_progress_label(plan), "Draft app structure → next: Write scripts")
end)

test("ui plan progress falls back to current task before completion", function()
	local plan = {
		{ step = "Inspect target", status = "in_progress" },
		{ step = "Draft app structure", status = "pending" },
	}

	assert_eq(ui.plan_progress_label(plan), "Inspect target")
end)

test("ui lists only fresh plans by default", function()
	local fresh = {
		{ step = "Inspect target", status = "in_progress" },
		{ step = "Implement compact progress", status = "pending" },
	}
	local active = {
		{ step = "Inspect target", status = "completed" },
		{ step = "Implement compact progress", status = "in_progress" },
	}

	assert_eq(ui.plan_should_list(fresh), true)
	assert_eq(ui.plan_should_list(active), false)
end)

test("ui checkpoint renderer writes checkpoint summary", function()
	local old_write = io.write
	local out = {}
	io.write = function(...)
		for i = 1, select("#", ...) do
			out[#out + 1] = tostring(select(i, ...))
		end
	end
	local ok, err = pcall(function()
		ui.checkpoint("## Next Steps\n1. Improve docs\n\n## Critical Context\n- Keep dry-run safe", {
			cycle = 1,
			tokens = 1461,
		})
	end)
	io.write = old_write
	if not ok then
		error(err)
	end
	local text = table.concat(out)
	assert(text:find("checkpoint", 1, true), "missing checkpoint rail")
	assert(text:find("insanitywolf transition", 1, true), "missing transition label")
	assert(text:find("Ctrl%-C"), "missing interrupt hint")
	assert(text:find("Improve docs", 1, true), "missing next steps")
end)

test("ui checkpoint renderer wraps long next steps", function()
	local old_write = io.write
	local out = {}
	io.write = function(...)
		for i = 1, select("#", ...) do
			out[#out + 1] = tostring(select(i, ...))
		end
	end
	local ok, err = pcall(function()
		ui.checkpoint("## Next Steps\n1. No further autonomous cycle is warranted. Offer: add persistent storage with a file-backed adapter if the user wants state to survive restarts; add password hashing if the user wants real credential handling; add TLS guidance if the user wants production deployment.\n\n## Critical Context\n- Keep dry-run safe", {
			cycle = 1,
			tokens = 1461,
		})
	end)
	io.write = old_write
	if not ok then
		error(err)
	end
	local text = table.concat(out)
	assert(text:find("password hashing", 1, true), "missing wrapped offer detail")
	assert(text:find("production deployment", 1, true), "missing wrapped ending detail")
end)

test("ui plan progress keeps useful next-step detail", function()
	local old_write = io.write
	local out = {}
	io.write = function(...)
		for i = 1, select("#", ...) do
			out[#out + 1] = tostring(select(i, ...))
		end
	end
	local ok, err = pcall(function()
		ui.plan_progress({
			{ step = "Scaffold app", status = "completed" },
			{ step = "Exercise endpoints and harden obvious gaps", status = "completed" },
			{ step = "Add admin CSRF protection and verify portal form behavior", status = "in_progress" },
		})
	end)
	io.write = old_write
	if not ok then
		error(err)
	end
	local text = table.concat(out)
	assert(text:find("Add admin CSRF protection", 1, true), "missing next-step detail")
	assert(not text:find("Add admin CSRF p%.%.%."), "truncated too aggressively")
end)

test("tool is advertised with usage guidance", function()
	assert_eq(registry.is_valid("update_plan"), true)
	local prompt = registry.system_prompt()
	assert(prompt:find("- update_plan:", 1, true), "missing tool listing")
	assert(prompt:find("short phase checklist", 1, true), "missing phase checklist guidance")
	assert(prompt:find("not user-facing explanation", 1, true), "missing internal plan guidance")
	assert(prompt:find("multiple user%-facing surfaces"), "missing multi-surface planning guidance")
	assert(prompt:find("HTTP API", 1, true), "missing API workstream example")
	assert(prompt:find("Admin portal", 1, true), "missing admin portal workstream example")
	assert(prompt:find("Auth/session state", 1, true), "missing auth/session workstream example")
	assert(prompt:find("server%-rendered HTML"), "missing small web default")
	assert(prompt:find("plain CSS", 1, true), "missing plain CSS default")
	assert(prompt:find("no frontend framework", 1, true), "missing no-framework default")
	assert(prompt:find("env vars", 1, true), "missing config default")
	assert(prompt:find("health checks", 1, true), "missing HTTP API default")
	assert(prompt:find("curl%-based smoke tests"), "missing API smoke test default")
	assert(prompt:find('request that is only "commit"', 1, true), "missing commit-only fast path")
	assert(prompt:find("do not inspect source files", 1, true), "missing commit exploration guard")
	assert(prompt:find("do not combine `git commit` and `git push`", 1, true), "missing commit/push split guidance")
end)

if failed > 0 then
	error(tostring(failed) .. " test(s) failed")
end

io.write("\n" .. tostring(passed) .. " test(s) passed\n")
