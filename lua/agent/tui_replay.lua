-- Model-free event playback through the real TUI. No tool dispatch or sessions.
local tui = require("agent.tui")
local json = require("agent.util.json")
local Replay = {}
Replay.__index = Replay
local STEP = 1 / 25
local SPEEDS = { 0.25, 0.5, 1, 2, 4 }
local KINDS = { submit = true, tool = true, complete = true, cancel = true, waiting = true,
	stream = true, activity = true, reviewing = true, failure = true }

function Replay.load(path)
	local file = assert(io.open(path, "r"))
	local text = file:read(2 * 1024 * 1024 + 1)
	file:close()
	assert(#text <= 2 * 1024 * 1024, "replay exceeds 2 MiB")
	local first = text:match("([^\n]*)\n")
	local ok, header = pcall(json.decode, first or "")
	if not ok or type(header) ~= "table" or header.format ~= "lca-tui-replay" then return json.decode(text) end
	assert(header.version == 1, "unsupported recording version")
	local fixture = { events = {}, effect = header.effect }
	local first_line, ended = true, false
	-- Only newline-terminated records are committed; tolerate a crash-torn final line.
	for line in text:gmatch("([^\n]*)\n") do
		if first_line then first_line = false
		else
			assert(not ended, "events after recording end")
			local item = json.decode(line)
			assert(type(item) == "table", "invalid recording event")
			if item.kind == "end" then
				assert(type(item.at) == "number" and item.at >= 0 and item.at < math.huge, "invalid recording end time")
				fixture.duration, fixture.recording_error, ended = item.at + 3, item.reason, true
			else fixture.events[#fixture.events + 1] = item end
		end
	end
	return fixture
end

function Replay.new(fixture, opts)
	assert(type(fixture) == "table" and type(fixture.events) == "table", "expected replay events array")
	local previous = 0
	for index, item in ipairs(fixture.events) do
		assert(type(item) == "table" and type(item.at) == "number" and item.at >= previous
			and item.at < math.huge, "invalid or unordered event time at " .. index)
		assert(KINDS[item.kind], "unknown replay event kind at " .. index)
		if item.kind == "tool" then
			assert(type(item.event) == "table" and type(item.event.name) == "string", "tool event requires name")
		end
		previous = item.at
	end
	local duration = fixture.duration or previous + 3
	assert(type(duration) == "number" and duration >= previous and duration < math.huge, "invalid replay duration")
	local self = setmetatable({ fixture = fixture, opts = opts or {}, duration = duration,
		speed_index = 3, paused = false }, Replay)
	self:restart()
	return self
end

function Replay:_events_until(target)
	while self.fixture.events[self.next_event] and self.fixture.events[self.next_event].at <= target + 1e-9 do
		local item = self.fixture.events[self.next_event]
		self.now = item.at
		local state = self.app.state
		if item.kind == "submit" then state:submit(item.text or "replay"); self.app.busy = true
		elseif item.kind == "tool" then state:tool_event(item.event)
		elseif item.kind == "waiting" then state:model_waiting(item.text)
		elseif item.kind == "stream" then state:model_stream(item.text)
		elseif item.kind == "activity" then state:model_activity(item.activity)
		elseif item.kind == "reviewing" then state:reviewing(item.info)
		elseif item.kind == "failure" then
			state:notice(item.text, "error"); state.mode = "failed"; self.app.busy = false
		elseif item.kind == "complete" then
			state:assistant_complete(item.text or "done", item.metrics or {})
			self.app.busy = false
		elseif item.kind == "cancel" then state:cancel(item.text or "cancelled"); self.app.busy = false end
		self.next_event = self.next_event + 1
	end
	self.now = target
end

function Replay:restart()
	local old = self.app
	self.now, self.tick, self.next_event, self.accumulator = 0, 0, 1, 0
	self.finished = false
	self.app = tui.App.new({
		backend = old and old.backend or self.opts.backend,
		terminal = old and old.terminal or self.opts.terminal,
		renderer = old and old.renderer or self.opts.renderer,
		editor = old and old.editor,
		state = tui.State.new({ clock = function() return self.now end }),
		effect = self.opts.effect or self.fixture.effect or "drift", tool_stage = true,
	})
	self.app.input = tui.Input.new(self.app.editor)
	self:_events_until(0)
	self.app:advance(0)
end

function Replay:step()
	if self.finished then return end
	self.tick = self.tick + 1
	local target = math.min(self.duration, self.tick * STEP)
	local dt = target - self.now
	self:_events_until(target)
	self.app:advance(dt)
	if target >= self.duration then self.finished = true end
end

function Replay:update(elapsed)
	if not self.paused and not self.finished then
		self.accumulator = self.accumulator + math.max(0, math.min(elapsed, 0.25)) * SPEEDS[self.speed_index]
		while self.accumulator + 1e-9 >= STEP and not self.finished do
			self.accumulator = self.accumulator - STEP
			self:step()
		end
	end
end

function Replay:draw()
	-- Refresh input/layout even while paused, without advancing replay time.
	self.app:advance(0)
	self.app:draw()
end

function Replay:feed_input(chunk)
	for index = 1, #chunk do
		local byte = chunk:sub(index, index)
		local input = self.app.input
		if not input.paste and input.buffer == "" and byte == "\16" then
			self.paused = not self.paused
		elseif not input.paste and input.buffer == "" and byte == "\18" then self:restart()
		elseif not input.paste and input.buffer == "" and byte == "\6" then
			self.speed_index = self.speed_index % #SPEEDS + 1
		elseif not input.paste and input.buffer == "" and byte == "\14" then
			self.paused = true; self:step()
		elseif not input.paste and input.buffer == "" and byte == "\3" then self.app.exit_requested = true
		elseif not input.paste and input.buffer == "" and (byte == "\r" or byte == "\n") then
			-- Drafts are for testing input; replay never submits work.
		else self.app:feed_input(byte) end
	end
end

function Replay:label()
	return string.format("replay %.2fs / %.2fs · %gx · %s", self.now, self.duration,
		SPEEDS[self.speed_index], self.finished and "finished" or self.paused and "paused" or "playing")
end

return Replay
