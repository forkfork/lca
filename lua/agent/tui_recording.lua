-- Opt-in local capture. Never overwrite an existing file; never dispatch tools.
local uv = require("luv")
local json = require("agent.util.json")
local Recording = {}
Recording.__index = Recording
local LIMIT = 2 * 1024 * 1024
local METHODS = {
	submit = { "submit", "text" }, tool_event = { "tool", "event" },
	model_waiting = { "waiting", "text" }, assistant_complete = { "complete", "text", "metrics" },
	cancel = { "cancel", "text" }, model_stream = { "stream", "text" },
	model_activity = { "activity", "activity" }, reviewing = { "reviewing", "info" },
}

function Recording.open(path, opts)
	opts = opts or {}
	local fd, err
	if not path or path == "" then
		local directory = opts.directory or "/tmp/lca/replays"
		local directories = opts.directory and { directory } or { "/tmp/lca", directory }
		for _, parent in ipairs(directories) do
			local made, mkdir_err = uv.fs_mkdir(parent, tonumber("700", 8))
			if not made then
				local stat = uv.fs_stat(parent)
				if not stat or stat.type ~= "directory" then return nil, mkdir_err end
			end
		end
		local prefix = directory .. "/" .. os.date("%Y%m%d-%H%M%S") .. string.format("-%d", uv.os_getpid())
		for index = 1, 1000 do
			path = prefix .. "-" .. index .. ".jsonl"
			local code
			fd, err, code = uv.fs_open(path, "wx", tonumber("600", 8))
			if fd or code ~= "EEXIST" then break end
		end
	else
		fd, err = uv.fs_open(path, "wx", tonumber("600", 8))
	end
	if not fd then return nil, err end
	local clock = opts.clock or function() return uv.hrtime() / 1e9 end
	local self = setmetatable({ fd = fd, path = path, clock = clock, start = clock(),
		bytes = 0, last_at = 0, limit = opts.limit or LIMIT, on_error = opts.on_error }, Recording)
	local ok = self:_write(json.encode({ format = "lca-tui-replay", version = 1, effect = opts.effect }) .. "\n")
	if not ok then return nil, self.error end
	return self
end

function Recording:_write(text)
	local position = 1
	while position <= #text do
		local written, err = uv.fs_write(self.fd, text:sub(position), self.bytes)
		if not written or written == 0 then
			self.error = tostring(err or "recording write made no progress")
			uv.fs_close(self.fd); self.fd = nil
			return false
		end
		position, self.bytes = position + written, self.bytes + written
	end
	return true
end

function Recording:_time()
	self.last_at = math.max(self.last_at, self.clock() - self.start)
	return self.last_at
end

function Recording:record(kind, fields)
	if not self.fd then return end
	fields = fields or {}
	fields.at, fields.kind = self:_time(), kind
	local ok, encoded = pcall(json.encode, fields)
	if not ok then self.error = "cannot encode replay event"
	elseif self.bytes + #encoded + 1 > self.limit - 256 then self.error = "recording size limit reached"
	else
		if self:_write(encoded .. "\n") then return true end
	end
	self:close()
	if self.on_error then self.on_error(self.error) end
	return false
end

function Recording:attach(state)
	assert(not self.state, "recording already attached")
	self.state, self.originals = state, {}
	for name, spec in pairs(METHODS) do
		local original = state[name]
		self.originals[name] = { rawget(state, name) }
		state[name] = function(target, first, second)
			local fields = { [spec[2]] = first }
			if spec[3] then fields[spec[3]] = second end
			self:record(spec[1], fields)
			return original(target, first, second)
		end
	end
	return self
end

function Recording:close()
	if self.state then
		for name, original in pairs(self.originals) do self.state[name] = original[1] end
		self.state = nil
	end
	if self.fd then
		self:_write(json.encode({ kind = "end", at = self:_time(), reason = self.error }) .. "\n")
		if self.fd then
			local ok, err = uv.fs_close(self.fd)
			self.fd = nil
			if not ok then self.error = tostring(err) end
		end
	end
	return not self.error, self.error
end

return Recording
