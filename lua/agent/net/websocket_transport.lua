local socket = require("socket")
local ssl = require("ssl")

local ws = {}
local WEBSOCKET_POLL_SECONDS = 0.08

local function now()
	return socket.gettime()
end

local function fail(kind, detail, phase, state)
	error({
		_transport_error = true,
		kind = kind,
		detail = tostring(detail),
		phase = phase,
		timings = state and state.timings or nil,
		response_bytes = state and state.response_bytes or 0,
		status = state and state.status or nil,
		body_tail = state and state.body_tail or "",
		diagnostics = {
			elapsed = state and state.started_at and (now() - state.started_at) or nil,
			first_byte_seen = state and state.first_byte_seen or false,
			wait_phase = phase,
			wait_mode = "websocket",
			wait_deadline_kind = phase,
		},
	}, 0)
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function base64(data)
	local out = {}
	for i = 1, #data, 3 do
		local a = data:byte(i) or 0
		local b = data:byte(i + 1) or 0
		local c = data:byte(i + 2) or 0
		local n = (a << 16) | (b << 8) | c
		out[#out + 1] = B64:sub(((n >> 18) & 63) + 1, ((n >> 18) & 63) + 1)
		out[#out + 1] = B64:sub(((n >> 12) & 63) + 1, ((n >> 12) & 63) + 1)
		out[#out + 1] = i + 1 <= #data and B64:sub(((n >> 6) & 63) + 1, ((n >> 6) & 63) + 1) or "="
		out[#out + 1] = i + 2 <= #data and B64:sub((n & 63) + 1, (n & 63) + 1) or "="
	end
	return table.concat(out)
end

local function random_bytes(n)
	local file = io.open("/dev/urandom", "rb")
	if file then
		local data = file:read(n)
		file:close()
		if data and #data == n then
			return data
		end
	end
	local out = {}
	local seed = tostring(now()) .. ":" .. tostring({}) .. ":" .. tostring(math.random())
	for i = 1, n do
		local byte = (seed:byte(((i - 1) % #seed) + 1) + i * 37 + math.random(0, 255)) & 255
		out[i] = string.char(byte)
	end
	return table.concat(out)
end

local function close_socket(sock)
	if sock then
		pcall(function() sock:close() end)
	end
end

local function notify_wait(opts, phase)
	if opts and opts.on_wait then
		pcall(opts.on_wait, phase)
	end
end

local function read_exact(sock, n, state, phase, timeout_sec, opts)
	local deadline = now() + timeout_sec
	local chunks = {}
	local got = 0
	while got < n do
		if opts.cancelled and opts.cancelled() then
			fail("cancelled", phase, phase, state)
		end
		local chunk, err, partial = sock:receive(n - got)
		chunk = chunk or partial
		if chunk and #chunk > 0 then
			if not state.first_byte_seen then
				state.first_byte_seen = true
				state.timings.first_byte = now() - state.started_at
			end
			state.response_bytes = state.response_bytes + #chunk
			chunks[#chunks + 1] = chunk
			got = got + #chunk
		elseif err == "timeout" or err == "wantread" or err == "wantwrite" then
			if now() >= deadline then
				fail("timeout", phase, phase, state)
			end
			notify_wait(opts, phase)
		else
			fail("stream", err or "closed", phase, state)
		end
	end
	return table.concat(chunks)
end

local function send_all(sock, data, state, phase, timeout_sec, opts)
	local deadline = now() + timeout_sec
	local index = 1
	while index <= #data do
		if opts.cancelled and opts.cancelled() then
			fail("cancelled", phase, phase, state)
		end
		local sent, err, partial = sock:send(data, index)
		if sent then
			index = sent + 1
		elseif partial and partial >= index then
			index = partial + 1
		elseif err == "timeout" or err == "wantread" or err == "wantwrite" then
			if now() >= deadline then
				fail("timeout", phase, phase, state)
			end
			notify_wait(opts, phase)
		else
			fail("write", err or "send failed", phase, state)
		end
	end
end

local function ca_params()
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

local function connect_tls(opts, state)
	local t0 = now()
	local tcp, err = socket.tcp()
	if not tcp then
		fail("socket", err or "failed to create tcp socket", "connect", state)
	end
	tcp:settimeout(opts.deadlines.connect)
	local ok
	ok, err = tcp:connect(opts.host, opts.port or 443)
	if not ok then
		fail("connect", err, "connect", state)
	end
	state.timings.connect = now() - t0

	t0 = now()
	local cafile, capath = ca_params()
	local wrapped
	wrapped, err = ssl.wrap(tcp, {
		mode = "client",
		protocol = "any",
		options = { "all", "no_sslv2", "no_sslv3", "no_tlsv1" },
		verify = opts.verify == false and "none" or "peer",
		server = opts.host,
		cafile = cafile,
		capath = capath,
	})
	if not wrapped then
		fail("tls_wrap", err, "tls", state)
	end
	if wrapped.sni then
		local sni_ok, sni_err = wrapped:sni(opts.host)
		if not sni_ok and sni_err then
			fail("tls_sni", sni_err, "tls", state)
		end
	end
	wrapped:settimeout(opts.deadlines.tls)
	ok, err = wrapped:dohandshake()
	if not ok then
		fail("tls_handshake", err, "tls", state)
	end
	wrapped:settimeout(WEBSOCKET_POLL_SECONDS)
	state.timings.tls = now() - t0
	return wrapped
end

local function header_lines(headers)
	local out = {}
	for _, header in ipairs(headers or {}) do
		out[#out + 1] = tostring(header[1]) .. ": " .. tostring(header[2])
	end
	return table.concat(out, "\r\n")
end

local function websocket_handshake(sock, opts, state)
	local key = base64(random_bytes(16))
	local headers = {
		{ "Host", opts.host },
		{ "Upgrade", "websocket" },
		{ "Connection", "Upgrade" },
		{ "Sec-WebSocket-Version", "13" },
		{ "Sec-WebSocket-Key", key },
		{ "User-Agent", opts.user_agent or "lca-codex/websocket" },
	}
	for _, header in ipairs(opts.headers or {}) do
		local name = tostring(header[1])
		if not name:lower():match("^sec%-websocket%-")
			and name:lower() ~= "host"
			and name:lower() ~= "connection"
			and name:lower() ~= "upgrade" then
			headers[#headers + 1] = header
		end
	end

	local request = table.concat({
		"GET " .. opts.path .. " HTTP/1.1",
		header_lines(headers),
		"\r\n",
	}, "\r\n")
	send_all(sock, request, state, "write", opts.deadlines.write, opts)

	local deadline = now() + opts.deadlines.first_byte
	local response = ""
	while not response:find("\r\n\r\n", 1, true) do
		if opts.cancelled and opts.cancelled() then
			fail("cancelled", "headers", "headers", state)
		end
		local chunk, err, partial = sock:receive(1)
		chunk = chunk or partial
		if chunk and #chunk > 0 then
			if not state.first_byte_seen then
				state.first_byte_seen = true
				state.timings.first_byte = now() - state.started_at
			end
			response = response .. chunk
			state.response_bytes = state.response_bytes + #chunk
			if #response > 65536 then
				fail("headers", "websocket handshake headers too large", "headers", state)
			end
		elseif err == "timeout" or err == "wantread" or err == "wantwrite" then
			if now() >= deadline then
				fail("timeout", "headers", "headers", state)
			end
			notify_wait(opts, "headers")
		else
			fail("headers", err or "closed", "headers", state)
		end
	end
	state.timings.headers = now() - state.started_at
	local status = tonumber(response:match("^HTTP/%d%.%d%s+(%d+)"))
	state.status = status
	if status ~= 101 then
		state.body_tail = response:sub(1, 4000)
		fail("http", "websocket upgrade failed: " .. tostring(status), "headers", state)
	end
end

local function encode_len(len)
	if len < 126 then
		return string.char(0x80 | len)
	elseif len <= 0xffff then
		return string.char(0x80 | 126, (len >> 8) & 255, len & 255)
	end
	local hi = len // 0x100000000
	local lo = len % 0x100000000
	return string.char(
		0x80 | 127,
		(hi >> 24) & 255, (hi >> 16) & 255, (hi >> 8) & 255, hi & 255,
		(lo >> 24) & 255, (lo >> 16) & 255, (lo >> 8) & 255, lo & 255
	)
end

local function mask_payload(payload, mask)
	local out = {}
	local m1, m2, m3, m4 = mask:byte(1, 4)
	local masks = { m1, m2, m3, m4 }
	for i = 1, #payload do
		out[i] = string.char(payload:byte(i) ~ masks[((i - 1) % 4) + 1])
	end
	return table.concat(out)
end

local function send_text(sock, text, state, opts)
	local mask = random_bytes(4)
	local frame = string.char(0x81) .. encode_len(#text) .. mask .. mask_payload(text, mask)
	local t0 = now()
	send_all(sock, frame, state, "write", opts.deadlines.write, opts)
	state.timings.write = (state.timings.write or 0) + (now() - t0)
end

local function read_u16(bytes)
	local a, b = bytes:byte(1, 2)
	return (a << 8) | b
end

local function read_u64(bytes)
	local n = 0
	for i = 1, 8 do
		n = n * 256 + bytes:byte(i)
	end
	return n
end

local function read_frame(sock, state, opts)
	local head = read_exact(sock, 2, state, "read", opts.deadlines.idle, opts)
	local b1, b2 = head:byte(1, 2)
	local fin = (b1 & 0x80) ~= 0
	local opcode = b1 & 0x0f
	local masked = (b2 & 0x80) ~= 0
	local len = b2 & 0x7f
	if len == 126 then
		len = read_u16(read_exact(sock, 2, state, "read", opts.deadlines.idle, opts))
	elseif len == 127 then
		len = read_u64(read_exact(sock, 8, state, "read", opts.deadlines.idle, opts))
	end
	local mask = masked and read_exact(sock, 4, state, "read", opts.deadlines.idle, opts) or nil
	local payload = len > 0 and read_exact(sock, len, state, "read", opts.deadlines.idle, opts) or ""
	if mask then
		payload = mask_payload(payload, mask)
	end
	return fin, opcode, payload
end

local function normalize_deadlines(opts)
	local deadlines = opts.deadlines or {}
	deadlines.connect = deadlines.connect or 15
	deadlines.tls = deadlines.tls or 15
	deadlines.write = deadlines.write or 15
	deadlines.first_byte = deadlines.first_byte or 45
	deadlines.idle = deadlines.idle or 300
	opts.deadlines = deadlines
end

function ws.connect(opts)
	normalize_deadlines(opts)

	local state = {
		started_at = now(),
		timings = {},
		response_bytes = 0,
		body_tail = "",
		first_byte_seen = false,
	}

	local sock
	local ok, result = pcall(function()
		sock = connect_tls(opts, state)
		websocket_handshake(sock, opts, state)
		state.timings.total = now() - state.started_at
		local conn = {}
		conn.state = state
		function conn:request(body, on_text)
			local request_started_at = now()
			local response_bytes_before = self.state.response_bytes
			self.state.body_tail = ""
			send_text(sock, body, self.state, opts)
			local text_parts = {}
			while true do
				local fin, opcode, payload = read_frame(sock, self.state, opts)
				if opcode == 0x8 then
					fail("stream", "websocket closed", "read", self.state)
				elseif opcode == 0x9 then
					-- pong, masked as required for client frames
					local mask = random_bytes(4)
					local frame = string.char(0x8a) .. encode_len(#payload) .. mask .. mask_payload(payload, mask)
					send_all(sock, frame, self.state, "write", opts.deadlines.write, opts)
				elseif opcode == 0x1 or opcode == 0x0 then
					text_parts[#text_parts + 1] = payload
					if fin then
						local text = table.concat(text_parts)
						text_parts = {}
						if on_text and on_text(text) == false then
							break
						end
					end
				elseif opcode == 0x2 then
					fail("stream", "unexpected binary websocket frame", "read", self.state)
				end
			end
			self.state.timings.total = now() - request_started_at
			return {
				status = self.state.status or 101,
				response_bytes = self.state.response_bytes - response_bytes_before,
				body_tail = self.state.body_tail,
				timings = self.state.timings,
			}
		end
		function conn.close()
			close_socket(sock)
			sock = nil
		end
		return conn
	end)

	if ok then
		return result
	end
	close_socket(sock)
	if type(result) == "table" and result._transport_error then
		return nil, result
	end
	error(result)
end

function ws.request(opts)
	normalize_deadlines(opts)
	local conn, err = ws.connect(opts)
	if not conn then
		return nil, err
	end
	local ok, result = pcall(function()
		return conn:request(opts.body, opts.on_text)
	end)
	conn:close()
	if ok then
		return result
	end
	if type(result) == "table" and result._transport_error then
		return nil, result
	end
	error(result)
end

return ws
