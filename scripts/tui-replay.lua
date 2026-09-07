#!/usr/bin/env lua
local root = (arg[0]:match("^(.*)/[^/]+$") or ".") .. "/.."
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
pcall(require, "luarocks.loader")
local Replay = require("agent.tui_replay")
local tui = require("agent.tui")
local uv = require("luv")
local socket = require("socket")
if arg[1] == "--help" then
	print("lua scripts/tui-replay.lua [fixture.json] [effect]")
	print("Ctrl-P pause · Ctrl-R restart · Ctrl-F speed · Ctrl-N step · Ctrl-T inspect · Ctrl-C quit")
	os.exit(0)
end
local player = Replay.new(Replay.load(arg[1] or root .. "/tests/fixtures/tui-replay.json"), { effect = arg[2] })
local timer, poll
local ok, err = tui.with_terminal(player.app.terminal, player.app.renderer, function()
	player.app:commit_lines({ "Replay only: no model, tools, or session writes.",
		"Ctrl-P pause · Ctrl-R restart · Ctrl-F speed · Ctrl-N step · Ctrl-T inspect · Ctrl-C quit", "" })
	local last = socket.gettime()
	local failure
	local function guarded(fn)
		local success, message = xpcall(fn, debug.traceback)
		if not success then failure = message; player.app.exit_requested = true end
	end
	timer = uv.new_timer()
	timer:start(0, 40, function() guarded(function()
		local now = socket.gettime()
		player:update(now - last)
		last = now
		player.app.state.model_phase = player:label()
		player:draw()
	end) end)
	poll = uv.new_poll(0)
	poll:start("r", function() guarded(function()
		local chunk, read_err = uv.fs_read(0, 128, -1)
		if not chunk then error(read_err or "stdin read failed") end
		if chunk == "" then player.app.exit_requested = true else player:feed_input(chunk) end
	end) end)
	while not player.app.exit_requested do uv.run("once") end
	if failure then error(failure) end
	return true
end)
for _, handle in pairs({ timer = timer, poll = poll }) do
	if not handle:is_closing() then handle:stop(); handle:close() end
end
uv.run("nowait")
if not ok then io.stderr:write(tostring(err), "\n"); os.exit(1) end
