local socket = require("socket")
local ssl = require("ssl")
local uv = require("luv")

local transport = {}

local DEFAULT_DEADLINES = {
	connect = 15,
	tls = 15,
	write = 15,
	first_byte = 45,
	idle = 60,
	total = 130,
}

local DEFAULT_LIMITS = {
	header_bytes = 64 * 1024,
	line_bytes = 8 * 1024,
	body_tail_bytes = 4000,
}

local function now()
	return socket.gettime()
end

local function close_handle(handle)
	if handle and not handle:is_closing() then
		handle:close()
	end
end

local function fd_for(sock)
	if not sock.getfd then
		return nil
	end
	local fd = sock:getfd()
	if type(fd) == "number" and fd >= 0 then
		return fd
	end
	return nil
end

local function merge_deadlines(values)
	local deadlines = {}
	for key, value in pairs(DEFAULT_DEADLINES) do
		deadlines[key] = value
	end
	for key, value in pairs(values or {}) do
		deadlines[key] = value
	end
	return deadlines
end

local function merge_limits(values)
	local limits = {}
	for key, value in pairs(DEFAULT_LIMITS) do
		limits[key] = value
	end
	for key, value in pairs(values or {}) do
		limits[key] = value
	end
	return limits
end

local Connection = {}
Connection.__index = Connection

function Connection:fail(kind, detail, phase)
	error({
		_transport_error = true,
		kind = kind,
		detail = tostring(detail),
		phase = phase,
		timings = self.timings,
		response_bytes = self.response_bytes,
		status = self.status,
		body_tail = self.body_tail,
	}, 0)
end

function Connection:is_cancelled()
	return self.cancel_fn and self.cancel_fn() or false
end

function Connection:wait(sock, mode, deadline, phase)
	local fd = fd_for(sock)
	if not fd then
		self:fail("poll", "socket has no fd", phase)
	end

	if self.poll_fd ~= fd then
		close_handle(self.poll)
		self.poll = nil
		self.poll_fd = nil
	end
	if not self.poll then
		local poll, poll_err = uv.new_poll(fd)
		if not poll then
			self:fail("poll", poll_err, phase)
		end
		self.poll = poll
		self.poll_fd = fd
	end
	if not self.timer then
		self.timer = uv.new_timer()
	end

	local poll = self.poll
	local timer = self.timer
	local done = false
	local failed = nil

	local function finish(err)
		if done then
			return
		end
		done = true
		failed = err
		pcall(function() poll:stop() end)
		pcall(function() timer:stop() end)
	end

	local remaining_ms = math.max(0, math.floor((deadline - now()) * 1000))
	if remaining_ms <= 0 then
		finish("timeout")
	else
		timer:start(remaining_ms, 0, function()
			finish("timeout")
		end)
		poll:start(mode == "read" and "r" or "w", function(err)
			finish(err)
		end)
	end

	while not done do
		if self:is_cancelled() then
			finish("cancelled")
			break
		end
		uv.run("once")
	end

	uv.run("nowait")
	if failed == "timeout" then
		self:fail("timeout", phase, phase)
	elseif failed == "cancelled" then
		self:fail("cancelled", phase, phase)
	elseif failed then
		self:fail("poll", failed, phase)
	end
end

function Connection:ca_params()
	local cafile = self.cafile
	local capath = self.capath
	if cafile or capath then
		return cafile, capath
	end

	local candidates = {
		"/etc/ssl/certs/ca-certificates.crt",
		"/etc/pki/tls/certs/ca-bundle.crt",
		"/etc/ssl/cert.pem",
	}
	for _, path in ipairs(candidates) do
		local file = io.open(path, "r")
		if file then
			file:close()
			return path, nil
		end
	end
	return nil, "/etc/ssl/certs"
end

