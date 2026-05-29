package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local turn_state = require("agent.turn_state")
local ui = require("agent.ui")

local passed = 0
local failed = 0

local function assert_contains(text, needle)
	if not tostring(text):find(needle, 1, true) then
		error("expected to find " .. tostring(needle) .. "\n--- text ---\n" .. tostring(text))
	end
end

local function test(name, fn)
	io.write("  " .. name .. " ")
	local ok, err = pcall(fn)
	if ok then
		passed = passed + 1
		io.write("\27[32mPASS\27[0m\n")
	else
		failed = failed + 1
		io.write("\27[31mFAIL\27[0m\n")
		io.write(tostring(err) .. "\n")
	end
end

print("\n\27[2m═══ Turn State Tests ═══\27[0m\n")

test("renders a recursive live turn object", function()
	local state = turn_state.new({ intent = "create Lua auth API" })
	state:tool_event({ name = "ls", args = { path = "/home/tim/git" }, result = { is_error = false, summary = "93 entries" } })
	state:tool_event({ name = "write", args = { path = "/home/tim/git/crap3/app.lua" }, result = { is_error = false, summary = "written" } })
	state:tool_event({ name = "write", args = { path = "/home/tim/git/crap3/src/http.lua" }, result = { is_error = false, summary = "written" } })
	state:tool_event({ name = "run", args = { command = "lua app.lua" }, result = { is_error = false, summary = "ok", content = "syntax ok\n" } })
	state:set_return("http://127.0.0.1:18080/admin")

	local rendered = state:render()
	assert_contains(rendered, "turn {")
	assert_contains(rendered, 'intent = ok("create Lua auth API")')
	assert_contains(rendered, 'inspect = ok("1 lookup")')
	assert_contains(rendered, 'changes = ok("2 files saved  app.lua, http.lua")')
	assert_contains(rendered, 'verify = ok("1 check")')
	assert_contains(rendered, 'return_value = ok("http://127.0.0.1:18080/admin")')
end)

test("tracks streamed tool batches before execution", function()
	local state = turn_state.new({ intent = "make crap2" })
	state:stream_tool_open("update_plan")
	state:stream_tool_close()
	state:stream_tool_open("write", "app.lua 8.4kB")
	state:stream_tool_progress("write app.lua 9.1kB")
	local rendered = state:render({ collapse_ok = false })

	assert_contains(rendered, 'tool_batch = streaming("2 tools, 1 closed")')
end)

test("streamed tool closed count cannot exceed discovered tools", function()
	local state = turn_state.new({ intent = "bad stream count" })
	state:stream_tool_open("write")
	state:stream_tool_close()
	state:stream_tool_close()

	local rendered = state:render({ collapse_ok = false })
	assert_contains(rendered, 'tool_batch = ok("1 tool, 1 closed")')
end)

