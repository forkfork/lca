#!/usr/bin/env lua

pcall(require, "luarocks.loader")

local repo = os.getenv("LCA_REPO") or "."
package.path = repo .. "/?.lua;" .. repo .. "/lua/?.lua;" .. repo .. "/lua/?/init.lua;" .. repo .. "/lua/?/?.lua;" .. package.path

local socket = require("socket")
local uv = require("luv")
local transport = require("agent.net.http_transport")

local tmp = os.tmpname() .. "-lca-transport"
assert(os.execute("mkdir -p " .. tmp))
local cert = tmp .. "/cert.pem"
local key = tmp .. "/key.pem"

local function shell_quote(value)
	return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local cert_cmd = table.concat({
	"openssl req -x509 -newkey rsa:2048 -nodes",
	"-keyout", shell_quote(key),
	"-out", shell_quote(cert),
	"-subj", shell_quote("/CN=localhost"),
	"-days 1 >/dev/null 2>&1",
}, " ")
assert(os.execute(cert_cmd))

local next_port = 19080
local function alloc_port()
	next_port = next_port + 1
	return next_port
end

local function write_file(path, body)
	local file = assert(io.open(path, "wb"))
	file:write(body)
	file:close()
end

local function start_server(response, opts)
	opts = opts or {}
	local port = alloc_port()
	local response_path = tmp .. "/response-" .. tostring(port) .. ".txt"
	write_file(response_path, response)

	local stdout = uv.new_pipe()
	local stderr = uv.new_pipe()
	local errbuf = ""
	local handle
	handle = assert(uv.spawn("lua", {
		args = { "tests/http_transport_fixture_server.lua" },
		stdio = { nil, stdout, stderr },
		env = {
			"LCA_FIXTURE_PORT=" .. tostring(port),
			"LCA_FIXTURE_CERT=" .. cert,
			"LCA_FIXTURE_KEY=" .. key,
			"LCA_FIXTURE_RESPONSE=" .. response_path,
			"LCA_FIXTURE_DELAY_FIRST_BYTE=" .. tostring(opts.delay_first_byte or 0),
			"LCA_FIXTURE_DELAY_AFTER_HEADERS=" .. tostring(opts.delay_after_headers or 0),
			"LCA_FIXTURE_REPORT_REQUEST_BODY=" .. (opts.report_request_body and "1" or "0"),
		},
	}, function()
		if stdout and not stdout:is_closing() then stdout:close() end
		if stderr and not stderr:is_closing() then stderr:close() end
		if handle and not handle:is_closing() then handle:close() end
	end))

	local ready = false
	stdout:read_start(function(_, data)
		if data and data:find("ready", 1, true) then
			ready = true
		end
	end)
	stderr:read_start(function(_, data)
		if data then
			errbuf = errbuf .. data
		end
	end)

	local deadline = socket.gettime() + 5
	while not ready and socket.gettime() < deadline do
		uv.run("once")
	end
	assert(ready, "fixture server did not start: " .. errbuf)
	return port, handle
end