function Connection:connect()
	local t0 = now()
	local tcp, create_err = socket.tcp()
	if not tcp then
		self:fail("socket", create_err or "failed to create tcp socket", "connect")
	end
	tcp:settimeout(0)

	local deadline = now() + self.deadlines.connect
	local ok, err = tcp:connect(self.host, self.port)
	if ok or err == "already connected" then
		self.tcp = tcp
		self.timings.connect = now() - t0
		return tcp
	end
	if err ~= "timeout" and err ~= "Operation already in progress" then
		self:fail("connect", err, "connect")
	end

	while true do
		self:wait(tcp, "write", deadline, "connect")
		ok, err = tcp:connect(self.host, self.port)
		if ok or err == "already connected" then
			self.tcp = tcp
			self.timings.connect = now() - t0
			return tcp
		end
		if err ~= "timeout" and err ~= "Operation already in progress" then
			self:fail("connect", err, "connect")
		end
	end
end

function Connection:handshake(tcp)
	local t0 = now()
	local cafile, capath = self:ca_params()
	local wrapped, err = ssl.wrap(tcp, {
		mode = "client",
		protocol = "any",
		options = { "all", "no_sslv2", "no_sslv3", "no_tlsv1" },
		verify = self.verify == false and "none" or "peer",
		server = self.host,
		cafile = cafile,
		capath = capath,
	})
	if not wrapped then
		self:fail("tls_wrap", err, "tls")
	end
	if wrapped.sni then
		local sni_ok, sni_err = wrapped:sni(self.host)
		if not sni_ok and sni_err then
			self:fail("tls_sni", sni_err, "tls")
		end
	end
	wrapped:settimeout(0)

	local deadline = now() + self.deadlines.tls
	while true do
		local ok, handshake_err = wrapped:dohandshake()
		if ok then
			self.sock = wrapped
			self.timings.tls = now() - t0
			return wrapped
		end
		if handshake_err == "wantread" or handshake_err == "timeout" then
			self:wait(wrapped, "read", deadline, "tls")
		elseif handshake_err == "wantwrite" then
			self:wait(wrapped, "write", deadline, "tls")
		else
			self:fail("tls_handshake", handshake_err, "tls")
		end
	end
end

function Connection:send_all(data)
	local t0 = now()
	local deadline = now() + self.deadlines.write
	local index = 1
	while index <= #data do
		if self:is_cancelled() then
			self:fail("cancelled", "write", "write")
		end
		local sent, err, partial = self.sock:send(data, index)
		if sent then
			index = sent + 1
		elseif err == "timeout" or err == "wantwrite" then
			if partial and partial >= index then
				index = partial + 1
			end
			self:wait(self.sock, "write", deadline, "write")
		elseif err == "wantread" then
			self:wait(self.sock, "read", deadline, "write")
		else
			self:fail("write", err, "write")
		end
	end
	self.timings.write = now() - t0
end

function Connection:receive_some(phase)
	if self:is_cancelled() then
		self:fail("cancelled", phase, phase)
	end
	local data, err, partial = self.sock:receive(8192)
	local chunk = data or partial
	if chunk and #chunk > 0 then
		local current = now()
		if not self.first_byte_at then
			self.first_byte_at = current
			self.timings.first_byte = current - self.started_at
		end
		self.last_progress_at = current
		self.response_bytes = self.response_bytes + #chunk
		return chunk
	end
	if err == "closed" then
		return nil, "closed"
	end
	if err == "timeout" or err == "wantread" then
		return nil, "timeout"
	end
	if err == "wantwrite" then
		return nil, "wantwrite"
	end
	self:fail("read", err, phase)
end

function Connection:read_controlled(phase)
	while true do
		local chunk, err = self:receive_some(phase)
		if chunk then
			return chunk
		end
		if err == "closed" then
			return nil
		end

		local deadline
		if not self.first_byte_at then
			deadline = self.started_at + self.deadlines.first_byte
			phase = "first_byte"
		else
			deadline = math.min(
				self.started_at + self.deadlines.total,
				(self.last_progress_at or now()) + self.deadlines.idle
			)
		end
		self:wait(self.sock, err == "wantwrite" and "write" or "read", deadline, phase)
	end
