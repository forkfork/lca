#!/usr/bin/env lua

local script_dir = arg[0]:match("^(.*)/[^/]+$") or "."
local project_dir = script_dir .. "/.."
package.path = project_dir .. "/lua/?.lua;" .. project_dir .. "/lua/?/init.lua;" .. package.path
pcall(require, "luarocks.loader")

local lcatui = require("agent.ui")
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

test("active tools survive history pressure and all receive cancellation", function()
	local state = tui.State.new({ clock = function() return 10 end })
	local active = {}
	for index = 1, 24 do
		active[index] = state:tool_event(start("active-" .. index, "read", { path = "README.md" }))
	end
	for index = 1, 30 do
		state:tool_event(finish("done-" .. index, "ls", {}, { summary = "done" }))
	end
	assert_eq(#state:active_tools(), 24)
	assert_eq(state:active_tools()[1], active[1])
	assert_eq(#state.tools, 42, "retain all active tools and 18 completed tools")
	assert_eq(state.tools_by_id["done-1"], nil)
	state:tool_event({ phase = "progress", call_id = "active-1", name = "read", progress = { elapsed_ms = 2000 } })
	assert_eq(active[1].elapsed_ms, 2000)
	state:tool_event(finish("active-1", "read", { path = "README.md" }, { summary = "done" }))
	assert_eq(active[1].status, "ok")
	assert_eq(#state:active_tools(), 23)
	state:cancel("cancelled")
	assert_eq(#state:active_tools(), 0)
	for index = 2, 24 do assert_eq(active[index].status, "cancelled") end
	assert_eq(#state.tools, 18)
	assert_eq(next(state.tool_queues), nil)
end)

test("tool identity wins over argument fallback and queues release completed tools", function()
	local state = tui.State.new({ clock = function() return 10 end })
	local args = { path = "README.md" }
	local first = state:tool_event(start("first", "read", args))
	local second = state:tool_event(start("second", "read", args))
	state:tool_event(finish("unknown", "read", args, { summary = "done" }))
	assert_eq(first.status, "active", "unknown IDs must not resolve another call")
	state:tool_event(finish("first", "read", {}, { summary = "done" }))
	assert_eq(first.status, "ok")
	state:tool_event(finish(nil, "read", args, { summary = "done" }))
	assert_eq(second.status, "ok", "fallback must skip the completed call even when its result omitted args")
	assert_eq(next(state.tool_queues), nil)
end)

test("realistic failure recovery settles into listening state", function()
	local tick = 0
	local state = tui.State.new({ clock = function() tick = tick + 1; return tick end })
	replay_supabase_sequence(state)
	assert_eq(state.mode, "listening")
	assert_eq(state.failure, nil)
	assert_eq(state.verification, nil)
	assert_eq(state.proof, 0)
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

test("default stdin reader keeps the first arrow sequence in one unbuffered chunk", function()
	local called
	local reader = tui._stdin_chunk_reader(function(fd, bytes, offset)
		called = { fd = fd, bytes = bytes, offset = offset }
		return "\27[A"
	end)
	local editor = tui.Editor.new({ "previous prompt" })
	local input = tui.Input.new(editor)
	input:feed_chunk(reader(), false)
	assert_eq(called.fd, 0)
	assert_eq(called.bytes, 128)
	assert_eq(called.offset, -1)
	assert_eq(editor:text(), "previous prompt")
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

test("private recording round-trips real state events and detaches on stop", function()
	local Recording = require("agent.tui_recording")
	local Replay = require("agent.tui_replay")
	local uv = require("luv")
	local path = os.tmpname(); os.remove(path)
	local now = 20
	local state = tui.State.new({ clock = function() return now end })
	local original = state.tool_event
	local recorder = assert(Recording.open(path, { clock = function() return now end, effect = "drift" })):attach(state)
	assert_eq(uv.fs_stat(path).mode & 511, 384, "capture must be owner-only")
	assert_eq(Recording.open(path), nil, "existing capture must not be overwritten")
	state:submit("capture this")
	now = 20.5; state:model_waiting("waiting for model")
	state:model_activity({ status = "thinking" })
	state:tool_event(start("a", "read", { path = "README.md" }))
	state:tool_event(start("b", "run", { command = "never execute this" }))
	now = 21
	state:tool_event(finish("b", "run", {}, { summary = "failed", is_error = true, content = "diagnostic" }))
	state:tool_event(finish("a", "read", {}, { summary = "read", content = "source" }))
	state:reviewing({ status = "reviewing results" })
	state:model_stream("answer")
	state:assistant_complete("done", { tokens = 123 })
	now = 22; state:submit("cancel this"); state:cancel("cancelled")
	assert(recorder:close())
	assert(recorder:close())
	assert_eq(state.tool_event, original)
	local fixture = Replay.load(path)
	assert_eq(fixture.effect, "drift")
	assert_eq(fixture.events[1].at, 0)
	assert_eq(fixture.events[2].at, .5)
	local player = Replay.new(fixture, { backend = fake_backend() })
	while not player.finished do player:step() end
	assert_eq(player.app.state.mode, state.mode)
	assert_eq(player.app.state.tools_by_id.b.result_detail, state.tools_by_id.b.result_detail)
	assert_eq(player.app.state.tools_by_id.a.status, "ok")
	assert_eq(#player.app.submitted, 0)
	os.remove(path)
	local app = tui.App.new({ backend = fake_backend(), effect = "drift" })
	assert(app:start_recording(path))
	app.state:submit("through app")
	assert(app:stop_recording())
	assert_eq(Replay.load(path).events[1].text, "through app")
	os.remove(path)
end)

test("recording auto-names private captures without overwriting", function()
	local uv = require("luv")
	local Recording = require("agent.tui_recording")
	local Replay = require("agent.tui_replay")
	local root = os.tmpname(); os.remove(root)
	assert(uv.fs_mkdir(root, 448))
	local directory = root .. "/replays"
	local paths = {}
	local ok, err = xpcall(function()
		for index = 1, 2 do
			local recording = assert(Recording.open(nil, { directory = directory }))
			local path = recording.path
			paths[#paths + 1] = path
			assert_eq(path:sub(1, #directory + 1), directory .. "/")
			assert(path:sub(#directory + 2):match("^[%w%-]+%.jsonl$"))
			assert_eq(uv.fs_stat(path).mode & 511, 384)
			recording:record("submit", { text = "capture " .. index })
			assert(recording:close())
		end
		assert(paths[1] ~= paths[2])
		assert_eq(Replay.load(paths[1]).events[1].text, "capture 1")
		assert_eq(Replay.load(paths[2]).events[1].text, "capture 2")
		assert_eq(uv.fs_stat(directory).mode & 511, 448)
		for _, path in ipairs(paths) do assert(os.remove(path)) end
		assert(uv.fs_rmdir(directory))
		local file = assert(io.open(directory, "w")); file:close()
		assert_eq(Recording.open(nil, { directory = directory }), nil)
		assert(os.remove(directory))
	end, debug.traceback)
	uv.fs_rmdir(root)
	assert(ok, err)
end)

test("recording limits and interrupted files stay replayable without breaking state", function()
	local Recording = require("agent.tui_recording")
	local Replay = require("agent.tui_replay")
	local path = os.tmpname(); os.remove(path)
	local warned
	local recorder = assert(Recording.open(path, { limit = 600, on_error = function(err) warned = err end }))
	local state = tui.State.new()
	recorder:attach(state)
	state:submit("small")
	state:model_stream(string.rep("x", 800))
	assert_contains(warned, "size limit")
	assert_eq(recorder.fd, nil)
	assert_eq(#state.assistant_stream, 800, "recording failure must not interrupt live state")
	local fixture = Replay.load(path)
	assert_eq(#fixture.events, 1)
	assert_contains(fixture.recording_error, "size limit")
	local file = assert(io.open(path, "r")); local saved = file:read("*a"); file:close()
	-- Remove footer and simulate death during the next append.
	saved = saved:match("^(.*\n)[^\n]+\n$")
	file = assert(io.open(path, "w")); file:write(saved, '{"at":'); file:close()
	assert_eq(#Replay.load(path).events, 1)
	file = assert(io.open(path, "a")); file:write("\n"); file:close()
	assert_eq(pcall(Replay.load, path), false, "malformed committed lines must be rejected")
	os.remove(path)
	assert_eq(Recording.open(path .. "/missing"), nil)
end)
test("tool inspector preserves drafts, follows identity and exposes bounded results", function()
	local backend = fake_backend({ width = 80 })
	local app = tui.App.new({ backend = backend, effect = "drift" })
	app.input = tui.Input.new(app.editor)
	app.editor:set("keep my draft")
	app.editor.cursor = 4
	app.state:tool_event(start("a", "read", { path = "README.md" }))
	app.busy = true
	app:feed_input("\20")
	app:render(0)
	assert_contains(app.renderer.previous:plain_line(1), "TOOLS")
	assert_eq(app.inspector_id, "a")
	app.state:tool_event(start("b", "run", { command = "make test" }))
	app.state:tool_event(finish("a", "read", {}, { is_error = true, summary = "failed", content = "diagnostic\n" .. string.rep("detail\n", 4000) }))
	app:render(0)
	assert_eq(app.inspector_id, "a")
	assert_contains(app.state.tools_by_id.a.args_detail, "README.md")
	assert(#app.state.tools_by_id.a.result_detail < 16010)
	app:feed_input("\27[B\27[B\r")
	app:render(0)
	assert(app.inspector_scroll > 0)
	assert_eq(app.editor:text(), "keep my draft")
	assert_eq(app.editor.cursor, 4)
	assert_eq(#app.submitted, 0)
	app:feed_input("\9")
	app:render(0)
	assert_eq(app.inspector_id, "b")
	assert_eq(app.inspector_scroll, 0)
	app:feed_input("\20")
	assert_eq(app.inspector_open, false)
	assert_eq(app.editor:text(), "keep my draft")
	app:feed_input("\27[200~\20\27[201~")
	assert_eq(app.inspector_open, false, "pasted controls must not open inspector")
end)

test("replay transport is deterministic and never submits typed work", function()
	local Replay = require("agent.tui_replay")
	local fixture = Replay.load(project_dir .. "/tests/fixtures/tui-replay.json")
	local function player() return Replay.new(fixture, { backend = fake_backend({ width = 80 }) }) end
	local a, b = player(), player()
	for _ = 1, 50 do a:update(0.04) end
	for _ = 1, 10 do b:update(0.2) end
	a:draw(); b:draw()
	assert_eq(a.now, b.now)
	for row = 1, a.app.renderer.previous.height do
		assert_eq(a.app.renderer.previous:plain_line(row), b.app.renderer.previous:plain_line(row))
	end
	assert_eq(a.app.state.tools_by_id["read-a"].status, "ok")
	a:feed_input("draft\r\16")
	local now = a.now
	a:update(0.2); a:draw()
	assert_eq(a.now, now)
	assert_eq(a.app.editor:text(), "draft")
	assert_eq(#a.app.submitted, 0)
	a:feed_input("\14")
	assert(a.now > now)
	a:feed_input("\6\18")
	assert_eq(a.now, 0)
	assert_eq(a.app.editor:text(), "draft")
	assert_eq(#a.app.state.tools, 0)
	a:feed_input("\16")
	while not a.finished do a:update(0.2) end
	assert_eq(a.app.state.mode, "cancelled")
	assert_eq(#a.app.state:active_tools(), 0)
	assert_eq(a.app.state.tools_by_id["cancel-g"].status, "cancelled")
	a:feed_input("\3")
	assert_eq(a.app.exit_requested, true)
	assert_eq(pcall(Replay.new, { events = { { at = 2, kind = "submit" }, { at = 1, kind = "cancel" } } }), false)
	assert_eq(pcall(Replay.new, { events = { { at = 0, kind = "execute" } } }), false)
end)
test("repainting does not advance or expire animation and semantic state", function()
	local now = 10
	local state = tui.State.new({ clock = function() return now end })
	local app = tui.App.new({ backend = fake_backend(), state = state, effect = "filament" })
	state:submit("change a file")
	state:tool_event(start("edit", "edit", { path = "README.md" }))
	state:tool_event(finish("edit", "edit", { path = "README.md" }, { summary = "changed" }))
	state:tool_event(start("run", "run", { command = "pwd" }))
	state:assistant_complete("done", { elapsed = 1, tokens = 100 })
	app:advance(0.1)
	app:set_effect("ink")
	app:advance(0.1)
	local stream, handoff, transfer = state.streams[1], state.handoffs[1], state.transfers[1]
	local stream_age, handoff_age, transfer_age = stream.age, handoff.age, transfer.age
	local wheel, flow_time, flow_mode = state.flywheel, app.flow.time, app.flow.mode
	local transition_age, motion_scale = app.effect_transition_age, app.motion_scale
	app:draw()
	local function screen_text()
		local lines = {}
		for row = 1, app.renderer.previous.height do lines[row] = app.renderer.previous:plain_line(row) end
		return table.concat(lines, "\n")
	end
	local painted = screen_text()
	now = 30
	assert_eq(state:flywheel_visual(now), nil)
	assert_eq(state.flywheel, wheel, "visual queries must not expire state")
	app.focus_path = "missing"
	app.editor:set("draft")
	for _ = 1, 3 do app:draw() end
	assert_eq(screen_text(), painted, "repaint must use the prepared clock and input")
	assert_eq(stream.age, stream_age)
	assert_eq(handoff.age, handoff_age)
	assert_eq(transfer.age, transfer_age)
	assert_eq(state.flywheel, wheel)
	assert_eq(app.flow.time, flow_time)
	assert_eq(app.flow.mode, flow_mode, "painting a dissolve must not switch simulation mode")
	assert_eq(app.effect_transition_age, transition_age)
	assert_eq(app.motion_scale, motion_scale)
	assert_eq(app.focus_path, "missing")
	assert_eq(state.input, "")
	app:advance(10)
	assert_eq(state.flywheel, nil)
	assert_eq(#state.handoffs, 0)
	assert_eq(#state.transfers, 0)
	assert_eq(app.effect_transition_from, nil)
	assert_eq(app.focus_path, nil)
	assert_eq(state.input, "draft")
end)

test("successful commands do not overlay the river with raw results", function()
	local now = 10
	local state = tui.State.new({ clock = function() return now end })
	state:submit("run the checks")
	state:tool_event(start("check", "run", { command = "make test" }))
	state:tool_event(finish("check", "run", { command = "make test" }, { is_error = false, summary = "exit 0" }))
	assert_eq(state.verification, nil)
	assert_eq(state.verification_label, nil)
	local app = tui.App.new({ backend = fake_backend({ width = 100, height = 24 }), state = state })
	for _, elapsed in ipairs({ 0.1, 1, 10 }) do
		now = now + elapsed
		app:render(elapsed)
		for row = 2, 5 do
			if app.renderer.previous:plain_line(row):find("◆ exit 0", 1, true) then
				error("successful command result overlaid the river")
			end
		end
	end
end)

test("failed commands keep diagnostics without raw exit overlays", function()
	for _, summary in ipairs({ "exit 1", "exit 128", "exit 1, truncated" }) do
		local now = 10
		local state = tui.State.new({ clock = function() return now end })
		state:submit("run the checks")
		state:tool_event(start("check", "run", { command = "make test" }))
		state:tool_event(finish("check", "run", { command = "make test" }, {
			is_error = true, summary = summary, content = "command diagnostics",
		}))
		assert_eq(state.failure, summary)
		assert_eq(state.tools_by_id.check.result, summary)
		local app = tui.App.new({ backend = fake_backend({ width = 100, height = 24 }), state = state })
		for _, elapsed in ipairs({ 0.1, 1, 10 }) do
			now = now + elapsed
			app:render(elapsed)
			assert_eq(app.celebration_active, false)
			for row = 2, 5 do
				if app.renderer.previous:plain_line(row):find("× exit", 1, true) then
					error("failed command result overlaid the river")
				end
			end
		end
	end
end)
test("completed turn rests on elapsed time and one context token number", function()
	local now = 100
	local state = tui.State.new({ clock = function() return now end })
	state:submit("make it better")
	now = 148.4
	state:assistant_complete("Done.", { tokens = 56320, cache_percent = 95.7 })
	assert_eq(state.completion_summary, "✓ 48s · 56k tokens · 96% cached")
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
	assert_eq(app.celebration_active, true)
	local burst_frame = {}
	for row = 2, 5 do burst_frame[#burst_frame + 1] = app.renderer.previous:plain_line(row) end
	local burst = table.concat(burst_frame, "\n")
	if not burst:find("✦", 1, true) and not burst:find("⋆", 1, true) and not burst:find("◆", 1, true) then
		error("completion pop did not emit a visible spark")
	end
	now = now + 1
	app:render(1.0)
	assert_eq(app.celebration_active, false)
	assert_contains(app.renderer.previous:plain_line(3), "✓ 48s · 56k tokens")
	state:submit("next request")
	assert_eq(state.completion_summary, nil)
end)

test("completion cache percentage distinguishes zero from unavailable", function()
	local now = 10
	local state = tui.State.new({ clock = function() return now end })
	state:submit("first request")
	now = 12
	state:assistant_complete("Done.", { tokens = 8000, cache_percent = 0 })
	assert_eq(state.completion_summary, "✓ 2s · 8k tokens · 0% cached")
	state:submit("second request")
	now = 14
	state:assistant_complete("Done.", { tokens = 8000 })
	assert_eq(state.completion_summary, "✓ 2s · 8k tokens")
end)

test("minute completion summary keeps its duration units", function()
	local state = tui.State.new({ clock = function() return 108 end })
	state:submit("research it")
	state:assistant_complete("Done.", { started_at = 0, tokens = 48858, cache_percent = 7 })
	assert_eq(state.completion_summary, "✓ 1m 48s · 49k tokens · 7% cached")
end)

test("failed turns do not trigger the completion pop", function()
	local now = 20
	local state = tui.State.new({ clock = function() return now end })
	state:submit("run the build")
	state:assistant_complete("The build failed.", { tokens = 2048 })
	state.failure = "build failed"
	now = now + 1
	local app = tui.App.new({ backend = fake_backend({ width = 100, height = 24 }), state = state })
	app:render(1.0)
	assert_eq(app.celebration_active, false)
	assert_contains(app.renderer.previous:plain_line(3), "build failed")
end)

test("stale file edits become a real recovery story", function()
	local now = 30
	local state = tui.State.new({ clock = function() return now end })
	state:submit("add archive support")
	local stale_args = { path = "src/main.js", start_line = 103, end_line = 109 }
	state:tool_event(start("edit-stale", "edit", stale_args))
	state:tool_event(finish("edit-stale", "edit", stale_args, {
		is_error = true,
		summary = "stale tag",
		content = "start_tag mismatch at line 103 — re-read the file",
	}))
	local recovery = state.recoveries["src/main.js"]
	assert_eq(recovery.phase, "failed")
	assert_eq(recovery.reason, "target changed")
	assert_eq(recovery.stream.duration, nil)
	assert_contains(recovery.stream.text, "main.js · target changed")
	state:tool_event(start("other-edit", "edit", { path = "src/main.js", start_line = 17, end_line = 20 }))
	state:tool_event(finish("other-edit", "edit", { path = "src/main.js", start_line = 17, end_line = 20 }, {
		is_error = false, summary = "replaced 4 lines",
	}))
	assert_eq(state.recoveries["src/main.js"], recovery)
	assert_eq(recovery.phase, "failed")

	-- Successful reads do not require a manufactured start event; their real
	-- result is enough to advance the recovery narrative.
	state:tool_event(finish("read-fresh", "read", { path = "src/main.js" }, {
		is_error = false, summary = "220 lines",
	}))
	assert_eq(recovery.phase, "refreshed")
	assert_eq(state.streams[#state.streams].kind, "file_refresh")
	assert_contains(state.streams[#state.streams].text, "source refreshed")

	local retry_args = { path = "src/main.js", start_line = 105, end_line = 111 }
	state:tool_event(start("edit-retry", "edit", retry_args))
	assert_eq(recovery.phase, "retrying")
	local app = tui.App.new({ backend = fake_backend({ width = 100, height = 24 }), state = state })
	app:render(0.1)
	assert_contains(app.renderer.previous:plain_line(1), "retrying edit")

	state:tool_event(finish("edit-retry", "edit", retry_args, {
		is_error = false, summary = "replaced 7 lines",
	}))
	assert_eq(state.recoveries["src/main.js"], nil)
	assert_eq(recovery.stream.kind, "file_resolving")
	assert_contains(recovery.stream.text, "main.js · updated")
	app:render(0.2)
	assert_contains(app.renderer.previous:plain_line(1), "main.js · recovered")

	now = now + 3
	state:listen()
	app:render(0.2)
	local quiet_divider = app.renderer.previous:plain_line(1)
	if quiet_divider:find("main.js", 1, true) then error("resolved recovery lingered in the quiet divider") end
end)

test("read failures stay transient rather than opening mutation recovery", function()
	local state = tui.State.new({ clock = function() return 10 end })
	state:tool_event(finish("missing-read", "read", { path = "optional.md" }, {
		is_error = true, summary = "not found", content = "No such file",
	}))
	assert_eq(next(state.recoveries), nil)
	local stream = state.streams[#state.streams]
	assert_eq(stream.kind, "file_error")
	assert_eq(stream.duration, 5.2)
	assert_contains(stream.text, "optional.md · file missing")
end)

test("living divider ignores the mechanical plan and carries a destination", function()
	local state = tui.State.new({ clock = function() return 10 end })
	local app = tui.App.new({ backend = fake_backend({ width = 100, height = 24 }), state = state })
	app:render(0.1)
	local quiet = app.renderer.previous:plain_line(1)
	if quiet:find("waiting", 1, true) or quiet:find("listening", 1, true) then
		error("quiet divider repeated dock status")
	end
	state:submit("improve the interaction")
	app:render(0.1)
	local waiting_divider = app.renderer.previous:plain_line(1)
	if waiting_divider:find("model waiting", 1, true) then
		error("divider duplicated the generic phase shown in the current")
	end
	assert_contains(app.renderer.previous:plain_line(3), "model waiting")
	state:tool_event(start("plan", "update_plan", { plan = {
		{ step = "Trace the recovery path", status = "completed" },
		{ step = "Make failures heal visibly", status = "in_progress" },
	} }))
	app:render(0.1)
	if app.renderer.previous:plain_line(1):find("Make failures heal visibly", 1, true) then
		error("mechanical plan leaked into the live trajectory")
	end
	state:tool_event(start("journey", "update_plan", {
		journey = {
			destination = "failures that visibly heal",
			approach = "recovery state attached to real file events",
			proof = "a stale edit refreshes and succeeds",
		},
		plan = { { step = "Build recovery", status = "in_progress" } },
	}))
	app:render(0.1)
	assert_eq(state:divider_status(10), nil)
	assert_eq(app.renderer.previous:plain_line(1):find("failures that visibly heal", 1, true), nil)
end)

test("divider does not infer a journey from planning, edits, or verification", function()
	local state = tui.State.new({ clock = function() return 10 end })
	local app = tui.App.new({ backend = fake_backend({ width = 100, height = 24 }), state = state })
	state:submit("make a change")
	local events = {
		start("plan", "update_plan", { journey = {
			destination = "a reliable change", approach = "inspect and edit", proof = "tests pass",
		}, plan = { { step = "Implement change", status = "in_progress" } } }),
		finish("read", "read", { path = "example.lua" }, { is_error = false, summary = "source" }),
		finish("write", "write", { path = "example.lua" }, { is_error = false, summary = "written" }),
		start("test", "run", { command = "make test" }),
		finish("test", "run", { command = "make test" }, { is_error = false, summary = "exit 0" }),
		finish("reread", "read", { path = "example.lua" }, { is_error = false, summary = "source" }),
	}
	for _, event in ipairs(events) do
		state:tool_event(event)
		app:render(0.2)
		local label, kind = state:divider_status(10)
		assert_eq(label, nil)
		assert_eq(kind, "quiet")
		local divider = app.renderer.previous:plain_line(1)
		assert_eq(divider:find("◉", 1, true), nil)
		assert_eq(divider:find("a reliable change", 1, true), nil)
	end
	assert_eq(state.verification_label, nil)
	assert_eq(state.plan[1].step, "Implement change")
	state:assistant_complete("Done.", { tokens = 1200 })
	assert_eq(state:divider_status(10), nil)
end)

test("typing lowers visual metabolism without slowing event time", function()
	local state = tui.State.new({ clock = function() return 10 end })
	state:submit("inspect the renderer")
	state:tool_event(finish("read", "read", { path = "lua/agent/tui.lua" }, {
		is_error = false, summary = "400 lines",
	}))
	local stream = state.streams[#state.streams]
	local app = tui.App.new({ backend = fake_backend({ width = 100, height = 24 }), state = state })
	app:render(0.1)
	local age_before, motion_before = stream.age, stream.motion_age
	app.editor:set("my follow-up")
	app:render(1.0)
	if app.motion_scale >= 0.36 then error("typing did not calm the organism") end
	if math.abs((stream.age - age_before) - 1.0) > 0.0001 then error("typing slowed semantic event time") end
	if stream.motion_age - motion_before >= 0.4 then error("typing did not slow visual travel") end
	app.editor:set("")
	local resumed_before = stream.motion_age
	app:render(1.0)
	if app.motion_scale <= 0.94 then error("organism did not wake after typing cleared") end
	if stream.motion_age - resumed_before <= 0.9 then error("visual travel did not resume") end
end)

test("unresolved file failures cannot trigger a success celebration", function()
	local now = 10
	local state = tui.State.new({ clock = function() return now end })
	state:submit("change the file")
	state:tool_event(start("bad-edit", "edit", { path = "src/main.js" }))
	state:tool_event(finish("bad-edit", "edit", { path = "src/main.js" }, {
		is_error = true, summary = "stale tag", content = "re-read the file",
	}))
	now = 20
	state:assistant_complete("I could not apply that edit.", { tokens = 4096 })
	assert_eq(state.completion_summary, nil)
	local app = tui.App.new({ backend = fake_backend({ width = 100, height = 24 }), state = state })
	app:render(1.0)
	assert_eq(app.celebration_active, false)
	assert_contains(app.renderer.previous:plain_line(1), "main.js · target changed")
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

test("working set remembers file state and real causal direction across a turn", function()
	local now = 10
	local state = tui.State.new({ clock = function() return now end })
	state:submit("inspect change and verify")
	state:tool_event(start("read-a", "read", { path = "lua/agent/core.lua" }))
	local memory = state.file_memory["lua/agent/core.lua"]
	assert_eq(memory.state, "reading")
	assert_eq(state.transfers[#state.transfers].from.kind, "file")
	assert_eq(state.transfers[#state.transfers].to.kind, "core")
	state:tool_event(finish("read-a", "read", { path = "lua/agent/core.lua" }, { is_error = false, summary = "120 lines" }))
	assert_eq(memory.state, "read")
	state:tool_event(start("edit-a", "edit", { path = "lua/agent/core.lua" }))
	assert_eq(memory.state, "editing")
	assert_eq(state.transfers[#state.transfers].from.kind, "core")
	assert_eq(state.transfers[#state.transfers].to.kind, "file")
	state:tool_event(finish("edit-a", "edit", { path = "lua/agent/core.lua" }, { is_error = false, summary = "replaced 4 lines" }))
	assert_eq(memory.state, "changed")
	state:tool_event(start("test-a", "run", { command = "make test" }))
	state:tool_event(finish("test-a", "run", { command = "make test" }, { is_error = false, summary = "exit 0" }))
	assert_eq(memory.state, "changed")
	assert_eq(state.verification_label, nil)
	assert_eq(state.proof, 0)
	for _, transfer in ipairs(state.transfers) do
		if transfer.kind == "proof" then error("command success certified a file") end
	end
	state:listen()
	assert_eq(state:working_files()[1], memory)
	now = 20
	state:submit("touch it again")
	assert_eq(state.file_memory["lua/agent/core.lua"], memory)
end)

test("working-set scar survives refresh and heals only after mutation retry", function()
	local state = tui.State.new({ clock = function() return 10 end })
	state:tool_event(finish("edit-fail", "edit", { path = "src/main.js" }, {
		is_error = true, summary = "stale tag",
	}))
	local memory = state.file_memory["src/main.js"]
	assert_eq(memory.state, "failed")
	assert_eq(memory.scar, true)
	state:tool_event(finish("refresh", "read", { path = "src/main.js" }, {
		is_error = false, summary = "70 lines",
	}))
	assert_eq(memory.state, "read")
	assert_eq(memory.scar, true)
	state:tool_event(finish("retry", "edit", { path = "src/main.js" }, {
		is_error = false, summary = "replaced 10 lines",
	}))
	assert_eq(memory.state, "changed")
	assert_eq(memory.scar, false)
end)

test("turn harvest reports files time and usage without inferred verification", function()
	local state = tui.State.new({ clock = function() return 100 end })
	state:submit("change two files")
	state:tool_event(finish("edit-a", "edit", { path = "lua/a.lua" }, { is_error = false, summary = "replaced 2 lines" }))
	state:tool_event(finish("write-b", "write", { path = "lua/b.lua" }, { is_error = false, summary = "wrote 20 lines" }))
	state:tool_event(finish("build", "run", { command = "make check" }, { is_error = false, summary = "exit 0" }))
	state:assistant_complete("done", { elapsed = 12, tokens = 20000, cache_percent = 50 })
	assert_eq(state.completion_summary, "✓ 2 files · 12s · 20k tokens · 50% cached")
end)

test("commands never certify changes based on their name or exit status", function()
	for _, name in ipairs({ "run", "shell" }) do
		for _, command in ipairs({ "pwd", "echo tests passed", "cat build.log", "make test", "make check" }) do
			local state = tui.State.new({ clock = function() return 100 end })
			state:submit("change then inspect")
			state:tool_event(finish("edit", "edit", { path = "lua/a.lua" }, { is_error = false }))
			state:tool_event(finish("failed", name, { command = command }, { is_error = true, summary = "exit 1" }))
			state:tool_event(finish("deferred", name, { command = command }, { ui_state = "deferred" }))
			assert_eq(state.failure, "exit 1", "deferred work must not clear failure")
			state:tool_event(finish("success", name, { command = command }, { is_error = false, summary = "exit 0" }))
			assert_eq(state.tools_by_id.success.status, "ok")
			assert_eq(state.failure, nil)
			assert_eq(state.verification, nil)
			assert_eq(state.verification_label, nil)
			assert_eq(state.proof, 0)
			assert_eq(state.file_memory["lua/a.lua"].state, "changed")
			assert_eq(state.file_memory["lua/a.lua"].verified_at, nil)
			state:assistant_complete("done", { elapsed = 8, tokens = 10000 })
			assert_eq(state.completion_summary, "✓ 1 file · 8s · 10k tokens")
		end
	end
end)

test("empty-dock Tab focuses recent files and typing dismisses the lens", function()
	local now = 20
	local state = tui.State.new({ clock = function() return now end })
	state:tool_event(finish("read-a", "read", { path = "lua/a.lua" }, { is_error = false, summary = "12 lines" }))
	now = 22
	state:tool_event(finish("edit-b", "edit", { path = "lua/b.lua" }, { is_error = false, summary = "replaced 3 lines" }))
	local app = tui.App.new({ backend = fake_backend({ width = 120, height = 24 }), state = state })
	local input = tui.Input.new(app.editor)
	app:_handle_action(input:feed("\t", false))
	assert_eq(app.focus_path, "lua/b.lua")
	app:render(0.1)
	assert_contains(app.renderer.previous:plain_line(8), "focus 1/2 · edit · b.lua · changed")
	app:_handle_action(input:feed("\t", false))
	assert_eq(app.focus_path, "lua/a.lua")
	app:_handle_action(input:feed("\t", false))
	assert_eq(app.focus_path, nil)
	input:feed("x", false)
	app.focus_path = "lua/b.lua"
	app:render(0.1)
	assert_eq(app.focus_path, nil)
end)

test("mechanical plan spores stay out of the destination membrane", function()
	local state = tui.State.new({ clock = function() return 10 end })
	state:tool_event(start("plan", "update_plan", { plan = {
		{ step = "Inspect the organism", status = "completed" },
		{ step = "Grow working memory", status = "in_progress" },
		{ step = "Verify the experience", status = "pending" },
	} }))
	local app = tui.App.new({ backend = fake_backend({ width = 120, height = 24 }), state = state })
	app:render(0.1)
	local divider = app.renderer.previous:plain_line(1)
	if divider:find("●", 1, true) or divider:find("◉", 1, true) or divider:find("○", 1, true) then
		error("mechanical plan status glyphs leaked into the destination membrane")
	end
	if divider:find("Grow working memory", 1, true) then error("mechanical plan label leaked into divider") end
end)

test("parallel tool fragments occupy lanes and move with the current", function()
	local backend = fake_backend({ width = 120, height = 32 })
	local state = tui.State.new({ clock = function() return 10 end })
	state:tool_event(start("tool-a", "grep", { pattern = "on_tool", path = "lua" }))
	state:tool_event(start("tool-b", "run", { command = "make test" }))
	local app = tui.App.new({ backend = backend, state = state })
	app:render(0.1)
	local first = {}
	for row = 2, 5 do first[#first + 1] = app.renderer.previous:plain_line(row) end
	local first_frame = table.concat(first, "\n")
	assert_contains(first_frame, "grep · /on_tool/ lua")
	assert_contains(first_frame, "run · make test")
	app:render(1.0)
	local second = {}
	for row = 2, 5 do second[#second + 1] = app.renderer.previous:plain_line(row) end
	if first_frame == table.concat(second, "\n") then error("tool personalities did not move") end
end)

test("tool stage keeps the full runtime batch named and shows outcomes", function()
	local now = 20
	local state = tui.State.new({ clock = function() return now end })
	local specs = {
		{ "ls", { path = "." } },
		{ "find", { path = "lua" } },
		{ "grep", { pattern = "tool_event", path = "lua" } },
		{ "read", { path = "README.md" } },
		{ "edit", { path = "lua/agent/tui.lua" } },
		{ "write", { path = "notes.txt" } },
		{ "run", { command = "make test" } },
	}
	for index, spec in ipairs(specs) do
		state:tool_event({
			type = "tool", phase = "start", call_id = "batch-4-" .. index,
			batch_id = 4, model_index = index, name = spec[1], args = spec[2],
		})
	end
	local app = tui.App.new({
		backend = fake_backend({ width = 160, height = 24 }), state = state, tool_stage = true,
	})
	now = 20.5
	app:render(0.2)
	local rows = {}
	for row = 2, 5 do rows[#rows + 1] = app.renderer.previous:plain_line(row) end
	local frame = table.concat(rows, "\n")
	for index, spec in ipairs(specs) do
		assert_contains(frame, string.format("%02d", index), "stage hid tool number " .. index)
		assert_contains(frame, spec[1], "stage hid tool " .. spec[1])
	end
	assert_eq(#app.staged_tools, #specs)
	assert_eq(app.staged_batch_id, 4)

	state:tool_event({
		type = "tool", call_id = "batch-4-4", batch_id = 4, model_index = 4,
		name = "read", args = { path = "README.md" }, duration_ms = 740,
		result = { is_error = false, summary = "20 lines" },
	})
	state:tool_event({
		type = "tool", call_id = "batch-4-5", batch_id = 4, model_index = 5,
		name = "edit", args = { path = "lua/agent/tui.lua" }, duration_ms = 910,
		result = { is_error = true, summary = "stale source" },
	})
	now = 21.1
	app:render(0.2)
	rows = {}
	for row = 2, 5 do rows[#rows + 1] = app.renderer.previous:plain_line(row) end
	frame = table.concat(rows, "\n")
	assert_contains(frame, "✓ read", "resolved tool did not land visibly")
	assert_contains(frame, "× edit", "failed tool did not land visibly")
	assert_contains(frame, "740ms", "tool timing was not informative")
	local status = app.renderer.previous:plain_line(8)
	assert_contains(status, "5 tools active")
	assert_contains(status, "stage 2/7")
	if status:find("LEARN", 1, true) then error("tutorial caption still visible") end
end)

test("tool board leaves notices and file focus visible", function()
	local state = tui.State.new({ clock = function() return 10 end })
	state:tool_event(start("read-a", "read", { path = "README.md" }))
	local app = tui.App.new({ backend = fake_backend({ width = 160, height = 24 }),
		state = state, tool_stage = true, effect = "drift" })
	app.busy = true
	state:notice("connection restored")
	app:render(0.1)
	local status = app.renderer.previous:plain_line(8)
	assert_contains(status, "connection restored")
	assert_contains(status, "Ctrl-C cancels")
	app:focus_next()
	app:render(0.1)
	status = app.renderer.previous:plain_line(8)
	assert_contains(status, "README.md")
	assert_contains(status, "Tab next")
	if status:find("LEARN", 1, true) then error("tutorial caption still visible") end
end)

test("tool stage can be toggled without changing tool state", function()
	local state = tui.State.new({ clock = function() return 10 end })
	state:tool_event(start("read-a", "read", { path = "README.md" }))
	local app = tui.App.new({ backend = fake_backend(), state = state })
	assert_eq(app.tool_stage, false)
	assert_eq(app:set_tool_stage(true), true)
	assert_eq(app.tool_stage, true)
	assert_eq(#state:active_tools(), 1)
	app:render(0.1)
	assert_eq(#app.staged_tools, 1)
	assert_eq(app:set_tool_stage(false), true)
	assert_eq(app.tool_stage, false)
	assert_eq(#state:active_tools(), 1)
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
	local living_flow = app.flow
	assert_eq(app:set_effect("mycelium"), true)
	assert_eq(app.flow, living_flow, "switching treatment replaced the living current")
	assert_eq(#state:active_tools(), 1)
	local invalid = app:set_effect("lava-lamp")
	assert_eq(invalid, nil)
	assert_eq(app.effect, "mycelium")
end)

test("organic effects render concurrent tools without losing their labels", function()
	local frames = {}
	for _, effect in ipairs({ "mycelium", "cytoplasm", "ink" }) do
		local state = tui.State.new({ clock = function() return 10 end })
		state:tool_event(start("read-a", "read", { path = "lua/agent/core.lua" }))
		state:tool_event(start("edit-b", "edit", { path = "lua/agent/tui.lua" }))
		local app = tui.App.new({ backend = fake_backend({ width = 100, height = 24 }), state = state, effect = effect })
		app:render(0.2)
		local rows = {}
		for row = 2, 5 do rows[#rows + 1] = app.renderer.previous:plain_line(row) end
		frames[effect] = table.concat(rows, "\n")
		assert_contains(frames[effect], "core.lua", effect .. " hid the read actor")
		assert_contains(frames[effect], "tui.lua", effect .. " hid the edit actor")
		assert_eq(#state:active_tools(), 2)
	end
	if frames.mycelium == frames.cytoplasm or frames.cytoplasm == frames.ink or frames.mycelium == frames.ink then
		error("organic effects collapsed to the same visual grammar")
	end
end)

test("automatic effects usually stay and change only at safe turn boundaries", function()
	local state = tui.State.new({ clock = function() return 10 end })
	local roll = 0.8
	local app = tui.App.new({ backend = fake_backend(), state = state, effect = "auto",
		effect_random = function(n) return n and 1 or roll end })
	assert_eq(app.effect, "drift")
	assert_eq(app:auto_advance_effect(), false, "first turn must keep startup style")
	assert_eq(app:auto_advance_effect(), false, "ordinary roll must keep style")
	roll = 0.2
	assert_eq(app:auto_advance_effect(), false, "20 percent boundary must keep style")
	roll = 0.19
	state:tool_event(start("read-a", "read", { path = "README.md" }))
	assert_eq(app:auto_advance_effect(), false, "active tools must block rotation")
	app:render(2.0)
	assert_eq(app.effect, "drift", "rendering must not rotate styles")
	state:tool_event(finish("read-a", "read", { path = "README.md" }, { is_error = false, summary = "20 lines" }))
	state.failure = "failed"
	assert_eq(app:auto_advance_effect(), false)
	state.failure = nil
	state.recoveries = { pending = {} }
	assert_eq(app:auto_advance_effect(), false)
	state.recoveries = {}
	assert_eq(app:auto_advance_effect(), true)
	assert_eq(app.effect, "mycelium")
	assert_eq(app.effect_transition_from, "drift")
	app:render(0.8)
	assert_eq(app.effect_transition_from, nil)
	app:set_effect_auto(false)
	assert_eq(app:auto_advance_effect(), false)
	local pinned = tui.App.new({ backend = fake_backend(), effect = "ink" })
	assert_eq(pinned.effect_auto, false)
	assert_eq(pinned:auto_advance_effect(), false)
end)

test("manual next cycles through the curated effect order", function()
	local app = tui.App.new({ backend = fake_backend(), effect = "drift" })
	assert_eq(app:next_effect(), true)
	assert_eq(app.effect, "mycelium")
	assert_eq(app:next_effect(), true)
	assert_eq(app.effect, "cytoplasm")
	assert_eq(app:next_effect(), true)
	assert_eq(app.effect, "ink")
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

test("hosted web searches keep an open-ended count with wandering eyes", function()
	local now = 20
	local state = tui.State.new({ clock = function() return now end })
	state:submit("compare search APIs")
	state:model_activity({ type = "web_search", phase = "searching", id = "ws-1" })
	assert_eq(state.model_phase, "web search ( o  o ) · 1 opened so far · 0s")
	now = 26
	state:model_activity({ type = "web_search", phase = "searching", id = "ws-2" })
	assert_contains(state.model_phase, "2 opened so far · 6s")
	local first_gaze = state.model_phase:match("web search (%b())")
	now = 29
	local moved = state:display_model_phase()
	assert_contains(moved, "2 opened so far · 9s")
	if moved:match("web search (%b())") == first_gaze then error("web-search eyes did not move") end
	state:model_activity({ type = "web_search", phase = "completed", id = "ws-1" })
	assert_contains(state.model_phase, "2 opened so far · 1 back · 9s")
	state:model_activity({ type = "web_search", phase = "completed", id = "ws-1" })
	assert_contains(state.model_phase, "2 opened so far · 1 back · 9s")
	state:model_activity({ type = "web_search", phase = "searching", id = "ws-3" })
	state:model_activity({ type = "web_search", phase = "searching", id = "ws-4" })
	assert_contains(state.model_phase, "4 opened so far · 1 back")
	if state.model_phase:find("/4", 1, true) then error("web search exposed a premature denominator") end
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

test("default rotation can start at every style and choose every other style", function()
	local names = { "drift", "mycelium", "cytoplasm", "ink", "filament", "contours" }
	for initial, name in ipairs(names) do
		for choice = 1, #names - 1 do
			local draws = 0
			local app = tui.App.new({ backend = fake_backend(), effect_random = function(n)
				if not n then return 0 end
				draws = draws + 1
				return draws == 1 and initial or choice
			end })
			assert_eq(app.effect, name)
			assert_eq(app.effect_auto, true)
			assert_eq(app:auto_advance_effect(), false)
			assert_eq(app:auto_advance_effect(), true)
			local expected = choice >= initial and choice + 1 or choice
			assert_eq(app.effect, names[expected])
			app:render(0.8)
			assert_eq(app.effect_transition_from, nil)
		end
	end
end)

test("drift eases through model tool failure and verification states", function()
	local state = tui.State.new({ clock = function() return 10 end })
	local app = tui.App.new({ backend = fake_backend({ width = 100, height = 24 }), state = state, effect = "drift" })
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
	assert_eq(state.proof, 0, "command success is not verification")
	if app.flow.morph.failure <= 0 or app.flow.morph.failure >= disturbed then
		error("failure disturbance did not ease out after command success")
	end
end)

test("edit filenames are pulled from the edge toward assembly", function()
	local backend = fake_backend({ width = 120, height = 32 })
	local state = tui.State.new({ clock = function() return 10 end })
	state:tool_event(start("file-a", "edit", { path = "lua/agent/tui.lua" }))
	local app = tui.App.new({ backend = backend, state = state, effect = "drift" })
	local positions = {}
	for _, dt in ipairs({ 0.1, 0.8, 1.6 }) do
		app:render(dt)
		local found
		for row = 2, 5 do
			local line = app.renderer.previous:plain_line(row)
			found = found or line:find("tui.lua", 1, true)
		end
		positions[#positions + 1] = assert(found, "missing edit filename")
	end
	local centre = 60
	if math.abs(positions[2] - centre) >= math.abs(positions[1] - centre) then error("edit filename was not pulled inward") end
	if math.abs(positions[3] - centre) >= math.abs(positions[2] - centre) then error("edit filename did not continue settling") end
end)

test("visual conductor preserves focal streams and reduces older labels to trails", function()
	local state = tui.State.new({ clock = function() return 10 end })
	state:submit("inspect and change several files")
	for index = 1, 10 do
		state:tool_event(finish("read-" .. index, "read", { path = "src/file" .. index .. ".lua" }, {
			is_error = false, summary = "20 lines",
		}))
	end
	state:tool_event(start("edit-focus", "edit", { path = "src/focus.lua" }))
	local app = tui.App.new({ backend = fake_backend({ width = 120, height = 24 }), state = state })
	app:render(0.1)
	if #app.foreground_streams > 4 then error("conductor exceeded the four-row foreground budget") end
	local focused = false
	for _, stream in ipairs(app.foreground_streams) do
		if stream.text == "focus.lua" and stream.kind == "file_active" then focused = true end
	end
	assert_eq(focused, true)
	if #state.streams <= #app.foreground_streams then error("older activity was not demoted to trails") end
end)

test("visual conductor prioritizes four concurrent tools ahead of the request trail", function()
	local state = tui.State.new({ clock = function() return 10 end })
	state:submit("run a busy batch")
	for index, spec in ipairs({
		{ "read", { path = "README.md" } },
		{ "grep", { pattern = "render", path = "lua" } },
		{ "find", { path = "." } },
		{ "edit", { path = "lua/agent/tui.lua" } },
		{ "write", { path = "notes.txt" } },
		{ "run", { command = "make test" } },
	}) do
		state:tool_event(start("tool-" .. index, spec[1], spec[2]))
	end
	local app = tui.App.new({ backend = fake_backend({ width = 120, height = 24 }), state = state })
	app:render(0.1)
	assert_eq(#app.foreground_streams, 4)
	for _, stream in ipairs(app.foreground_streams) do
		if not stream.tool or stream.tool.status ~= "active" then error("non-tool displaced concurrent active work") end
	end
end)

test("tool streams receive distinct motion personalities", function()
	local state = tui.State.new({ clock = function() return 10 end })
	state:tool_event(start("read", "read", { path = "README.md" }))
	state:tool_event(start("edit", "edit", { path = "lua/agent/tui.lua" }))
	state:tool_event(start("search", "grep", { pattern = "render", path = "lua" }))
	state:tool_event(start("build", "run", { command = "make test" }))
	local personalities = {}
	for _, stream in ipairs(state.streams) do personalities[stream.tool.name] = stream.personality end
	assert_eq(personalities.read, "skim")
	assert_eq(personalities.edit, "inward")
	assert_eq(personalities.grep, "scatter")
	assert_eq(personalities.run, "pulse")
end)

test("inline animation hides hardware cursor until terminal cleanup", function()
	local backend = fake_backend()
	local app = tui.App.new({ backend = backend, effect = "drift" })
	local ok, err = tui.with_terminal(app.terminal, app.renderer, function()
		assert_contains(table.concat(backend.output), lcatui.ansi.hide_cursor)
		for _ = 1, 3 do
			-- Another writer or terminal reset can restore cursor visibility.
			backend:write(lcatui.ansi.show_cursor)
			backend.output = {}
			app:render(0.05)
			local output = table.concat(backend.output)
			assert_eq(output:sub(1, #lcatui.ansi.hide_cursor), lcatui.ansi.hide_cursor)
			assert_contains(output, lcatui.ansi.begin_synchronized_update)
			assert_eq(output:find(lcatui.ansi.show_cursor, 1, true), nil)
		end
		backend.output = {}
		app:commit_lines({ "transcript" })
		assert_eq(table.concat(backend.output):sub(1, #lcatui.ansi.hide_cursor), lcatui.ansi.hide_cursor)
		return true
	end)
	assert_eq(ok, true, err)
	assert_contains(table.concat(backend.output), lcatui.ansi.show_cursor)
	assert_eq(backend.raw, false)
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

test("248x69 terminal keeps a fast fixed eight-row inline strip", function()
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
	assert_eq(app.renderer.previous.height, 8)
	for row = 3, 5 do
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

test("render caps a tall terminal to four flow rows between dividers and the dock", function()
	local backend = fake_backend()
	local app = tui.App.new({
		backend = backend, effect = "drift",
		size_provider = function() return 132, 47 end,
	})
	app:render()
	assert_eq(app.flow_width, 132)
	assert_eq(app.flow_height, 4)
	assert_eq(app.renderer.previous.height, 8)
	assert_contains(app.renderer.previous:plain_line(1), "────")
	assert_contains(app.renderer.previous:plain_line(7), "input ›")
	assert_eq(app.renderer.previous.rows[7][10].style.attrs[1], "reverse")
	for _ = 1, 20 do app.last_frame = app.last_frame - 0.05; app:render() end
	local lower_before = {}
	for row = 3, 5 do lower_before[#lower_before + 1] = app.renderer.previous:plain_line(row) end
	app.last_frame = app.last_frame - 0.05
	app:render()
	local lower_after, lower_glyphs = {}, 0
	for row = 3, 5 do
		local line = app.renderer.previous:plain_line(row)
		lower_after[#lower_after + 1] = line
		for char in line:gmatch(utf8.charpattern) do if char ~= " " then lower_glyphs = lower_glyphs + 1 end end
	end
	if lower_glyphs < 3 then error("lower half of the compact flow field is empty") end
	if table.concat(lower_before, "\n") == table.concat(lower_after, "\n") then error("compact flow field is not moving") end
end)

test("long input wraps, follows editing, and shrinks after submission", function()
	local width = 40
	local app = tui.App.new({ backend = fake_backend(), size_provider = function() return width, 24 end })
	app.editor:set(string.rep("a", 30) .. "visible tail")
	app:render()
	assert_eq(app.renderer.previous.height, 9)
	assert_contains(app.renderer.previous:plain_line(8), "visible tail")
	assert_eq(app.renderer.previous.rows[8][22].style.attrs[1], "reverse")
	app.editor:set(string.rep("a", 180) .. "last")
	app:render()
	assert_eq(app.renderer.previous.height, 12)
	assert_contains(app.renderer.previous:plain_line(11), "last")
	assert_eq(app.renderer.previous.rows[11][14].style.attrs[1], "reverse")
	app.editor.cursor = 0
	app:render()
	assert_eq(app.renderer.previous.rows[7][10].style.attrs[1], "reverse")
	width = 100
	app.editor.cursor = #app.editor.chars
	app:render()
	assert_eq(app.renderer.previous.height, 10)
	assert_contains(app.renderer.previous:plain_line(9), "last")
	assert_eq(app.editor:submit(), string.rep("a", 180) .. "last")
	app:render()
	assert_eq(app.renderer.previous.height, 8)
	assert_eq(app.renderer.previous.rows[7][10].style.attrs[1], "reverse")
end)

test("input wrapping respects wide characters and exact row boundaries", function()
	local editor = tui.Editor.new()
	editor:set(string.rep("a", 29) .. "界é")
	local lines, row, col = editor:layout(30, 5)
	assert_eq(lines[1], string.rep("a", 29))
	assert_eq(lines[2], "界é")
	assert_eq(row, 2)
	assert_eq(col, 3)
	editor.cursor = 29
	lines, row, col = editor:layout(30, 5)
	assert_eq(row, 2)
	assert_eq(col, 0)
	editor:set(string.rep("界", 15))
	lines, row, col = editor:layout(30, 5)
	assert_eq(lines[1], string.rep("界", 15))
	assert_eq(lines[2], "")
	assert_eq(row, 2)
	assert_eq(col, 0)
end)

test("Ctrl+L reanchors the viewport without changing the draft or task", function()
	for _, busy in ipairs({ false, true }) do
		local backend = fake_backend({ width = 80, height = 24 })
		local app = tui.App.new({ backend = backend })
		app.input = tui.Input.new(app.editor)
		app.busy = busy
		app.editor:set("keep my draft")
		app.editor.cursor = 4
		app.state.plan = { { step = "Keep working", status = "in_progress" } }
		local plan = app.state.plan
		app:render(0)
		backend.output = {}
		app:feed_input("\12")
		app:render(0)
		local output = table.concat(backend.output)
		assert_contains(output, lcatui.ansi.clear_screen)
		assert_contains(output, lcatui.ansi.position(24 - app.renderer.previous.height + 1, 1))
		assert_contains(output, "keep")
		assert_eq(output:find("\27[3J", 1, true), nil, "must not erase scrollback")
		assert_eq(app.editor:text(), "keep my draft")
		assert_eq(app.editor.cursor, 4)
		assert_eq(app.state.plan, plan)
		assert_eq(#app.submitted, 0)
		assert_eq(app.redraw_requested, false)
		backend.output = {}
		app:render(0)
		assert_eq(table.concat(backend.output):find(lcatui.ansi.clear_screen, 1, true), nil)
	end
	local editor = tui.Editor.new()
	local input = tui.Input.new(editor)
	local actions = input:feed_chunk("\27[200~draft\12\27[201~", false)
	assert_eq(#actions, 0, "pasted Ctrl+L must not trigger redraw")
end)

test("completed assistant response becomes a colored riverbank transcript", function()
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
	assert_contains(output, "\27[2;38;2;72;151;153m")
	assert_contains(output, "\27[1;38;2;190;142;231mlca ›")
	assert_contains(output, "\r\n\27[2;38;2;72;151;153m│")
	assert_contains(output, "Email magic-link authentication")
	assert_contains(output, "The project includes environment setup and build instructions")
	if output:find("\r\n  - ", 1, true) then error("assistant transcript retained the plain two-column indent") end
	assert_eq(app.renderer.inline_height, 0)
	assert_eq(app.renderer.previous, nil)
end)

test("narrow assistant transcript keeps its riverbank and semantic structure", function()
	local backend = fake_backend({ width = 72, height = 24 })
	local app = tui.App.new({ backend = backend })
	app.renderer:mount("inline")
	backend.output = {}
	app:commit_assistant("## Result\n\n- item\n  continuation\n\n```lua\nprint('ok')\n```")
	local output = table.concat(backend.output)
	assert_contains(output, "╭ lca › Result")
	assert_contains(output, "\r\n│")
	assert_contains(output, "\r\n│ · item")
	assert_contains(output, "\r\n│   continuation")
	assert_contains(output, "\r\n│ ```lua")
	assert_contains(output, "\r\n│ print('ok')")
	assert_contains(output, "\r\n╰")
end)

test("assistant transcript wraps inside the riverbank including long links", function()
	local lines = tui._assistant_transcript_lines(
		"## Tools\n\n- Tools can include MCP servers, AgentCore Gateway, Browser, Code Interpreter, shell, and file operations. "
			.. "([docs.aws.amazon.com](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/harness-tools.html?utm_source=openai))",
		false, 54)
	assert_eq(lines[1]:sub(1, #"╭ lca › "), "╭ lca › ")
	local continuation_seen = false
	for index, line in ipairs(lines) do
		if lcatui.width.string(line) > 54 then error("transcript row exceeded terminal width: " .. line) end
		if index > 1 and line:sub(1, #"│   ") == "│   " then continuation_seen = true end
	end
	assert_eq(continuation_seen, true)
end)

test("assistant tables become wrapped labeled entries", function()
	local source = "## Proposed building blocks\n\n"
		.. "| Capability | Blessed default |\n|---|---|\n"
		.. "| Frontend | Static assets on S3 + CloudFront |\n"
		.. "| Database | Shared RDS PostgreSQL infrastructure; separate database and restricted login per app |"
	local lines = tui._assistant_transcript_lines(source, false, 48)
	local output = table.concat(lines, "\n")
	assert_contains(output, "Capability → Blessed default")
	assert_contains(output, "│ · Frontend\n│   Static assets on S3 + CloudFront")
	assert_contains(output, "│ · Database\n│   Shared RDS PostgreSQL infrastructure;")
	assert_contains(output, "│   separate database and restricted login")
	if output:find("|", 1, true) then error("raw table pipes remained") end
	for _, line in ipairs(lines) do
		if lcatui.width.string(line) > 48 then error("table overflow: " .. line) end
	end
end)

test("table records preserve column labels empty cells and escaped pipes", function()
	local output = table.concat(tui._assistant_transcript_lines(
		"Name | Status | Notes\n:--- | ---: | :---:\nAlpha | ready | a\\|b\nBeta | | pending", false, 80), "\n")
	assert_contains(output, "│ · Alpha\n│   Status: ready\n│   Notes: a|b")
	assert_contains(output, "│ · Beta\n│   Status: \n│   Notes: pending")
end)

test("table recognition leaves code and ordinary pipes alone", function()
	for _, fence in ipairs({ "```", "~~~~" }) do
		local output = table.concat(tui._assistant_transcript_lines(
			"Example\n" .. fence .. "\n| A | B |\n|---|---|\n| x | y |\n" .. fence
			.. "\nleft | right\n| A | B |\n| not | a separator |", false, 80), "\n")
		assert_contains(output, "│ |---|---|")
		assert_contains(output, "│ | x | y |")
		assert_contains(output, "│ left | right")
		assert_contains(output, "│ | not | a separator |")
	end
end)

test("river retains a whole turn beyond the live tool window and commits once", function()
	local now = 0
	local state = tui.State.new({ clock = function() return now end })
	state:submit("inspect files")
	local chosen_design = state.river_design
	assert_eq(type(chosen_design), "string")
	for index = 1, 25 do
		state:tool_event({phase="start",call_id=tostring(index),name="read",args={path="a"}})
		now = now + 1
		state:tool_event({phase="complete",call_id=tostring(index),name="read",args={path="a"},result={is_error=index==1}})
	end
	assert_eq(#state.tools, 18)
	assert_eq(state.river_trace:summary().calls, 25)
	local backend = fake_backend({width=80,height=24})
	local app = tui.App.new({backend=backend,state=state})
	app.renderer:mount("inline")
	app:commit_river()
	local output = table.concat(backend.output)
	assert_contains(output,"25 calls")
	assert_contains(output,"1 failed")
	app:commit_river()
	assert_eq(state.river_design, chosen_design)
	assert_eq(table.concat(backend.output),output)
	app:commit_river_details()
	assert_contains(table.concat(backend.output),"same arguments as #24")
	state:submit("next")
	assert_eq(state.river_trace:summary().calls,0)
end)

test("river details display readable arguments and wrap each physical line", function()
	local state = tui.State.new({clock=function() return 1 end})
	state:submit("inspect logs")
	local command = "find /tmp/lca -type f -printf '%p\\n' | head -60\nprintf 'done'"
	-- Use a real newline between commands, retaining the shell's literal escape.
	command = command:gsub("head %-60\\n", "head -60\n")
	local args = {command=command,timeout=10000,options={verbose=true}}
	state:tool_event({phase="start",call_id="a",name="run",args=args})
	args.command = "mutated after start"
	state:tool_event({phase="complete",call_id="a",name="run",result={summary="exit 0\nsecond result line"}})
	local app = tui.App.new({backend=fake_backend({width=48,height=24}),state=state})
	local captured
	function app:commit_lines(lines) captured=lines end
	app:commit_river_details()
	local text = table.concat(captured,"\n")
	assert_contains(text,"#1  run · ok")
	assert_contains(text,"│   command:\n│     find /tmp/lca")
	assert_contains(text,"│     printf 'done'")
	assert_contains(text,"timeout: 10000")
	assert_contains(text,'options: {"verbose":true}')
	assert_contains(text,"│     exit 0\n│     second result line")
	if text:find("string:",1,true) or text:find("mutated after start",1,true) then error("internal or mutated arguments leaked") end
	for _, line in ipairs(captured) do
		if line:find("\n",1,true) then error("embedded newline bypasses layout") end
		if lcatui.width.string(line)>48 then error("detail overflow: "..line) end
	end
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
	if buffer:plain_line(7):find("explain this project", 1, true) then
		error("submitted text remained in the input dock")
	end
	assert_eq(buffer.rows[7][10].style.attrs[1], "reverse")
	assert_contains(buffer:plain_line(8), "working")
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
	local status = app.renderer.previous:plain_line(8)
	assert_contains(status, "LCA · listening")
	if status:find("session cleared", 1, true) then error("expired notice remained in status row") end
end)

test("run progress keeps verification alive and advances its elapsed story", function()
	local now = 10
	local state = tui.State.new({ clock = function() return now end })
	state:submit("make it work")
	state:tool_event({ phase = "start", call_id = "run-live", name = "run", args = { command = "make test" } })
	now = 22
	local tool = state:tool_event({ phase = "progress", call_id = "run-live", name = "run", progress = {
		elapsed_ms = 12000, output_bytes = 140, output_chunks = 3,
	} })
	assert_eq(tool.status, "active")
	assert_eq(tool.result, "12s")
	assert_contains(state.model_phase, "12s")
	state:tool_event({ phase = "finish", call_id = "run-live", name = "run", args = { command = "make test" }, result = { summary = "exit 0" } })
	assert_eq(tool.status, "ok")
end)



test("narrow rivers keep a compact eddy without phase labels", function()
	local buffer = lcatui.Buffer.new(60, 4)
	local drawn = tui._draw_flywheel(buffer, 60, 4, {
		phase = "harvest", seed = 116, age = 1, birth = 1, release = 0,
	}, 2.3)
	assert_eq(drawn, true)
	local frame = {}
	for row = 1, 4 do frame[#frame + 1] = buffer:plain_line(row) end
	local text = table.concat(frame, "\n")
	if text:find("evidence", 1, true) then error("compact eddy retained its wide label") end
	if not text:find("◇", 1, true) and not text:find("·", 1, true) then error("compact eddy emitted no organism") end
end)


test("status FPS is always visible and counts completed frames including stalls", function()
	local now = 0
	local app = tui.App.new({ backend = fake_backend({ width = 100, height = 24 }),
		fps_clock = function() return now end })
	local function status()
		local screen = app.renderer.previous
		return screen:plain_line(screen.height)
	end
	app:render(0)
	assert_contains(status(), "-- fps")
	for _ = 1, 25 do
		now = now + 40000000
		app:render(0.04)
	end
	app:draw()
	assert_contains(status(), "25 fps")
	assert_eq(app.fps_intervals, 0)
	for _ = 1, 10 do app:draw() end
	assert_eq(app.fps_intervals, 0)
	now = now + 2000000000
	app:render(0.04)
	app:draw()
	assert_contains(status(), "1 fps")
	assert_eq(app.fps, 0.5)
	app.draw = function() error("test draw failure") end
	local ok = pcall(function() app:render(0.04) end)
	assert_eq(ok, false)
	assert_eq(app.fps_intervals, 0)
	app:stop_io()
end)

io.write("\n" .. tostring(passed) .. " passed, " .. tostring(failed) .. " failed\n")
if failed > 0 then os.exit(1) end
