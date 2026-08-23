#!/usr/bin/env lua

local script_dir = arg[0]:match("^(.*)/[^/]+$") or "."
local project_dir = script_dir .. "/.."
package.path = project_dir .. "/lua/?.lua;" .. project_dir .. "/lua/?/init.lua;" .. package.path
pcall(require, "luarocks.loader")

local lcatui = require("lcatui")
local tui = require("agent.tui")

local passed, failed = 0, 0

local function assert_eq(actual, expected, message)
	if actual ~= expected then
		error((message or "values differ") .. "\nexpected: " .. tostring(expected) .. "\nactual: " .. tostring(actual))
	end
end

local function assert_contains(text, needle, message)
	if not tostring(text):find(needle, 1, true) then
		error((message or "missing text") .. ": " .. tostring(needle))
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
		io.write("\27[31mFAIL\27[0m (" .. tostring(err):sub(1, 160) .. ")\n")
	end
end

local function start(id, name, args)
	return { type = "tool", phase = "start", call_id = id, name = name, args = args or {} }
end

local function finish(id, name, args, result)
	return { type = "tool", call_id = id, name = name, args = args or {}, result = result }
end

local function replay_supabase_sequence(state)
	state:submit("build a lean Supabase starter here")
	state:model_waiting()
	state:tool_event(start("inspect-ls", "ls", { path = "." }))
	state:tool_event(start("inspect-find", "find", { path = ".", maxDepth = 2 }))
	state:tool_event(start("inspect-plan", "update_plan", { plan = {
		{ step = "Inspect directory", status = "in_progress" },
		{ step = "Create app files", status = "pending" },
		{ step = "Verify build", status = "pending" },
	} }))
	state:tool_event(finish("inspect-find", "find", { path = ".", maxDepth = 2 }, { is_error = false, summary = "0 paths" }))
	state:tool_event(finish("inspect-ls", "ls", { path = "." }, { is_error = false, summary = "empty" }))
	state:tool_event(finish("inspect-plan", "update_plan", {}, { is_error = false, summary = "updated 3 steps", plan = {
		{ step = "Inspect directory", status = "completed" },
		{ step = "Create app files", status = "in_progress" },
		{ step = "Verify build", status = "pending" },
	} }))

	local paths = { "package.json", "index.html", "src/main.js", "src/styles.css", ".env.example", "migration.sql", "config.toml", "README.md" }
	for index, path in ipairs(paths) do
		local id = "write-" .. tostring(index)
		state:tool_event(start(id, "write", { path = path }))
		state:tool_event(finish(id, "write", { path = path }, { is_error = false, summary = "wrote " .. tostring(index * 7) .. " lines" }))
	end
	state:tool_event(finish("plan-write", "update_plan", {}, { is_error = false, summary = "updated 3 steps", plan = {
		{ step = "Inspect directory", status = "completed" },
		{ step = "Create app files", status = "completed" },
		{ step = "Verify build", status = "in_progress" },
	} }))
	state:tool_event(start("build-1", "run", { command = "npm install && npm run build" }))
	state:tool_event(finish("build-1", "run", { command = "npm install && npm run build" }, {
		is_error = true, summary = "exit 1", content = "top-level await is not available",
	}))
	state:tool_event(start("read-source", "read", { path = "src/main.js", offset = 1, limit = 70 }))
	state:tool_event(finish("read-source", "read", { path = "src/main.js", offset = 1, limit = 70 }, { is_error = false, summary = "70 lines" }))
	state:tool_event(start("repair", "edit", { path = "src/main.js" }))
	state:tool_event(finish("repair", "edit", { path = "src/main.js" }, { is_error = false, summary = "replaced 10 lines" }))
	state:tool_event(start("build-2", "run", { command = "npm run build" }))
	state:tool_event(finish("build-2", "run", { command = "npm run build" }, { is_error = false, summary = "exit 0", content = "built in 312ms" }))
	state:model_stream("Supabase starter created. ")
	state:model_stream("Build passes.")
	state:assistant_complete("Supabase starter created. Build passes.")
	state:listen()
end

io.write("\n═══ TUI Adapter Tests ═══\n\n")

