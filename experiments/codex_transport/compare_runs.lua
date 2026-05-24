#!/usr/bin/env lua

pcall(require, "luarocks.loader")

local repo = os.getenv("LCA_REPO") or "."
package.path = repo .. "/?.lua;" .. repo .. "/lua/?.lua;" .. repo .. "/lua/?/init.lua;" .. repo .. "/lua/?/?.lua;" .. package.path

local socket = require("socket")
local provider = require("agent.providers.codex")

local runs = tonumber(os.getenv("LCA_RUNS") or "5")
local prompt = os.getenv("LCA_PROMPT") or "Reply with exactly: ok"

local function messages()
	if os.getenv("LCA_PROBE_MODE") ~= "session" then
		return {
			{ role = "user", text = prompt },
		}
	end
	local path = os.getenv("LCA_SESSION") or ".lca-session.json"
	local file = assert(io.open(path, "r"))
	local raw = file:read("*a")
	file:close()
	local decoded = require("cjson").decode(raw)
	local loaded = decoded.messages or {}
	loaded[#loaded + 1] = { role = "user", text = prompt }
	return loaded
end

local failures = 0
for i = 1, runs do
	local started = socket.gettime()
	local streamed = {}
	local ok, result = pcall(provider.complete, {
		model = os.getenv("LCA_MODEL") or "gpt-5.5",
		system_prompt = "You are a helpful assistant.",
		messages = messages(),
		deadlines = {
			first_byte = tonumber(os.getenv("LCA_FIRST_BYTE_TIMEOUT") or "") or nil,
			total = tonumber(os.getenv("LCA_TOTAL_TIMEOUT") or "") or nil,
		},
		max_retries = tonumber(os.getenv("LCA_MAX_RETRIES") or "") or nil,
		cancelled = function()
			return false
		end,
	}, function(delta)
		streamed[#streamed + 1] = delta
	end)
	local total = socket.gettime() - started
	if ok then
		io.write(string.format(
			"run=%d status=%s first_byte=%.3fs total=%.3fs bytes=%s text=%q streamed=%q\n",
			i,
			tostring(result._http_status),
			result._timings.first_byte or 0,
			total,
			tostring(result._response_bytes),
			result.text,
			table.concat(streamed)
		))
	else
		failures = failures + 1
		io.write(string.format(
			"run=%d error=%s total=%.3fs\n",
			i,
			tostring(result),
			total
		))
	end
	io.flush()
end

if failures > 0 then
	os.exit(1)
end
