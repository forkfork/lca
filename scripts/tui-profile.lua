#!/usr/bin/env lua
-- Offline, fixed-step replay. No terminal, model, tools, or session writes.
local root = (arg[0]:match("^(.*)/[^/]+$") or ".") .. "/.."
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
pcall(require, "luarocks.loader")
local Replay = require("agent.tui_replay")
local effects = require("agent.tui_effects")
local lcatui = require("agent.ui")
local uv = require("luv")
local json = require("agent.util.json")
local Profile = {}

function Profile.stats(values)
	local sorted, total, over = {}, 0, 0
	for i, value in ipairs(values) do
		sorted[i], total = value, total + value
		if value > 40 then over = over + 1 end
	end
	table.sort(sorted)
	local function percentile(p) return sorted[math.max(1, math.ceil(#sorted * p))] or 0 end
	return { count = #sorted, total_ms = total, p50_ms = percentile(0.5), p95_ms = percentile(0.95),
		p99_ms = percentile(0.99), max_ms = percentile(1), over_40ms = over }
end

function Profile.run(fixture, opts)
	opts = opts or {}
	local width, height = opts.width or 80, opts.height or 24
	assert(width >= 20 and width % 1 == 0 and height >= 10 and height % 1 == 0, "invalid dimensions")
	local backend, output, frames, samples = {}, {}, {}, {}
	local current, stack, restores = nil, {}, {}
	function backend:size() return width, height end
	function backend:supports_color() return true end
	function backend:write(text)
		if current then current.bytes = current.bytes + #text; current.writes = current.writes + 1 end
		if opts.capture then output[#output + 1] = text end
	end
	function backend:flush() if current then current.flushes = current.flushes + 1 end end
	local player = Replay.new(fixture, { backend = backend, effect = opts.effect })
	local function wrap(object, key, name)
		local original, own = object[key], rawget(object, key)
		assert(type(original) == "function", "missing profiling seam: " .. key)
		restores[#restores + 1] = function() object[key] = own end
		object[key] = function(...)
			if not current then return original(...) end
			local phase = type(name) == "function" and name(...) or name
			local entry = { start = uv.hrtime(), children = 0 }
			stack[#stack + 1] = entry
			local result = table.pack(original(...))
			local elapsed = uv.hrtime() - entry.start
			stack[#stack] = nil
			if stack[#stack] then stack[#stack].children = stack[#stack].children + elapsed end
			current.phases[phase] = (current.phases[phase] or 0) + (elapsed - entry.children) / 1e6
			current.calls[phase] = (current.calls[phase] or 0) + 1
			return table.unpack(result, 1, result.n)
		end
	end
	local old_hook, old_mask, old_count = debug.gethook()
	local ok, err = xpcall(function()
		wrap(player, "_events_until", "events")
		wrap(player.app, "advance", function(_, dt) return dt == 0 and "refresh" or "advance" end)
		wrap(player.app, "draw", "compose")
		wrap(effects, "render", "effect")
		wrap(player.app.renderer, "draw", "renderer")
		wrap(lcatui.Buffer, "styled_line", "serialize")
		wrap(backend, "write", "write")
		wrap(backend, "flush", "flush")
		if opts.sample then
			assert(not old_hook, "sampling would replace an existing debug hook")
			debug.sethook(function()
				local info = debug.getinfo(2, "Sl")
				local key = info.short_src .. ":" .. info.currentline
				samples[key] = (samples[key] or 0) + 1
			end, "", 10000)
		end
		local stop = math.min(opts.until_time or player.duration, player.duration)
		assert(stop > 0, "end time must be positive")
		while not player.finished and player.now < stop - 1e-9 do
			current = { phases = {}, calls = {}, bytes = 0, writes = 0, flushes = 0,
				first_event = player.next_event, heap_before_kb = collectgarbage("count") }
			local started, cpu = uv.hrtime(), os.clock()
			player:step()
			player.app.state.model_phase = player:label()
			player:draw()
			current.wall_ms, current.cpu_ms = (uv.hrtime() - started) / 1e6, (os.clock() - cpu) * 1000
			current.at, current.last_event = player.now, player.next_event - 1
			current.events = math.max(0, current.last_event - current.first_event + 1)
			current.mode, current.tools, current.streams = player.app.state.mode, #player.app.state.tools, #player.app.state.streams
			current.heap_after_kb = collectgarbage("count")
			frames[#frames + 1], current = current, nil
		end
	end, debug.traceback)
	if opts.sample and not old_hook then debug.sethook() end
	for i = #restores, 1, -1 do restores[i]() end
	if not ok then error(err, 0) end
	local wall, phases, bytes = {}, {}, 0
	for i, frame in ipairs(frames) do
		wall[i], bytes = frame.wall_ms, bytes + frame.bytes
		for name, ms in pairs(frame.phases) do phases[name] = (phases[name] or 0) + ms end
	end
	local ranked = {}
	for i, frame in ipairs(frames) do ranked[i] = frame end
	table.sort(ranked, function(a, b) return a.wall_ms > b.wall_ms end)
	local worst = {}
	for i = 1, math.min(10, #ranked) do worst[i] = ranked[i] end
	return { schema = 1, backend = "discard", cadence = "one 40ms step plus replay draw; no sleeping or catch-up",
		width = width, height = height, effect = player.app.effect, lua = _VERSION,
		sampled = opts.sample == true, samples_kind = "Lua instruction samples, NOT CPU time; native calls are not sampled",
		initial_events = frames[1] and frames[1].first_event - 1 or 0,
		processed_events = player.next_event - 1, fixture_events = #fixture.events,
		finished = player.finished, summary = Profile.stats(wall), phase_exclusive_ms = phases,
		bytes = bytes, worst_frames = worst, frames = frames, samples = samples }, table.concat(output)
end

if ... == "tui_profile_test" then return Profile end
if arg[1] == "--help" then
	print("lua scripts/tui-profile.lua FIXTURE REPORT [WIDTH HEIGHT EFFECT [UNTIL_SECONDS [sample]]]")
	print("Writes JSON with exclusive phase timings, worst frames, and optional instruction samples.")
	print("Offline cost benchmark: not a real-terminal FPS or input-latency measurement.")
	return
end
assert(arg[1] and arg[2], "expected FIXTURE REPORT; use --help")
local report = Profile.run(Replay.load(arg[1]), { width = tonumber(arg[3]), height = tonumber(arg[4]),
	effect = arg[5], until_time = tonumber(arg[6]), sample = arg[7] == "sample" })
report.fixture = arg[1]
local file = assert(io.open(arg[2], "w"))
assert(file:write(json.encode(report), "\n")); assert(file:close())
print(string.format("%d frames; p50 %.2f / p95 %.2f / p99 %.2f / max %.2f ms; %d >40ms; %.2f MB output",
	report.summary.count, report.summary.p50_ms, report.summary.p95_ms, report.summary.p99_ms,
	report.summary.max_ms, report.summary.over_40ms, report.bytes / 1e6))
local names = {}; for name in pairs(report.phase_exclusive_ms) do names[#names + 1] = name end
table.sort(names, function(a, b) return report.phase_exclusive_ms[a] > report.phase_exclusive_ms[b] end)
for _, name in ipairs(names) do print(string.format("  %-10s %9.2f ms", name, report.phase_exclusive_ms[name])) end