test("streamed tool deferred count is rendered separately", function()
	local state = turn_state.new({ intent = "deferred stream count" })
	state:stream_tool_open("read")
	state:stream_tool_close()
	state:stream_tool_deferred("read")

	local old_write = io.write
	local chunks = {}
	io.write = function(...)
		for _, value in ipairs({ ... }) do
			chunks[#chunks + 1] = tostring(value)
		end
	end
	local ok, err = pcall(function()
		ui.live_ast(state, { label = "work" })
	end)
	io.write = old_write
	if not ok then
		error(err)
	end
	assert_contains(table.concat(chunks), "1 tool, 1 closed, +1 deferred")
end)

test("keeps cancellation as partial evaluation state", function()
	local state = turn_state.new({ intent = "make crap2" })
	state:stream_tool_open("write", "app.lua")
	state:stream_tool_close()
	state:cancel("1 complete tool call, 0 executed")
	local rendered = state:render({ collapse_ok = false })

	assert_contains(rendered, 'tool_batch = cancelled("1 complete tool call, 0 executed")')
end)

test("localizes failed verification", function()
	local state = turn_state.new({ intent = "start app" })
	state:tool_event({
		name = "run",
		args = { command = "lua app.lua" },
		result = { is_error = true, summary = "exit 1", content = "address already in use" },
	})
	local rendered = state:render()

	assert_contains(rendered, "verify {")
	assert_contains(rendered, 'return error("1 check")')
end)

test("ui can render a live ast block", function()
	local ui = require("agent.ui")
	local state = turn_state.new({ intent = "render ast" })
	state:tool_event({ name = "write", args = { path = "app.lua" }, result = { is_error = false, summary = "written" } })

	local old_write = io.write
	local chunks = {}
	io.write = function(...)
		local args = { ... }
		for _, value in ipairs(args) do
			chunks[#chunks + 1] = tostring(value)
		end
	end
	local ok, err = pcall(function()
		ui.live_ast(state, { label = "ast" })
	end)
	io.write = old_write
	if not ok then
		error(err)
	end

	local output = table.concat(chunks)
	assert_contains(output, "ast")
	assert_contains(output, "render ast")
	assert_contains(output, "changes")
end)

test("ui renders live stream preview inside tree", function()
	local ui = require("agent.ui")
	local state = turn_state.new({ intent = "stream preview" })

	local old_write = io.write
	local chunks = {}
	io.write = function(...)
		local args = { ... }
		for _, value in ipairs(args) do
			chunks[#chunks + 1] = tostring(value)
		end
	end
	local ok, err = pcall(function()
		ui.live_stream_preview("you can specify auth.db", 128)
		ui.live_ast(state, { label = "work" })
		ui.clear_live_stream_preview()
	end)
	io.write = old_write
	if not ok then
		error(err)
	end

	local output = table.concat(chunks)
	assert_contains(output, "work")
	assert_contains(output, "≋")
	assert_contains(output, "128B")
	assert_contains(output, "you can specify auth.db")
end)

test("ui stream preview hides tool protocol markers", function()
	local ui = require("agent.ui")
	local state = turn_state.new({ intent = "tool preview" })

	local old_write = io.write
	local chunks = {}
	io.write = function(...)
		local args = { ... }
		for _, value in ipairs(args) do
			chunks[#chunks + 1] = tostring(value)
		end
	end
	local ok, err = pcall(function()
		ui.live_stream_preview("write app.py · routes sessions admin", 512)
		ui.live_stream_preview("<tool_call name=\"write\">", 640)
		ui.live_ast(state, { label = "work" })
		ui.clear_live_stream_preview()
	end)
	io.write = old_write
	if not ok then
		error(err)
	end

	local output = table.concat(chunks)
	assert_contains(output, "write app.py")
	assert_contains(output, "routes sessions admin")
	if output:find("<tool_call", 1, true) then
		error("tool protocol marker leaked into stream preview")
	end
end)

test("ui reports whether tool events write persistent output", function()
	local ui = require("agent.ui")

	if ui.tool_writes_persistent({ name = "read", phase = "start", args = { path = "app.lua" } }) then
		error("read start should not require clearing the live tree")
	end
	if ui.tool_writes_persistent({
		name = "run",
		result = { is_error = false, summary = "exit 0", content = "(no output)" },
	}) then
		error("quiet successful run should stay represented by the live tree")
	end
	if ui.tool_writes_persistent({
		name = "update_plan",
		result = {
			is_error = false,
			plan = {
				{ status = "in_progress", step = "Patch UI" },
			},
		},
	}) then
		error("plan updates should stay represented by the live tree")
	end
	if not ui.tool_writes_persistent({
		name = "grep",
		result = { is_error = false, summary = "many matches", content = ("match\n"):rep(180) },
	}) then
		error("large grep output prints persistent output")
	end
end)

test("plan steps become branches for subsequent tool evidence", function()
	local state = turn_state.new({ intent = "build tool" })
	state:tool_event({
		name = "update_plan",
		result = {
			is_error = false,
			plan = {
				{ status = "completed", step = "Inspect repo" },
				{ status = "in_progress", step = "Write UI" },
				{ status = "pending", step = "Verify" },
			},
		},
	})
	state:tool_event({ name = "write", args = { path = "lua/agent/ui.lua" }, result = { is_error = false, summary = "written" } })

	local snapshot = state:snapshot()
	local plan
	for _, child in ipairs(snapshot.children or {}) do
		if child.kind == "plan" then
			plan = child
		end
	end
	if not plan then
		error("missing plan branch")
	end
	local write_step
	for _, child in ipairs(plan.children or {}) do
		if child.kind == "plan_step" and child.detail == "Write UI" then
			write_step = child
		end
	end
	if not write_step then
		error("missing active plan step")
	end
	local changes
	for _, child in ipairs(write_step.children or {}) do
		if child.kind == "changes" then
			changes = child
		end
	end
	if not changes or changes.summary ~= "1 file saved  ui.lua" then
		error("write evidence did not attach under active plan step")
	end
end)

test("snapshots retain detail pane metadata", function()
	local state = turn_state.new({ intent = "verify detail" })
	state:tool_event({
		name = "run",
		args = { command = "lua tests/test_turn_state.lua" },
		result = { is_error = true, summary = "exit 1", content = "failure line\nmore detail" },
	})

	local snapshot = state:snapshot()
	local verify
	for _, child in ipairs(snapshot.children or {}) do
		if child.kind == "verify" then
			verify = child
		end
	end
	if not verify then
		error("missing verify node")
	end
	if verify.meta.last_command ~= "lua tests/test_turn_state.lua" then
		error("missing command metadata")
	end
	if verify.meta.last_summary ~= "exit 1" then
		error("missing summary metadata")
	end
	assert_contains(verify.meta.last_output, "failure line")
end)

test("successful run output becomes a verification headline", function()
	local state = turn_state.new({ intent = "verify smoke" })
	state:tool_event({
		name = "run",
		args = { command = "lua tests/smoke.lua" },
		result = { is_error = false, summary = "exit 0", content = "Seeded admin user admin@example.test\nsmoke ok\n" },
	})

	local snapshot = state:snapshot()
	local verify
	for _, child in ipairs(snapshot.children or {}) do
		if child.kind == "verify" then
			verify = child
		end
	end
	if not verify then
		error("missing verify node")
	end
	if verify.summary ~= "1 check" then
		error("unexpected verify summary: " .. tostring(verify.summary))
	end
	assert_contains(verify.meta.last_headline, "smoke ok")
	assert_contains(verify.meta.last_output, "smoke ok")
end)

test("failed verification headline is preserved after later success", function()
	local state = turn_state.new({ intent = "verify recovery" })
	state:tool_event({
		name = "run",
		args = { command = "make smoke" },
		result = { is_error = true, summary = "exit 1", content = "connection refused\n" },
	})
	state:tool_event({
		name = "run",
		args = { command = "make smoke" },
		result = { is_error = false, summary = "exit 0", content = "smoke ok\n" },
	})

	local old_write = io.write
	local chunks = {}
	io.write = function(...)
		for _, value in ipairs({ ... }) do
			chunks[#chunks + 1] = tostring(value)
		end
	end
	local ok, err = pcall(function()
		require("agent.ui").live_ast(state, { label = "work" })
	end)
	io.write = old_write
	if not ok then
		error(err)
	end
	local output = table.concat(chunks)
	assert_contains(output, "verify connection refused")
	if output:find("verify smoke ok", 1, true) then
		error("failed verify rendered later successful headline:\n" .. output)
	end
end)

test("failed verification records failed tool leaf", function()
	local state = turn_state.new({ intent = "commit changes" })
	state:tool_event({
		name = "run",
		args = { command = "git diff --cached --check" },
		result = { is_error = true, summary = "exit 2", content = "AGENTS.md | 1 +\n" },
	})

	local snapshot = state:snapshot()
	local verify = nil
	for _, child in ipairs(snapshot.children or {}) do
		if child.kind == "verify" then
			verify = child
		end
	end
	if not verify then
		error("missing verify node")
	end
	if verify.meta.failed_headline ~= "exit 2" then
		error("unexpected failed headline: " .. tostring(verify.meta.failed_headline))
	end
	if not verify.children or #verify.children ~= 1 then
		error("missing failed tool leaf")
	end
	local tool = verify.children[1]
	if tool.kind ~= "tool" or tool.status ~= "error" then
		error("unexpected failed tool leaf")
	end
	assert_contains(tool.detail, "exit 2")
	assert_contains(tool.detail, "git diff --cached --check")
end)

test("failed run output becomes a cleaned verification headline", function()
	local state = turn_state.new({ intent = "verify module" })
	state:tool_event({
		name = "run",
		args = { command = "lua -e 'require(\"lsqlite3\")'" },
		result = {
			is_error = true,
			summary = "exit 1",
			content = "Lua 5.5.0 Copyright (C) 1994-2025 Lua.org, PUC-Rio\nlua: (command line):1: module 'lsqlite3' not found:\n\tno field package.preload['lsqlite3']\n",
		},
	})

	local snapshot = state:snapshot()
	local verify
	for _, child in ipairs(snapshot.children or {}) do
		if child.kind == "verify" then
			verify = child
		end
	end
	if not verify then
		error("missing verify node")
	end
	if verify.meta.last_headline ~= "module 'lsqlite3' not found:" then
		error("unexpected verify headline: " .. tostring(verify.meta.last_headline))
	end
end)

test("live tree displays child failure on completed plan step", function()
	local ui = require("agent.ui")
	local state = turn_state.new({ intent = "build auth app" })
	state:tool_event({
		name = "update_plan",
		result = {
			is_error = false,
			plan = {
				{ status = "in_progress", step = "Scaffold Lua auth service" },
				{ status = "pending", step = "Build admin portal" },
			},
		},
	})
	state:tool_event({
		name = "run",
		args = { command = "lua -e 'require(\"lsqlite3\")'" },
		result = { is_error = true, summary = "exit 1", content = "lua: (command line):1: module 'lsqlite3' not found:" },
	})
	state:tool_event({
		name = "update_plan",
		result = {
			is_error = false,
			plan = {
				{ status = "completed", step = "Scaffold Lua auth service" },
				{ status = "in_progress", step = "Build admin portal" },
			},
		},
	})

	local old_write = io.write
	local chunks = {}
	io.write = function(...)
		for _, value in ipairs({ ... }) do
			chunks[#chunks + 1] = tostring(value)
		end
	end
	local ok, err = pcall(function()
		ui.live_ast(state, { label = "work" })
	end)
	io.write = old_write
	if not ok then
		error(err)
	end

	local output = table.concat(chunks)
	assert_contains(output, "✗ Scaffold Lua auth service")
	assert_contains(output, "✗ verify module 'lsqlite3' not found:")
end)

test("plan completion cannot hide failed evidence", function()
	local ui = require("agent.ui")
	local state = turn_state.new({ intent = "build auth app" })
	state:tool_event({
		name = "update_plan",
		result = {
			is_error = false,
			plan = {
				{ status = "in_progress", step = "Build auth API" },
				{ status = "pending", step = "Build admin portal" },
				{ status = "pending", step = "Add docs and verification" },
			},
		},
	})
	state:tool_event({
		name = "write",
		args = { path = "app.py" },
		result = { is_error = true, summary = "write failed", content = "permission denied" },
	})
	state:tool_event({
		name = "update_plan",
		result = {
			is_error = false,
			plan = {
				{ status = "completed", step = "Build auth API" },
				{ status = "completed", step = "Build admin portal" },
				{ status = "in_progress", step = "Add docs and verification" },
			},
		},
	})

	local snapshot = state:snapshot()
	local plan
	for _, child in ipairs(snapshot.children or {}) do
		if child.kind == "plan" then
			plan = child
		end
	end
	if not plan then
		error("missing plan branch")
	end
	if plan.status ~= "error" then
		error("plan should retain failed evidence status, got " .. tostring(plan.status))
	end
	if plan.children[1].status ~= "error" then
		error("failed completed step should stay error, got " .. tostring(plan.children[1].status))
	end
	if plan.children[2].status ~= "warning" then
		error("completed step without evidence after failure should warn, got " .. tostring(plan.children[2].status))
	end

	local old_write = io.write
	local chunks = {}
	io.write = function(...)
		for _, value in ipairs({ ... }) do
			chunks[#chunks + 1] = tostring(value)
		end
	end
	local ok, err = pcall(function()
		ui.live_ast(state, { label = "work" })
	end)
	io.write = old_write
	if not ok then
		error(err)
	end

	local output = table.concat(chunks)
	assert_contains(output, "✗ Build auth API")
	assert_contains(output, "◇ Build admin portal")
	assert_contains(output, "◐ Add docs and verification")
end)

test("plan updates reconcile steps by text instead of index", function()
	local state = turn_state.new({ intent = "reorder plan" })
	state:tool_event({
		name = "update_plan",
		result = {
			is_error = false,
			plan = {
				{ status = "in_progress", step = "Build auth API" },
				{ status = "pending", step = "Verify smoke path" },
			},
		},
	})
	state:tool_event({
		name = "update_plan",
		result = {
			is_error = false,
			plan = {
				{ status = "completed", step = "Verify smoke path" },
				{ status = "in_progress", step = "Build auth API" },
			},
		},
	})

	local snapshot = state:snapshot()
	local plan
	for _, child in ipairs(snapshot.children or {}) do
		if child.kind == "plan" then
			plan = child
		end
	end
	if not plan then
		error("missing plan")
	end
	local steps = 0
	for _, child in ipairs(plan.children or {}) do
		if child.kind == "plan_step" then
			steps = steps + 1
		end
	end
	if steps ~= 2 then
		error("expected 2 reconciled plan steps, got " .. tostring(steps))
	end
end)

test("final answer cannot mark failed turn ok", function()
	local state = turn_state.new({ intent = "build auth app" })
	state:tool_event({
		name = "run",
		args = { command = "python app.py --check" },
		result = { is_error = true, summary = "exit 1", content = "syntax error" },
	})
	state:set_return("Default admin login is admin@example.com / admin123.")

	local snapshot = state:snapshot()
	if snapshot.status ~= "error" then
		error("turn root should remain error, got " .. tostring(snapshot.status))
	end
end)

test("live tree nests streamed batch under active plan", function()
	local ui = require("agent.ui")
	local state = turn_state.new({ intent = "build auth app" })
	state:tool_event({
		name = "update_plan",
		result = {
			is_error = false,
			plan = {
				{ status = "completed", step = "Inspect target directory" },
				{ status = "in_progress", step = "Scaffold Lua auth app" },
				{ status = "pending", step = "Build admin portal UI" },
			},
		},
	})
	state:stream_tool_open("write", "store.lua")
	state:stream_tool_open("write", "server.lua")
	state:stream_tool_close()

	local old_write = io.write
	local chunks = {}
	io.write = function(...)
		for _, value in ipairs({ ... }) do
			chunks[#chunks + 1] = tostring(value)
		end
	end
	local ok, err = pcall(function()
		ui.live_ast(state, { label = "work" })
	end)
	io.write = old_write
	if not ok then
		error(err)
	end

	local output = table.concat(chunks)
	if output:find("tool_batch", 1, true) then
		error("top-level protocol batch leaked into live tree:\n" .. output)
	end
	assert_contains(output, "◐ Scaffold Lua auth app")
	assert_contains(output, "◐ writing project files 1/2")
end)

test("live tree nests large streamed batch under active plan", function()
	local ui = require("agent.ui")
	local state = turn_state.new({ intent = "build auth app" })
	state:tool_event({
		name = "update_plan",
		result = {
			is_error = false,
			plan = {
				{ status = "in_progress", step = "Scaffold Lua app and config" },
				{ status = "pending", step = "Auth API and persistence" },
				{ status = "pending", step = "Admin portal UI" },
				{ status = "pending", step = "Docs and verification" },
			},
		},
	})
	for i = 1, 10 do
		state:stream_tool_open("write", i == 10 and "write" or ("file" .. tostring(i) .. ".lua"))
	end
	for _ = 1, 9 do
		state:stream_tool_close()
	end

	local old_write = io.write
	local chunks = {}
	io.write = function(...)
		for _, value in ipairs({ ... }) do
			chunks[#chunks + 1] = tostring(value)
		end
	end
	local ok, err = pcall(function()
		ui.live_ast(state, { label = "work" })
	end)
	io.write = old_write
	if not ok then
		error(err)
	end

	local output = table.concat(chunks)
	if output:find("tool_batch", 1, true) then
		error("top-level protocol batch leaked into live tree:\n" .. output)
	end
	assert_contains(output, "◐ Scaffold Lua app and config")
	assert_contains(output, "◐ writing project files 9/10")
	assert_contains(output, "○ Auth API and persistence")
	if output:find("\n  " .. "┆           ├─ ◐ writing project files", 1, true) then
		error("streamed batch rendered as a plan sibling:\n" .. output)
	end
end)

test("exports compact summary and serializable snapshot", function()
	local state = turn_state.new({ intent = "create Lua auth API" })
	state:tool_event({ name = "write", args = { path = "app.lua" }, result = { is_error = false, summary = "written" } })
	state:tool_event({ name = "run", args = { command = "lua app.lua" }, result = { is_error = true, summary = "exit 1", content = "address already in use" } })

	local summary = state:summary()
	assert_contains(summary, "intent=ok(create Lua auth API)")
	assert_contains(summary, "changes=ok(1 file saved  app.lua)")
	assert_contains(summary, "verify=error(1 check)")

	local snapshot = state:snapshot()
	if snapshot.kind ~= "turn" then
		error("unexpected snapshot root: " .. tostring(snapshot.kind))
	end
	if type(snapshot.children) ~= "table" or #snapshot.children == 0 then
		error("snapshot children missing")
	end
	local found_changes = false
	for _, child in ipairs(snapshot.children) do
		if child.kind == "changes" and child.summary == "1 file saved  app.lua" then
			found_changes = true
		end
	end
	if not found_changes then
		error("snapshot missing changes summary")
	end
end)

print("\n\27[2m─────────────────────────────────────\27[0m")
print("  \27[32m" .. tostring(passed) .. "\27[0m passed, " .. (failed == 0 and "\27[32m" or "\27[31m") .. tostring(failed) .. "\27[0m failed\n")

if failed > 0 then
	os.exit(1)
end