local function request(response, opts)
	local port = start_server(response, opts)
	local body = {}
	local result, err = transport.request({
		host = "127.0.0.1",
		port = port,
		path = "/test",
		verify = false,
		body = opts and opts.request_body or "hello",
		deadlines = opts and opts.deadlines or {
			connect = 2,
			tls = 2,
			write = 2,
			first_byte = 2,
			idle = 2,
			total = 5,
		},
		limits = opts and opts.limits or nil,
		headers = {
			{ "Content-Type", "text/plain" },
		},
		cancelled = opts and opts.cancelled or nil,
		on_body_chunk = function(chunk)
			body[#body + 1] = chunk
		end,
	})
	return result, err, table.concat(body)
end

local function cancel_after(seconds)
	local cancelled = false
	local timer = uv.new_timer()
	timer:start(math.floor(seconds * 1000), 0, function()
		cancelled = true
	end)
	return function()
		return cancelled
	end, function()
		if timer and not timer:is_closing() then
			timer:stop()
			timer:close()
		end
	end
end

local tests = {}

local function test(name, fn)
	tests[#tests + 1] = { name = name, fn = fn }
end

test("content length", function()
	local result, err, body = request("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
	assert(not err, err and err.detail)
	assert(result.status == 200)
	assert(body == "ok")
end)

test("chunked with extensions and trailers", function()
	local response = table.concat({
		"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n",
		"2;foo=bar\r\nok\r\n",
		"0\r\nX-Trailer: yes\r\n\r\n",
	})
	local result, err, body = request(response)
	assert(not err, err and err.detail)
	assert(result.status == 200)
	assert(body == "ok")
end)

test("gzip rejected", function()
	local result, err = request("HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 2\r\n\r\nok")
	assert(not result)
	assert(err.kind == "unsupported_encoding")
end)

test("folded header rejected", function()
	local result, err = request("HTTP/1.1 200 OK\r\nX-Test: a\r\n folded\r\nContent-Length: 2\r\n\r\nok")
	assert(not result)
	assert(err.kind == "http")
end)

test("bad chunk size rejected", function()
	local result, err = request("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nwat\r\n")
	assert(not result)
	assert(err.kind == "chunked")
end)

test("header limit", function()
	local result, err = request("HTTP/1.1 200 OK\r\nX-Big: " .. string.rep("x", 200) .. "\r\n\r\n", {
		limits = { header_bytes = 32 },
	})
	assert(not result)
	assert(err.kind == "limit")
end)

test("first byte timeout", function()
	local result, err = request("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok", {
		delay_first_byte = 0.2,
		deadlines = { connect = 2, tls = 2, write = 2, first_byte = 0.05, idle = 2, total = 2 },
	})
	assert(not result)
	assert(err.kind == "timeout")
	assert(err.phase == "first_byte")
end)

test("idle timeout after headers", function()
	local result, err = request("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok", {
		delay_after_headers = 0.2,
		deadlines = { connect = 2, tls = 2, write = 2, first_byte = 2, idle = 0.05, total = 2 },
	})
	assert(not result)
	assert(err.kind == "timeout")
	assert(err.diagnostics)
	assert(err.diagnostics.first_byte_seen == true)
	assert((err.diagnostics.since_last_progress or 0) >= 0)
	assert(err.diagnostics.wait_deadline_kind == "idle")
end)

test("chunk-size timeout reports transport diagnostics", function()
	local result, err = request("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nok\r\n0\r\n\r\n", {
		delay_after_headers = 0.2,
		deadlines = { connect = 2, tls = 2, write = 2, first_byte = 2, idle = 0.05, total = 2 },
	})
	assert(not result)
	assert(err.kind == "timeout")
	assert(err.phase == "chunk_size")
	assert(err.diagnostics)
	assert(err.diagnostics.transfer_encoding == "chunked")
	assert(err.diagnostics.first_byte_seen == true)
	assert((err.diagnostics.since_last_progress or 0) >= 0)
	assert((err.diagnostics.body_chunks or -1) == 0)
	assert(err.diagnostics.wait_phase == "chunk_size")
	assert(err.diagnostics.wait_deadline_kind == "idle")
end)

test("cancel waiting for first byte", function()
	local cancelled, close_cancel = cancel_after(0.05)
	local result, err = request("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok", {
		delay_first_byte = 0.5,
		deadlines = { connect = 2, tls = 2, write = 2, first_byte = 2, idle = 2, total = 3 },
		cancelled = cancelled,
	})
	close_cancel()
	assert(not result)
	assert(err.kind == "cancelled")
	assert(err.phase == "first_byte")
end)

test("cancel waiting for body after headers", function()
	local cancelled, close_cancel = cancel_after(0.05)
	local result, err = request("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok", {
		delay_after_headers = 0.5,
		deadlines = { connect = 2, tls = 2, write = 2, first_byte = 2, idle = 2, total = 3 },
		cancelled = cancelled,
	})
	close_cancel()
	assert(not result)
	assert(err.kind == "cancelled")
end)

test("large request body is fully written", function()
	local size = 2 * 1024 * 1024 + 123
	local large_body = string.rep("x", size)
	local response = table.concat({
		"HTTP/1.1 200 OK\r\n",
		"X-Request-Body-Bytes: {REQUEST_BODY_BYTES}\r\n",
		"Content-Length: 2\r\n",
		"\r\n",
		"ok",
	})
	local result, err, body = request(response, {
		request_body = large_body,
		report_request_body = true,
		deadlines = { connect = 2, tls = 2, write = 10, first_byte = 10, idle = 2, total = 20 },
	})
	assert(not err, err and err.detail)
	assert(result.status == 200)
	assert(body == "ok")
	assert(result.headers["x-request-body-bytes"] == tostring(size), result.headers["x-request-body-bytes"])
end)

local failed = 0
for _, entry in ipairs(tests) do
	local ok, err = xpcall(entry.fn, debug.traceback)
	if ok then
		print("ok " .. entry.name)
	else
		failed = failed + 1
		print("not ok " .. entry.name)
		print(err)
	end
end

os.execute("rm -rf " .. shell_quote(tmp))
if failed > 0 then
	os.exit(1)
end
