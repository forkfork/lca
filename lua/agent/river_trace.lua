-- Per-turn observations only: repeated arguments do not imply wasted work.
local Trace = {}
Trace.__index = Trace
local function canonical(value)
	if type(value) ~= 'table' then return type(value) .. ':' .. tostring(value) end
	local keys, parts = {}, {}
	for key in pairs(value) do keys[#keys + 1] = key end
	table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
	for _, key in ipairs(keys) do parts[#parts + 1] = canonical(key) .. '=' .. canonical(value[key]) end
	-- Length delimiters prevent distinct argument strings from colliding.
	for index, part in ipairs(parts) do parts[index] = #part .. ':' .. part end
	return '{' .. table.concat(parts) .. '}'
end
local function snapshot(value)
	if type(value) ~= 'table' then return value end
	local copy = {}
	for key, item in pairs(value) do copy[key] = snapshot(item) end
	return copy
end
function Trace.new()
	return setmetatable({ calls = {}, active = {}, seen = {}, count = 0, peak = 0, seconds = 0 }, Trace)
end
function Trace:event(event, now)
	if self.finished or not event or not event.name or event.phase == 'progress' then return end
	local key = event.name .. ':' .. canonical(event.args or {})
	local id = event.call_id and tostring(event.call_id)
	if event.phase == 'start' then
		local call = { name = event.name, key = key, id = id, started = now, args = snapshot(event.args or {}),
			repeated = self.seen[key], status = 'active', index = #self.calls + 1 }
		self.seen[key] = call.index
		self.calls[#self.calls + 1] = call
		self.active[#self.active + 1] = call
		if self.count == 0 then self.busy_since = now end
		self.count = self.count + 1
		self.peak = math.max(self.peak, self.count)
		call.overlap = self.count
	else
		for index, call in ipairs(self.active) do
			if (id and call.id == id) or (not id and call.key == key) then
				local result = event.result or {}
				call.status = result.is_error and 'failed' or result.ui_state == 'deferred' and 'deferred' or 'ok'
				call.summary = tostring(result.summary or result.content or '')
				call.elapsed = math.max(0, now - call.started)
				table.remove(self.active, index)
				self.count = self.count - 1
				if self.count == 0 then self.seconds = self.seconds + math.max(0, now - self.busy_since) end
				break
			end
		end
	end
end
function Trace:finish(now)
	if self.finished then return end
	if self.count > 0 then self.seconds = self.seconds + math.max(0, now - self.busy_since) end
	for _, call in ipairs(self.active) do call.status = 'unfinished'; call.elapsed = math.max(0, now - call.started) end
	self.active, self.count, self.finished = {}, 0, true
end
function Trace:summary()
	local summary = { calls = #self.calls, failed = 0, repeated = 0, unfinished = 0, deferred = 0,
		peak = self.peak, seconds = self.seconds, events = self.calls }
	for _, call in ipairs(self.calls) do
		if call.status == 'failed' then summary.failed = summary.failed + 1 end
		if call.status == 'unfinished' then summary.unfinished = summary.unfinished + 1 end
		if call.status == 'deferred' then summary.deferred = summary.deferred + 1 end
		if call.repeated then summary.repeated = summary.repeated + 1 end
	end
	return summary
end
return Trace
