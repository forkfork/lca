#!/usr/bin/env lua

local script_dir = arg[0]:match("^(.*)/[^/]+$") or "."
local project_dir = script_dir .. "/.."
package.path = project_dir .. "/lua/?.lua;" .. project_dir .. "/lua/?/init.lua;" .. project_dir .. "/lua/?/?.lua;" .. package.path
pcall(require, "luarocks.loader")

local socket = require("socket")
local transport = require("agent.net.websocket_transport")

local original_gettime = socket.gettime
local clock = 100
socket.gettime = function()
	clock = clock + 0.1
	return clock
end

local fake_socket = {}
function fake_socket:receive()
	return nil, "timeout", ""
end

local state = {
	started_at = 100,
	request_deadline = 100.35,
	timings = {},
	response_bytes = 0,
	first_byte_seen = false,
}

local ok, err = pcall(function()
	transport._test.read_exact(fake_socket, 1, state, "read", 60, {})
end)

socket.gettime = original_gettime

assert(not ok, "read should stop at the absolute request deadline")
assert(type(err) == "table" and err._transport_error, "expected structured transport error")
assert(err.kind == "timeout", "expected timeout kind")
assert(err.phase == "total", "expected total deadline, got " .. tostring(err.phase))

print("ok - websocket reads honor the absolute request deadline")
