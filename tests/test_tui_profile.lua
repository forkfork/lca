local root = (arg[0]:match("^(.*)/[^/]+$") or ".") .. "/.."
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
pcall(require, "luarocks.loader")
local Profile = assert(loadfile(root .. "/scripts/tui-profile.lua"))("tui_profile_test")
local Replay = require("agent.tui_replay")
local effects = require("agent.tui_effects")
local original = effects.render
local fixture = { duration = 0.16, events = {
	{ at = 0, kind = "submit", text = "hello" },
	{ at = 0.04, kind = "stream", text = "hello world" },
	{ at = 0.08, kind = "complete", text = "hello world" },
} }
local stats = Profile.stats({ 1, 2, 3, 50 })
assert(stats.count == 4 and stats.p50_ms == 2 and stats.p99_ms == 50 and stats.over_40ms == 1)
assert(Profile.stats({}).max_ms == 0)
local report, output = Profile.run(fixture, { capture = true })
assert(report.finished and report.summary.count == 4 and report.processed_events == 3)
assert(report.initial_events == 1 and report.frames[1].events == 1)
assert(report.bytes == #output and #output > 0 and effects.render == original)
for _, frame in ipairs(report.frames) do
	assert(frame.calls.advance == 1 and frame.calls.refresh == 1)
	local total = 0; for _, ms in pairs(frame.phases) do assert(ms >= 0); total = total + ms end
	assert(total <= frame.wall_ms and frame.cpu_ms >= 0)
end
-- Independently replay without any instrumentation; the complete ANSI stream must match.
local chunks, backend = {}, {}
function backend:size() return 80, 24 end
function backend:supports_color() return true end
function backend:write(text) chunks[#chunks + 1] = text end
function backend:flush() end
local player = Replay.new(fixture, { backend = backend })
while not player.finished do
	player:step(); player.app.state.model_phase = player:label(); player:draw()
end
assert(table.concat(chunks) == output, "profiling altered rendered output")
local sampled = Profile.run(fixture, { sample = true })
assert(sampled.sampled and next(sampled.samples) and debug.gethook() == nil)
-- Failure must restore all wrapped shared methods and the debug hook.
effects.render = function() error("injected render failure") end
local failing = effects.render
local ok, err = pcall(Profile.run, fixture, { sample = true })
assert(not ok and tostring(err):find("injected render failure", 1, true))
assert(effects.render == failing and debug.gethook() == nil)
effects.render = original
assert(not pcall(Profile.run, fixture, { width = 0 }))
print("PASS replay profiling: timing accounting, exact ANSI equivalence, samples, failure cleanup")
