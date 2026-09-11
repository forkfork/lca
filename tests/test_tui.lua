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

io.write("\n═══ TUI Adapter Tests ═══\n\n")

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

test("public work updates enter live scrollback without hidden protocol or duplicate finals", function()
	local backend = fake_backend({ width = 100, height = 32 })
	local app = tui.App.new({ backend = backend })
	app.renderer:mount("inline")
	app.state:submit("investigate reconnect")
	app.busy = true
	app:render(1 / 30)
	local calls = { { name = "read", args = { path = "timer.lua" } } }
	assert_eq(app:commit_work_update({ _native_tool_calls = calls,
		text = "<thinking>HIDDEN_REASONING</thinking>The callback still runs. Checking timer ownership."
			.. '<tool_call name="read">HIDDEN_ARGUMENTS</tool_call>' }), true)
	app:render(1 / 30)
	local output = table.concat(backend.output)
	assert_contains(output, "The callback still runs. Checking timer ownership.")
	assert_eq(output:find("HIDDEN_", 1, true), nil)
	assert_eq(app.busy, true)
	local count = #backend.output
	assert_eq(app:commit_work_update({ text = "Final answer." }), false)
	assert_eq(app:commit_work_update({ _native_tool_calls = {}, text = "Final answer." }), false)
	assert_eq(app:commit_work_update({ _native_tool_calls = calls, text = "<thinking>hidden</thinking>" }), false)
	assert_eq(#backend.output, count)
end)

test("captured hosted commentary displays live once and silent batches are diagnosed", function()
	local file = assert(io.open(project_dir .. "/tests/fixtures/tui-work-updates.json"))
	local fixture = require("agent.util.json").decode(file:read("*a")); file:close()
	local backend = fake_backend({ width = 180, height = 32 })
	local app = tui.App.new({ backend = backend })
	app.renderer:mount("inline")
	local core = require("agent.core")
	local original_log, logs = core.debug_log, {}
	core.debug_log = function(fmt, ...) logs[#logs + 1] = string.format(fmt, ...) end
	local ok, err = pcall(function()
		assert_eq(app:commit_work_update(fixture.silent_response), false)
		assert_contains(table.concat(logs, "\n"), "reason=no_public_text")
		local codex = require("agent.providers.codex")
		local item
		codex._process_event_payload(fixture.commentary_event, function() end, nil,
			codex._new_sse_stats(), nil, function(activity)
				assert_eq(activity.type, "assistant_commentary")
				item = activity.item
				app:commit_commentary(item, "live_commentary")
			end)
		assert(item)
		local public = item.content[1].text
		assert_contains(table.concat(backend.output), public)
		assert_contains(table.concat(logs, "\n"), "displayed source=live_commentary")
		local count = #backend.output
		local response = { text = public .. "\n\nFinal answer.", _output_items = {item} }
		assert_eq(app:commit_work_update(response), false, "completed response must not duplicate live commentary")
		assert_eq(#backend.output, count)
		assert_eq(app:final_response_text(response), "Final answer.")
		local fallback = tui.App.new({ backend = fake_backend({width = 180}) })
		assert_eq(fallback:commit_work_update(response), true, "completed-item fallback must work without local tools")
	end)
	core.debug_log = original_log
	if not ok then error(err) end
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

io.write("\n" .. tostring(passed) .. " passed, " .. tostring(failed) .. " failed\n")
if failed > 0 then os.exit(1) end
