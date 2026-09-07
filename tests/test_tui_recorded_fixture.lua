#!/usr/bin/env lua
local root = (arg[0]:match("^(.*)/[^/]+$") or ".") .. "/.."
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
pcall(require, "luarocks.loader")
local Replay = require("agent.tui_replay")
local fixture = Replay.load(root .. "/tests/fixtures/tui-performance-analysis.jsonl")
assert(#fixture.events == 1214)
assert(not fixture.recording_error)
local function player()
	local backend = {}
	function backend:size() return 80, 24 end
	function backend:supports_color() return true end
	function backend:write(_) end
	function backend:flush() end
	return Replay.new(fixture, { backend = backend, effect = "drift" })
end
local a, b = player(), player()
local checkpoints = { 29.2, 35.4, 53.6, 74, 81, 106, 126.6 }
for _, target in ipairs(checkpoints) do
	while a.now + 1e-9 < math.min(target, a.duration) and not a.finished do a:step() end
	while b.now + 1e-9 < math.min(target, b.duration) and not b.finished do b:update(0.2) end
	assert(math.abs(a.now - b.now) < 1e-8, "chunking changed replay time")
	a:draw(); b:draw()
	local left, right = a.app.renderer.previous, b.app.renderer.previous
	assert(left.width == right.width and left.height == right.height)
	for row = 1, left.height do
		assert(left:styled_line(row, true) == right:styled_line(row, true), "render mismatch at " .. target .. " row " .. row)
	end
	if target == 29.2 then
		assert(a.app.state.tools_by_id["call_wfJQ75EY3HWAVZ67pIZnAUiJ"].status == "ok")
	elseif target == 81 then
		assert(a.app.state.mode == "streaming")
		assert(#a.app.state.assistant_stream > 0)
	elseif target == 106 then
		assert(a.app.state.mode == "complete")
		assert(#a.app.state:active_tools() == 0)
	end
end
assert(a.finished and b.finished)
assert(a.next_event == #fixture.events + 1)
assert(a.app.state.assistant == fixture.events[#fixture.events].text)
print("PASS recorded analysis: all events replayed; styled checkpoints deterministic")