test("concurrent tools coexist and resolve by stable identity", function()
	local state = tui.State.new({ clock = function() return 10 end })
	state:tool_event(start("a", "ls", { path = "." }))
	state:tool_event(start("b", "find", { path = "." }))
	state:tool_event(start("c", "read", { path = "README.md" }))
	assert_eq(#state:active_tools(), 3)
	state:tool_event(finish("b", "find", { path = "." }, { is_error = false, summary = "12 files" }))
	assert_eq(#state:active_tools(), 2)
	assert_eq(state.tools_by_id.a.status, "active")
	assert_eq(state.tools_by_id.b.status, "ok")
	assert_eq(state.tools_by_id.c.status, "active")
end)

test("realistic failure recovery settles into listening state", function()
	local tick = 0
	local state = tui.State.new({ clock = function() tick = tick + 1; return tick end })
	replay_supabase_sequence(state)
	assert_eq(state.mode, "listening")
	assert_eq(state.failure, nil)
	assert_eq(state.verification, "exit 0")
	assert_eq(state.proof, 1)
	assert_eq(state.disturbance, 0)
	assert_contains(state.assistant, "Build passes")
	assert_eq(#state.tools, 16)
end)

test("file tools become filename objects instead of source or diff fragments", function()
	local state = tui.State.new({ clock = function() return 10 end })
	state:tool_event(finish("read-1", "read", { path = "lua/agent/core.lua" }, {
		is_error = false, summary = "2 lines", content = "336:aB9z: function core.run_session(session)\n337:q1Wx: return true",
	}))
	state:tool_event(start("edit-1", "edit", {
		path = "lua/agent/tui.lua", start_line = 20, end_line = 22,
		_raw_content = "local current = make_current(width)\nreturn current",
	}))
	state:tool_event(finish("edit-1", "edit", {
		path = "lua/agent/tui.lua", start_line = 20, end_line = 22,
		_raw_content = "local current = make_current(width)\nreturn current",
	}, { is_error = false, summary = "replaced 3 lines" }))
	local by_kind = {}
	for _, stream in ipairs(state.streams) do
		by_kind[stream.kind] = stream
		if stream.text:find("function core.run_session", 1, true) or stream.text:find("local current", 1, true) then
			error("source content leaked into filename stream")
		end
	end
	assert_eq(by_kind.file_read.text, "core.lua")
	assert_eq(by_kind.file_changed.text, "tui.lua")
	assert_eq(by_kind.file_changed.file, true)
	assert_eq(by_kind.file_changed.verb, "edit")
end)

test("plan updates put the focused task name into the current", function()
	local state = tui.State.new({ clock = function() return 10 end })
	local started_plan = {
		{ step = "Inspect renderer timing", status = "completed" },
		{ step = "Smooth filename motion", status = "in_progress" },
		{ step = "Verify in a PTY", status = "pending" },
	}
	state:tool_event(start("plan-1", "update_plan", { plan = started_plan }))
	local active = state.streams[#state.streams]
	assert_eq(active.kind, "task_active")
	assert_eq(active.text, "Smooth filename motion")
	assert_eq(active.task, true)
	local finished_plan = {
		{ step = "Inspect renderer timing", status = "completed" },
		{ step = "Smooth filename motion", status = "completed" },
		{ step = "Verify in a PTY", status = "in_progress" },
	}
	state:tool_event(finish("plan-1", "update_plan", { plan = started_plan }, {
		is_error = false, summary = "updated 3 steps", plan = finished_plan,
	}))
	local settled = state.streams[#state.streams]
	assert_eq(settled.kind, "task")
	assert_eq(settled.text, "Verify in a PTY")
	assert_eq(settled.task_status, "in_progress")
end)

test("UTF-8 editor handles cursor history backspace and delete", function()
	local editor = tui.Editor.new({ "older command" })
	local input = tui.Input.new(editor)
	for index = 1, #"héλ" do input:feed(("héλ"):sub(index, index), false) end
	assert_eq(editor:text(), "héλ")
	input:feed("\27", false); input:feed("[", false); input:feed("D", false)
	input:feed(string.char(127), false)
	assert_eq(editor:text(), "hλ")
	input:feed("\27", false); input:feed("[", false); input:feed("3", false); input:feed("~", false)
	assert_eq(editor:text(), "h")
	input:feed("\27", false); input:feed("[", false); input:feed("A", false)
	assert_eq(editor:text(), "older command")
	local action = input:feed("\r", false)
	assert_eq(action.type, "submit")
	assert_eq(action.text, "older command")
end)

test("complete arrow-key chunks move exactly one history entry", function()
	local editor = tui.Editor.new({ "first", "second", "third" })
	local input = tui.Input.new(editor)
	local actions = input:feed_chunk("\27[A", false)
	assert_eq(#actions, 0)
	assert_eq(editor:text(), "third")
	input:feed_chunk("\27[A", false)
	assert_eq(editor:text(), "second")
	input:feed_chunk("\27[B", false)
	assert_eq(editor:text(), "third")
	input:feed_chunk("\27[B", false)
	assert_eq(editor:text(), "")
end)

local function fake_backend(opts)
	opts = opts or {}
	local backend = { output = {}, raw = false, flushes = 0 }
	function backend:is_tty() return true end
	function backend:supports_color() return opts.color == true end
	function backend:size() return opts.width or 60, opts.height or 18 end
	function backend:write(value) self.output[#self.output + 1] = tostring(value or "") end
	function backend:flush() self.flushes = self.flushes + 1 end
	function backend:enable_raw() self.raw = true; return true end
	function backend:disable_raw() self.raw = false; return true end
	return backend
end

test("completed turn rests on elapsed time and one context token number", function()
	local now = 100
	local state = tui.State.new({ clock = function() return now end })
	state:submit("make it better")
	now = 148.4
	state:assistant_complete("Done.", { tokens = 56320 })
	assert_eq(state.completion_summary, "✓ 48s · 56k tokens")
	state.verification = "exit 0"
	state:listen()
	local app = tui.App.new({ backend = fake_backend({ width = 100, height = 24 }), state = state })
	app:render(0.1)
	local forming = app.renderer.previous:plain_line(3)
	if forming:find("✓ 48s · 56k tokens", 1, true) then error("completion summary did not crystallize") end
	now = now + 1
	app:render(0.9)
	local middle = app.renderer.previous:plain_line(3)
	assert_contains(middle, "✓ 48s · 56k tokens")
	if middle:find("exit 0", 1, true) then error("raw exit code displaced the completion summary") end
	state:submit("next request")
	assert_eq(state.completion_summary, nil)
end)

test("submitted request ripples through the current", function()
	local state = tui.State.new({ clock = function() return 10 end })
	state:submit("explain the renderer timing")
	local ripple = state.streams[#state.streams]
	assert_eq(ripple.kind, "request")
	assert_eq(ripple.text, "› explain the renderer timing")
	assert_eq(ripple.turn, 1)
	assert_eq(ripple.duration, 2.6)
end)

test("recent changed files hand off into verification", function()
	local state = tui.State.new({ clock = function() return 10 end })
	state:submit("change and verify")
	state:tool_event(finish("edit-a", "edit", { path = "lua/agent/tui.lua" }, { is_error = false, summary = "replaced 2 lines" }))
	state:tool_event(finish("write-b", "write", { path = "tests/test_tui.lua" }, { is_error = false, summary = "wrote 4 lines" }))
	state:tool_event(start("build", "run", { command = "make test" }))
	assert_eq(#state.handoffs, 2)
	assert_eq(state.handoffs[1].target.id, "build")
	local linked = {}
	for _, handoff in ipairs(state.handoffs) do linked[handoff.source.text] = true end
	assert_eq(linked["tui.lua"], true)
	assert_eq(linked["test_tui.lua"], true)
	local app = tui.App.new({ backend = fake_backend({ width = 100, height = 24 }), state = state })
	app:render(0.2)
	assert_eq(#state.handoffs, 2)
	if state.handoffs[1].age <= 0 then error("handoff pulse did not advance") end
end)

test("parallel tool fragments occupy lanes and move with the current", function()
	local backend = fake_backend({ width = 120, height = 32 })
	local state = tui.State.new({ clock = function() return 10 end })
	state:tool_event(start("tool-a", "grep", { pattern = "on_tool", path = "lua" }))
	state:tool_event(start("tool-b", "run", { command = "make test" }))
	local app = tui.App.new({ backend = backend, state = state })
	app:render(0.1)
	local first_a = app.renderer.previous:plain_line(1)
	local first_b = app.renderer.previous:plain_line(2)
	assert_contains(first_a, "grep · /on_tool/ lua")
	assert_contains(first_b, "run · make test")
	app:render(1.0)
	local second_a = app.renderer.previous:plain_line(1)
	local second_b = app.renderer.previous:plain_line(2)
	if first_a == second_a then error("grep fragment did not flow") end
	if first_b == second_b then error("run fragment did not flow") end
end)

test("animation effects switch without replacing semantic state", function()
	local backend = fake_backend({ width = 100, height = 24 })
	local state = tui.State.new({ clock = function() return 10 end })
	state:tool_event(start("file-a", "read", { path = "lua/agent/core.lua" }))
	local app = tui.App.new({ backend = backend, state = state, effect = "drift" })
	app:render(0.1)
	assert_eq(app.effect, "drift")
	assert_eq(app.flow.mode, "drift")
	assert_eq(#state:active_tools(), 1)
	local ok, err = app:set_effect("filament")
	assert_eq(ok, true, err)
	app:render(0.1)
	assert_eq(app.flow.mode, "filament")
	assert_eq(#state:active_tools(), 1)
	local invalid = app:set_effect("lava-lamp")
	assert_eq(invalid, nil)
	assert_eq(app.effect, "filament")
end)

test("invalid launch effect fails clearly", function()
	local ok, err = pcall(function()
		tui.App.new({ backend = fake_backend(), effect = "lava-lamp" })
	end)
	assert_eq(ok, false)
	assert_contains(err, "unknown TUI effect 'lava-lamp'")
end)

test("hidden streamed edits expose honest model composition progress", function()
	local filter = tui.StreamFilter.new()
	local visible, activity = filter:feed('<tool_call name="edit">\n{"path":"src/main.js","start_line":1}\n' .. string.rep("x", 1400))
	assert_eq(visible, "")
	assert_eq(activity.kind, "tool")
	assert_eq(activity.name, "edit")
	assert_eq(activity.target, "src/main.js")
	assert_contains(activity.status, "model drafting edit · src/main.js")
	assert_contains(activity.status, "1.4k chars")
	local state = tui.State.new()
	state:reviewing({})
	assert_eq(state.model_phase, "model continuing after tools")
	state:model_activity(activity)
	assert_contains(state.model_phase, "drafting edit")
	assert_eq(state.mode, "composing")
end)

test("split tool tags still expose streamed activity", function()
	local filter = tui.StreamFilter.new()
	local visible, activity = filter:feed('<tool_call name="wri')
	assert_eq(visible, "")
	assert_eq(activity, nil)
	visible, activity = filter:feed('te">{"path":"README.md"}\nhello')
	assert_eq(visible, "")
	assert_eq(activity.name, "write")
	visible, activity = filter:feed(" more streamed content")
	assert_eq(activity.target, "README.md")
end)

test("drift is the default animation effect", function()
	local app = tui.App.new({ backend = fake_backend() })
	app:render(0.1)
	assert_eq(app.effect, "drift")
	assert_eq(app.flow.mode, "drift")
end)

test("drift eases through model tool failure and verification states", function()
	local state = tui.State.new({ clock = function() return 10 end })
	local app = tui.App.new({ backend = fake_backend({ width = 100, height = 24 }), state = state })
	state:listen()
	app:render(0.2)
	state:model_activity({ status = "model drafting edit · tui.lua · 2.0k chars" })
	app:render(0.2)
	local composing = app.flow.morph.energy
	if composing <= 0 or composing >= 1 then error("composition transition snapped") end
	if app.palette.r <= 55 or app.palette.r >= 132 then error("composition palette did not ease") end
	state:tool_event(start("edit-a", "edit", { path = "lua/agent/tui.lua" }))
	app:render(0.2)
	local tooling = app.flow.morph.tools
	if tooling <= 0 or tooling >= 1 then error("tool transition snapped") end
	state:tool_event(finish("build-a", "run", { command = "make test" }, { is_error = true, summary = "exit 1" }))
	app:render(0.2)
	local disturbed = app.flow.morph.failure
	if disturbed <= 0 or disturbed >= 1 then error("failure transition snapped") end
	if app.palette.r <= 132 or app.palette.r >= 205 then error("failure palette did not ease") end
	state:tool_event(finish("build-b", "run", { command = "make test" }, { is_error = false, summary = "exit 0" }))
	app:render(0.2)
	if app.flow.morph.resolution <= 0 then error("verification did not begin resolving the drift") end
	if app.flow.morph.failure <= 0 then error("failure disturbance vanished instead of easing out") end
end)

test("filename objects morph and bounce instead of wrapping", function()
	local backend = fake_backend({ width = 120, height = 32 })
	local state = tui.State.new({ clock = function() return 10 end })
	state:tool_event(start("file-a", "edit", { path = "lua/agent/tui.lua" }))
	local app = tui.App.new({ backend = backend, state = state })
	local positions = {}
	for _, dt in ipairs({ 0.1, 1.0, 7.0 }) do
		app:render(dt)
		local line = app.renderer.previous:plain_line(1)
		assert_contains(line, "tui.lua")
		positions[#positions + 1] = assert(line:find("tui.lua", 1, true))
	end
	if positions[2] <= positions[1] then error("filename did not travel outward") end
	if positions[3] >= positions[2] then error("filename wrapped instead of bouncing back") end
end)

test("terminal lifecycle restores after injected failure", function()
	local backend = fake_backend()
	local terminal = lcatui.Terminal.new(backend)
	local renderer = lcatui.Renderer.new(backend, { mode = "inline", synchronized = true })
	local ok, err = tui.with_terminal(terminal, renderer, function() error("injected render failure") end)
	assert_eq(ok, nil)
	assert_contains(err, "injected render failure")
	assert_eq(backend.raw, false)
	local output = table.concat(backend.output)
	assert_contains(output, lcatui.ansi.end_synchronized_update)
	assert_contains(output, lcatui.ansi.show_cursor)
	assert_contains(output, lcatui.ansi.disable_bracketed_paste)
	if output:find(lcatui.ansi.enter_alt_screen, 1, true) then error("compact TUI entered alternate screen") end
	if output:find(lcatui.ansi.leave_alt_screen, 1, true) then error("compact TUI emitted alternate-screen restore") end
end)

test("248x69 terminal keeps a fast fixed nine-row inline strip", function()
	local backend = fake_backend({ width = 248, height = 69, color = true })
	local app = tui.App.new({ backend = backend })
	app.renderer:mount("inline")
	app:render(1 / 30)
	backend.output = {}
	local started = os.clock()
	for _ = 1, 60 do app:render(1 / 30) end
	local elapsed = os.clock() - started
	local bytes = #table.concat(backend.output)
	if elapsed / 60 >= 1 / 30 then
		error(string.format("average frame %.2fms exceeds 33.33ms", elapsed / 60 * 1000))
	end
	if bytes / 60 >= 5000 then
		error(string.format("average frame emits %.0f bytes (budget 4999)", bytes / 60))
	end
	local lower_glyphs = 0
	assert_eq(app.renderer.previous.height, 9)
	for row = 4, 6 do
		for char in app.renderer.previous:plain_line(row):gmatch(utf8.charpattern) do
			if char ~= " " then lower_glyphs = lower_glyphs + 1 end
		end
	end
	if lower_glyphs < 10 then error("animation did not reach the lower strip rows") end
end)

test("frame scheduling advances by elapsed wall time", function()
	local original_gettime = require("socket").gettime
	local now = 10
	require("socket").gettime = function() return now end
	local app = tui.App.new({ backend = fake_backend() })
	local elapsed
	app.render = function(_, dt)
		elapsed = dt
		now = now + 0.020
	end
	now = 10.087
	local ok, err = pcall(function() app:drive_frame() end)
	require("socket").gettime = original_gettime
	if not ok then error(err) end
	if math.abs(elapsed - 0.087) > 0.00001 then
		error("frame ignored elapsed wall time: " .. tostring(elapsed))
	end
end)

test("network pumps do not inject opportunistic frames", function()
	local app = tui.App.new({ backend = fake_backend() })
	local frames = 0
	app.drive_frame = function() frames = frames + 1 end
	app:pump()
	assert_eq(frames, 0)
end)

test("terminal lifecycle restores after cancellation", function()
	local backend = fake_backend()
	local terminal = lcatui.Terminal.new(backend)
	local renderer = lcatui.Renderer.new(backend, { mode = "inline", synchronized = true })
	local state = tui.State.new()
	local ok, err = tui.with_terminal(terminal, renderer, function()
		state:cancel("Ctrl-C")
		return true
	end)
	assert_eq(ok, true, err)
	assert_eq(state.mode, "cancelled")
	assert_eq(backend.raw, false)
	local output = table.concat(backend.output)
	assert_contains(output, lcatui.ansi.show_cursor)
	if output:find(lcatui.ansi.enter_alt_screen, 1, true) then error("cancellation path entered alternate screen") end
end)

test("render caps a tall terminal to six flow rows plus the dock", function()
	local backend = fake_backend()
	local app = tui.App.new({
		backend = backend,
		size_provider = function() return 132, 47 end,
	})
	app:render()
	assert_eq(app.flow_width, 132)
	assert_eq(app.flow_height, 6)
	assert_eq(app.renderer.previous.height, 9)
	assert_contains(app.renderer.previous:plain_line(8), "input ›")
	assert_eq(app.renderer.previous.rows[8][10].style.attrs[1], "reverse")
	for _ = 1, 20 do app.last_frame = app.last_frame - 0.05; app:render() end
	local lower_before = {}
	for row = 4, 6 do lower_before[#lower_before + 1] = app.renderer.previous:plain_line(row) end
	app.last_frame = app.last_frame - 0.05
	app:render()
	local lower_after, lower_glyphs = {}, 0
	for row = 4, 6 do
		local line = app.renderer.previous:plain_line(row)
		lower_after[#lower_after + 1] = line
		for char in line:gmatch(utf8.charpattern) do if char ~= " " then lower_glyphs = lower_glyphs + 1 end end
	end
	if lower_glyphs < 3 then error("lower half of the compact flow field is empty") end
	if table.concat(lower_before, "\n") == table.concat(lower_after, "\n") then error("compact flow field is not moving") end
end)

test("completed assistant response is committed intact above the strip", function()
	local backend = fake_backend({ width = 248, height = 69, color = true })
	local app = tui.App.new({ backend = backend })
	app.renderer:mount("inline")
	app:render(1 / 30)
	backend.output = {}
	app:commit_assistant([[This is a small **Vite + Supabase starter app**. It provides:

- **Email magic-link authentication** via Supabase Auth.
- A simple authenticated **notes app**.
- A `public.notes` table with `id`, `user_id`, `body`, and `inserted_at`.
- **Row-level security** so users can only access their own notes.

The project includes environment setup and build instructions for local development.]])
	local output = table.concat(backend.output)
	assert_contains(output, "lca › This is a small **Vite + Supabase starter app**")
	assert_contains(output, "- **Email magic-link authentication** via Supabase Auth.")
	assert_contains(output, "The project includes environment setup and build instructions")
	assert_eq(app.renderer.inline_height, 0)
	assert_eq(app.renderer.previous, nil)
end)

test("stream window never slices through a UTF-8 bullet", function()
	local state = tui.State.new({ clock = function() return 50 end })
	local payload = "x•" .. string.rep("b", 1198)
	state:model_stream(payload)
	assert_eq(utf8.len(state.assistant_stream) ~= nil, true)
	local app = tui.App.new({ backend = fake_backend({ width = 100, height = 32 }), state = state })
	local ok, err = pcall(function() app:render(1 / 30) end)
	if not ok then error("UTF-8 stream crashed strip rendering: " .. tostring(err)) end
end)

test("submitted input clears the dock and is acknowledged before work", function()
	local backend = fake_backend({ width = 100, height = 32 })
	local app = tui.App.new({ backend = backend })
	app.editor:set("explain this project")
	local submitted = app.editor:submit()
	app.state:submit(submitted)
	app.busy = true
	app.renderer:mount("inline")
	app:commit_user(submitted)
	app:render(1 / 30)
	local buffer = app.renderer.previous
	assert_contains(table.concat(backend.output), "you › explain this project")
	if buffer:plain_line(8):find("explain this project", 1, true) then
		error("submitted text remained in the input dock")
	end
	assert_eq(buffer.rows[8][10].style.attrs[1], "reverse")
	assert_contains(buffer:plain_line(9), "working")
end)

test("expired notices disappear from the compact status row", function()
	local now = 40
	local state = tui.State.new({ clock = function() return now end })
	state.prompt = "whats this project"
	state:assistant_complete("This is the centered assistant response.")
	state:notice("session cleared and saved to .lca-session.json")
	now = 49
	state:listen()
	local app = tui.App.new({ backend = fake_backend({ width = 100, height = 32 }), state = state })
	app:render(1 / 30)
	local status = app.renderer.previous:plain_line(9)
	assert_contains(status, "LCA · listening")
	if status:find("session cleared", 1, true) then error("expired notice remained in status row") end
end)

io.write("\n" .. tostring(passed) .. " passed, " .. tostring(failed) .. " failed\n")
if failed > 0 then os.exit(1) end
