#!/usr/bin/env lua

local script_dir = arg[0]:match("^(.*)/[^/]+$") or "."
local project_dir = script_dir .. "/.."
package.path = project_dir .. "/lua/?.lua;" .. project_dir .. "/lua/?/init.lua;" .. project_dir .. "/lua/?/?.lua;" .. package.path
pcall(require, "luarocks.loader")

local json = require("agent.util.json")

package.loaded["agent.providers"] = {
	credentials_body = function()
		return '{"access":"token","accountId":"acct"}'
	end,
}

local function sse_delta(text)
	return "data: " .. json.encode({
		type = "response.output_text.delta",
		delta = text,
	}) .. "\n\n"
end

package.loaded["agent.net.http_transport"] = {
	request = function(options)
		local chunks = {
			'<tool_call name="ls">\n',
			'{"path":"."}\n',
			"</tool_call>\n",
			'<tool_call name="write">\n',
			'{"path":"agent_flow_tui.py"}\n',
			"#!/usr/bin/env python3\n",
			"print('still streaming')\n",
		}
		local response_bytes = 0
		for _, chunk in ipairs(chunks) do
			local body = sse_delta(chunk)
			response_bytes = response_bytes + #body
			options.on_body_chunk(body)
		end
		return nil, {
			kind = "timeout",
			phase = "chunk_size",
			detail = "chunk_size",
			response_bytes = response_bytes,
			body_tail = "",
			timings = {
				connect = 0.001,
				tls = 0.001,
				write = 0.001,
				first_byte = 0.01,
			},
		}
	end,
}

local codex = require("agent.providers.codex")

local passed = 0
local failed = 0

local function green(s) return "\27[32m" .. s .. "\27[0m" end
local function red(s) return "\27[31m" .. s .. "\27[0m" end
local function dim(s) return "\27[2m" .. s .. "\27[0m" end

local function test(name, fn)
	io.write("  " .. name .. " ")
	io.flush()
	local ok, err = pcall(fn)
	if ok then
		passed = passed + 1
		io.write(green("PASS") .. "\n")
	else
		failed = failed + 1
		io.write(red("FAIL") .. " (" .. tostring(err):sub(1, 120) .. ")\n")
	end
end

local function assert_eq(actual, expected, msg)
	if actual ~= expected then
		error((msg or "") .. " expected: " .. tostring(expected) .. ", got: " .. tostring(actual))
	end
end

io.write("\n" .. dim("═══ Codex Partial Stream Tests ═══") .. "\n\n")

test("mid-stream timeout returns salvaged complete tool calls", function()
	local response = codex.complete({
		credentials_path = "/tmp/lca-test-credentials.json",
		session_id = "partial-stream-test",
		model = "gpt-5.5",
		system_prompt = "You are a test model.",
		messages = {
			{ role = "user", text = "create the app" },
		},
		max_retries = 0,
	})
	assert(response.text:find('<tool_call name="ls">', 1, true), "missing salvaged ls call")
	assert(response.text:find('"path":"."', 1, true), "missing ls args")
	if response.text:find("agent_flow_tui.py", 1, true) then
		error("incomplete write leaked into salvaged response: " .. response.text)
	end
	assert_eq(response._partial_salvage, true)
	assert_eq(response._partial_salvaged_calls, 1)
	assert_eq(response._usage_status, "early_cutoff")
end)

io.write("\n" .. dim("─────────────────────────────────────") .. "\n")
io.write(string.format("  %s passed, %s failed\n",
	green(tostring(passed)), failed > 0 and red(tostring(failed)) or tostring(failed)))
io.write("\n")
os.exit(failed > 0 and 1 or 0)