end

function Connection:ensure_buffer(n, phase)
	while #self.read_buffer < n do
		local chunk = self:read_controlled(phase)
		if not chunk then
			return false
		end
		self.read_buffer = self.read_buffer .. chunk
	end
	return true
end

function Connection:read_until(marker, phase, limit)
	while true do
		local pos = self.read_buffer:find(marker, 1, true)
		if pos then
			local value = self.read_buffer:sub(1, pos - 1)
			self.read_buffer = self.read_buffer:sub(pos + #marker)
			return value
		end
		if limit and #self.read_buffer > limit then
			self:fail("limit", phase .. " exceeded " .. tostring(limit) .. " bytes", phase)
		end
		local chunk = self:read_controlled(phase)
		if not chunk then
			self:fail("closed", "before " .. phase, phase)
		end
		self.read_buffer = self.read_buffer .. chunk
		if limit and #self.read_buffer > limit then
			self:fail("limit", phase .. " exceeded " .. tostring(limit) .. " bytes", phase)
		end
	end
end

function Connection:read_exact(n, phase)
	if not self:ensure_buffer(n, phase) then
		self:fail("closed", "during " .. phase, phase)
	end
	local value = self.read_buffer:sub(1, n)
	self.read_buffer = self.read_buffer:sub(n + 1)
	return value
end

local function parse_headers(raw)
	local lines = {}
	for line in (raw .. "\r\n"):gmatch("(.-)\r\n") do
		lines[#lines + 1] = line
	end
	local status_line = lines[1] or ""
	local status = tonumber(status_line:match("^HTTP/%d%.%d%s+(%d%d%d)"))
	if not status then
		return nil, "bad status line: " .. status_line
	end
	local headers = {}
	for i = 2, #lines do
		if lines[i]:find("^[ \t]") then
			return nil, "folded headers are not supported"
		end
		local name, value = lines[i]:match("^([^:]+):%s*(.*)$")
		if name then
			local key = name:lower()
			if key == "content-length" and headers[key] and headers[key] ~= value then
				return nil, "conflicting content-length headers"
			end
			headers[key] = headers[key] and (headers[key] .. ", " .. value) or value
		end
	end
	return {
		status = status,
		status_line = status_line,
		headers = headers,
	}
end

function Connection:read_chunk_trailers()
	while true do
		local line = self:read_until("\r\n", "chunk_trailers", self.limits.line_bytes)
		if line == "" then
			return
		end
		if line:find("^[ \t]") then
			self:fail("chunked", "folded chunk trailers are not supported", "body")
		end
		if not line:match("^[^:]+:%s*.*$") then
			self:fail("chunked", "bad chunk trailer: " .. line, "body")
		end
	end
end

function Connection:next_body_chunk(headers)
	local transfer = (headers["transfer-encoding"] or ""):lower()
	if transfer:find("chunked", 1, true) then
		local size_line = self:read_until("\r\n", "chunk_size", self.limits.line_bytes)
		local hex = size_line:match("^%s*([0-9a-fA-F]+)")
		if not hex then
			self:fail("chunked", "bad chunk size: " .. size_line, "body")
		end
		local size = tonumber(hex, 16)
		if size == 0 then
			self:read_chunk_trailers()
			return nil
		end
		local data = self:read_exact(size, "chunk_body")
		local crlf = self:read_exact(2, "chunk_terminator")
		if crlf ~= "\r\n" then
			self:fail("chunked", "bad chunk terminator", "body")
		end
		return data
	end

	local content_length = tonumber(headers["content-length"] or "")
	if content_length then
		if content_length == 0 then
			return nil
		end
		local data = self:read_exact(content_length, "body")
		headers["content-length"] = "0"
		return data
	end

	return self:read_controlled("body")
end

local function header_lines(headers)
	local lines = {}
	for _, header in ipairs(headers or {}) do
		lines[#lines + 1] = tostring(header[1]) .. ": " .. tostring(header[2]) .. "\r\n"
	end
	return table.concat(lines)
end

function Connection:request_bytes()
	local headers = {
		{ "Host", self.host },
		{ "User-Agent", self.user_agent or "lca-transport-probe/0" },
		{ "Accept-Encoding", "identity" },
		{ "Content-Length", tostring(#self.body) },
		{ "Connection", "close" },
	}
	for _, header in ipairs(self.headers or {}) do
		headers[#headers + 1] = header
	end
	return table.concat({
		self.method .. " " .. self.path .. " HTTP/1.1\r\n",
		header_lines(headers),
		"\r\n",
		self.body,
	})
end

function Connection:run()
	self:handshake(self:connect())
	self:send_all(self:request_bytes())

	local raw_headers = self:read_until("\r\n\r\n", "headers", self.limits.header_bytes)
	self.timings.headers = now() - self.started_at
	local parsed, parse_err = parse_headers(raw_headers)
	if not parsed then
		self:fail("http", parse_err, "headers")
	end
	self.status = parsed.status
	if self.on_headers then
		self.on_headers({
			status = parsed.status,
			status_line = parsed.status_line,
			headers = parsed.headers,
			timings = self.timings,
		})
	end

	local encoding = (parsed.headers["content-encoding"] or "identity"):lower()
	if encoding ~= "identity" then
		self:fail("unsupported_encoding", encoding, "headers")
	end

	while true do
		local chunk = self:next_body_chunk(parsed.headers)
		if not chunk then
			break
			end
			self.body_tail = (self.body_tail .. chunk):sub(-self.body_tail_limit)
			if self.on_body_chunk then
				if self.on_body_chunk(chunk) == false then
					break
				end
			end
		end

	self.timings.total = now() - self.started_at
	return {
		status = parsed.status,
		status_line = parsed.status_line,
		headers = parsed.headers,
		body_tail = self.body_tail,
		response_bytes = self.response_bytes,
		timings = self.timings,
	}
end

function Connection:close()
	if self.poll then
		pcall(function() self.poll:stop() end)
		close_handle(self.poll)
		self.poll = nil
	end
	if self.timer then
		pcall(function() self.timer:stop() end)
		close_handle(self.timer)
		self.timer = nil
	end
	if self.sock then
		pcall(function() self.sock:close() end)
	end
	if self.tcp then
		pcall(function() self.tcp:close() end)
	end
end

function transport.request(options)
	local conn = setmetatable({
		host = assert(options.host, "host is required"),
		port = options.port or 443,
		path = options.path or "/",
		method = options.method or "POST",
		headers = options.headers or {},
		body = options.body or "",
		user_agent = options.user_agent,
		deadlines = merge_deadlines(options.deadlines),
		limits = merge_limits(options.limits),
		cancel_fn = options.cancelled,
		cafile = options.cafile,
		capath = options.capath,
		verify = options.verify,
		on_headers = options.on_headers,
		on_body_chunk = options.on_body_chunk,
		body_tail_limit = options.body_tail_limit
			or (options.limits and options.limits.body_tail_bytes)
			or DEFAULT_LIMITS.body_tail_bytes,
		started_at = now(),
		timings = {},
		read_buffer = "",
		body_tail = "",
		response_bytes = 0,
	}, Connection)

	local ok, result = pcall(function()
		return conn:run()
	end)
	conn:close()

	if ok then
		return result
	end
	if type(result) == "table" and result._transport_error then
		return nil, result
	end
	return nil, {
		_transport_error = true,
		kind = "internal",
		detail = tostring(result),
		timings = conn.timings,
		response_bytes = conn.response_bytes,
		status = conn.status,
		body_tail = conn.body_tail,
	}
end

return transport
