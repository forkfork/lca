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

test("terminal lifecycle restores after injected failure", function()
	local backend = fake_backend()
	local terminal = lcatui.Terminal.new(backend)
	local renderer = lcatui.Renderer.new(backend, { mode = "fullscreen", synchronized = true })
	local ok, err = tui.with_terminal(terminal, renderer, function() error("injected render failure") end)
	assert_eq(ok, nil)
	assert_contains(err, "injected render failure")
	assert_eq(backend.raw, false)
	local output = table.concat(backend.output)
	assert_contains(output, lcatui.ansi.enter_alt_screen)
	assert_contains(output, lcatui.ansi.end_synchronized_update)
	assert_contains(output, lcatui.ansi.show_cursor)
	assert_contains(output, lcatui.ansi.leave_alt_screen)
	assert_contains(output, lcatui.ansi.disable_bracketed_paste)
end)

test("248x69 fullscreen animation stays inside its frame and output budgets", function()
	local backend = fake_backend({ width = 248, height = 69, color = true })
	local app = tui.App.new({ backend = backend })
	app.renderer:mount("inline")
	app.renderer:switch("fullscreen")
	app:render(1 / 30)
	backend.output = {}
	local started = os.clock()
	for _ = 1, 60 do app:render(1 / 30) end
	local elapsed = os.clock() - started
	local bytes = #table.concat(backend.output)
	if elapsed / 60 >= 1 / 30 then
		error(string.format("average frame %.2fms exceeds 33.33ms", elapsed / 60 * 1000))
	end
	if bytes / 60 >= 10000 then
		error(string.format("average frame emits %.0f bytes (budget 9999)", bytes / 60))
	end
	local lower_glyphs = 0
	for row = 35, 64 do
		for char in app.renderer.previous:plain_line(row):gmatch(utf8.charpattern) do
			if char ~= " " then lower_glyphs = lower_glyphs + 1 end
		end
	end
	if lower_glyphs < 20 then error("performance frame did not reach the lower screen") end
end)

test("frame scheduling uses deadlines rather than adding render time", function()
	local original_gettime = require("socket").gettime
	local now = 10.034
	require("socket").gettime = function() return now end
	local app = tui.App.new({ backend = fake_backend() })
	app.next_frame_at = 10.033
	app.render = function(_, dt)
		assert_eq(dt, 1 / 30)
		now = now + 0.020
	end
	local ok, err = pcall(function() app:drive_frame() end)
	require("socket").gettime = original_gettime
	if not ok then error(err) end
	if math.abs(app.next_frame_at - 10.066333333333) > 0.00001 then
		error("next deadline drifted by the render duration: " .. tostring(app.next_frame_at))
	end
end)

test("terminal lifecycle restores after cancellation", function()
	local backend = fake_backend()
	local terminal = lcatui.Terminal.new(backend)
	local renderer = lcatui.Renderer.new(backend, { mode = "fullscreen", synchronized = true })
	local state = tui.State.new()
	local ok, err = tui.with_terminal(terminal, renderer, function()
		state:cancel("Ctrl-C")
		return true
	end)
	assert_eq(ok, true, err)
	assert_eq(state.mode, "cancelled")
	assert_eq(backend.raw, false)
	assert_contains(table.concat(backend.output), lcatui.ansi.leave_alt_screen)
end)

test("render uses the real tall terminal size for flow and input dock", function()
	local backend = fake_backend()
	local app = tui.App.new({
		backend = backend,
		size_provider = function() return 132, 47 end,
	})
	app:render()
	assert_eq(app.flow_width, 132)
	assert_eq(app.flow_height, 43)
	if app.renderer.previous:plain_line(2):find("you ›", 1, true) then error("top row looks like a second input prompt") end
	assert_contains(app.renderer.previous:plain_line(45), "input ›")
	assert_eq(app.renderer.previous.rows[45][10].style.attrs[1], "reverse")
	for _ = 1, 20 do app.last_frame = app.last_frame - 0.05; app:render() end
	local lower_before = {}
	for row = 24, 42 do lower_before[#lower_before + 1] = app.renderer.previous:plain_line(row) end
	app.last_frame = app.last_frame - 0.05
	app:render()
	local lower_after, lower_glyphs = {}, 0
	for row = 24, 42 do
		local line = app.renderer.previous:plain_line(row)
		lower_after[#lower_after + 1] = line
		for char in line:gmatch(utf8.charpattern) do if char ~= " " then lower_glyphs = lower_glyphs + 1 end end
	end
	if lower_glyphs < 20 then error("lower half of the flow field is empty") end
	if table.concat(lower_before, "\n") == table.concat(lower_after, "\n") then error("lower half of the flow field is not moving") end
end)

io.write("\n" .. tostring(passed) .. " passed, " .. tostring(failed) .. " failed\n")
if failed > 0 then os.exit(1) end
