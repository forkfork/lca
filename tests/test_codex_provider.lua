#!/usr/bin/env lua

local script_dir = arg[0]:match("^(.*)/[^/]+$") or "."
local project_dir = script_dir .. "/.."
package.path = project_dir .. "/lua/?.lua;" .. project_dir .. "/lua/?/init.lua;" .. project_dir .. "/lua/?/?.lua;" .. package.path
pcall(require, "luarocks.loader")

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

io.write("\n" .. dim("═══ Codex Provider Tests ═══") .. "\n\n")

test("request body uses session-specific prompt cache key", function()
	local body = codex._request_body({
		session_id = "lca-session-123",
		messages = {
			{ role = "user", text = "hi" },
		},
	})
	if not body:find('"prompt_cache_key":"lca-session-123"', 1, true) then
		error("missing session prompt cache key: " .. body)
	end
end)

test("native request body declares function tools", function()
	local json = require("agent.util.json")
	local body = json.decode(codex._request_body({
		session_id = "lca-native-123",
		native_tool_calling = true,
		messages = { { role = "user", text = "inspect this project" } },
	}))
	assert_eq(body.tool_choice, "auto")
	assert_eq(body.parallel_tool_calls, true)
	assert(type(body.tools) == "table" and #body.tools >= 13, "missing native tool definitions")
	local by_name = {}
	local by_type = {}
	for _, tool in ipairs(body.tools) do
		if tool.name then by_name[tool.name] = tool end
		by_type[tool.type] = tool
	end
	assert(by_name.read and by_name.read.parameters.required[1] == "path", "read schema missing required path")
	assert(by_name.edit and by_name.edit.parameters.properties.content.type == "string", "edit schema missing content")
	assert(by_type.web_search, "missing hosted web search tool")
end)

test("request body can isolate a background reviewer to hosted search", function()
	local json = require("agent.util.json")
	local web_only = json.decode(codex._request_body({
		tool_scope = "web_only",
		messages = { { role = "user", text = "research this mechanism" } },
	}))
	assert_eq(#web_only.tools, 1)
	assert_eq(web_only.tools[1].type, "web_search")
	assert_eq(web_only.tool_choice, "auto")
	local no_tools = json.decode(codex._request_body({
		tool_scope = "none",
		messages = { { role = "user", text = "review this packet" } },
	}))
	assert_eq(no_tools.tools, nil)
	assert_eq(no_tools.tool_choice, nil)
end)

test("local-only removes exactly hosted search and preserves every native tool", function()
	local json = require("agent.util.json")
	local request = { model = "gpt-6-astra", messages = { { role = "user", text = "local task" } } }
	local normal = json.decode(codex._request_body(request))
	request.tool_scope = "local_only"
	local offline = json.decode(codex._request_body(request))
	assert_eq(normal.tools[#normal.tools].type, "web_search")
	table.remove(normal.tools)
	assert_eq(json.encode(offline), json.encode(normal), "unexpected payload difference")
	for _, tool in ipairs(offline.tools) do assert_eq(tool.type, "function") end
end)

test("retired tools and scheduler fields are absent from native schemas", function()
	local registry = require("agent.tool_registry")
	assert_eq(registry.get("delegate_readonly"), nil)
	assert_eq(registry.is_valid("delegate_readonly"), false)
	for _, tool in ipairs(registry.native_tools()) do
		assert(tool.name ~= "delegate_readonly")
		assert_eq(tool.parameters.properties.node_id, nil)
		assert_eq(tool.parameters.properties.depends_on, nil)
	end
	assert_eq(registry.execute("delegate_readonly", {}, {}).is_error, true)
end)

test("request body defaults to GPT-6 Astra", function()
	local json = require("agent.util.json")
	local body = json.decode(codex._request_body({ messages = { { role = "user", text = "hello" } } }))
	assert_eq(body.model, "gpt-6-astra")
end)

test("native input replays calls and correlated outputs", function()
	local json = require("agent.util.json")
	local input = json.decode(codex._input_json({
		{ role = "user", text = "read it" },
		{ role = "assistant", text = "", provider_items = {
			{ type = "reasoning", id = "rs_1", encrypted_content = "opaque" },
			{ type = "function_call", id = "fc_1", call_id = "call_1", name = "read", arguments = '{"path":"README.md"}' },
		} },
		{ role = "user", text = "file contents", tool_name = "read", native_call_id = "call_1" },
	}, true))
	assert_eq(input[2].type, "reasoning")
	assert_eq(input[3].type, "function_call")
	assert_eq(input[4].type, "function_call_output")
	assert_eq(input[4].call_id, "call_1")
	assert_eq(input[4].output, "file contents")
end)

test("native input omits function calls whose output was never recorded", function()
	local json = require("agent.util.json")
	local input = json.decode(codex._input_json({
		{ role = "assistant", text = "", provider_items = {
			{ type = "reasoning", id = "rs_1", encrypted_content = "opaque" },
			{ type = "function_call", id = "fc_ok", call_id = "call_ok", name = "read", arguments = '{"path":"README.md"}' },
			{ type = "function_call", id = "fc_orphan", call_id = "call_orphan", name = "read", arguments = '{"path":"missing.md"}' },
		} },
		{ role = "user", text = "file contents", tool_name = "read", native_call_id = "call_ok" },
	}, true))
	local calls = {}
	for _, item in ipairs(input) do
		if item.type == "function_call" then calls[#calls + 1] = item.call_id end
	end
	assert_eq(#calls, 1)
	assert_eq(calls[1], "call_ok")
end)

test("native input drops orphan outputs and preserves exactly paired history", function()
	local json = require("agent.util.json")
	local input = json.decode(codex._input_json({
		{ role = "assistant", text = "", provider_items = {
			{ type = "function_call", id = "fc_ok", call_id = "call_ok", name = "read", arguments = '{"path":"README.md"}' },
		} },
		{ role = "user", text = "ok", tool_name = "read", native_call_id = "call_ok" },
		{ role = "user", text = "orphan", tool_name = "read", native_call_id = "call_missing" },
	}, true))
	local calls, outputs = {}, {}
	for _, item in ipairs(input) do
		if item.type == "function_call" then calls[item.call_id] = true end
		if item.type == "function_call_output" then outputs[item.call_id] = true end
	end
	assert_eq(calls.call_ok, true)
	assert_eq(outputs.call_ok, true)
	assert_eq(outputs.call_missing, nil)
end)

test("native output items become executable calls", function()
	local calls, err = codex._native_tool_calls({
		{ type = "reasoning", id = "rs_1" },
		{ type = "function_call", id = "fc_1", call_id = "call_1", name = "edit", arguments = '{"path":"a.lua","start_line":1,"start_tag":"abcd","end_line":1,"end_tag":"abcd","content":"return 1\\n"}' },
	})
	assert_eq(err, nil)
	assert_eq(#calls, 1)
	assert_eq(calls[1].name, "edit")
	assert_eq(calls[1].native_call_id, "call_1")
	assert_eq(calls[1].args.content, "return 1\n")
end)

test("native reasoning replay preserves empty array fields", function()
	local json = require("agent.util.json")
	local item = json.decode('{"type":"reasoning","id":"rs_1","summary":[],"content":[]}')
	item = codex._normalize_output_item(item)
	local encoded = json.encode(item)
	if not encoded:find('"summary":%[%]') then
		error("reasoning summary was not encoded as an array: " .. encoded)
	end
	if not encoded:find('"content":%[%]') then
		error("reasoning content was not encoded as an array: " .. encoded)
	end
end)

test("native input repairs legacy object-shaped empty response arrays", function()
	local json = require("agent.util.json")
	local reasoning = json.decode('{"type":"reasoning","id":"rs_legacy","summary":{},"content":{}}')
	local message = json.decode('{"type":"message","id":"msg_legacy","role":"assistant","content":[{"type":"output_text","text":"hello","annotations":{},"logprobs":{}}]}')
	local encoded = codex._input_json({
		{ role = "assistant", text = "", provider_items = { reasoning, message } },
	}, true)
	if not encoded:find('"summary":%[%]') then
		error("legacy reasoning summary was not repaired as an array: " .. encoded)
	end
	if not encoded:find('"content":%[%]') then
		error("legacy reasoning content was not repaired as an array: " .. encoded)
	end
	if not encoded:find('"annotations":%[%]') then
		error("legacy output annotations were not repaired as an array: " .. encoded)
	end
	if not encoded:find('"logprobs":%[%]') then
		error("legacy output logprobs were not repaired as an array: " .. encoded)
	end
end)

test("native web citations become usable markdown links", function()
	local text = "AWS documents this. citeturn0search0turn0search1"
	local items = {
		{
			type = "message",
			content = {
				{
					type = "output_text",
					text = text,
					annotations = {
						{ type = "url_citation", start_index = 20, end_index = 55, title = "AWS documentation", url = "https://docs.aws.amazon.com/example" },
						{ type = "url_citation", start_index = 20, end_index = 55, title = "AWS sample", url = "https://github.com/aws-samples/example" },
					},
				},
			},
		},
	}
	local rendered = codex._materialize_citations(text, items)
	if rendered:find("cite", 1, true) then error("raw citation marker leaked: " .. rendered) end
	if not rendered:find("[AWS documentation](<https://docs.aws.amazon.com/example>)", 1, true) then error("missing first citation: " .. rendered) end
	if not rendered:find("[AWS sample](<https://github.com/aws-samples/example>)", 1, true) then error("missing grouped citation: " .. rendered) end
end)

test("citation annotations without markers receive a compact source footer", function()
	local rendered = codex._materialize_citations("Grounded answer.", {
		{ type = "message", content = { { type = "output_text", text = "Grounded answer.", annotations = {
			{ type = "url_citation", start_index = 0, end_index = 8, title = "Primary source", url = "https://example.com/source" },
		} } } },
	})
	if not rendered:find("Sources: [Primary source](<https://example.com/source>)", 1, true) then error("missing source footer: " .. rendered) end
end)

test("provider empty-array sentinels do not break citation rendering", function()
	local cjson = require("cjson")
	local rendered = codex._materialize_citations("Plain answer.", {
		{ type = "message", content = { { type = "output_text", text = "Plain answer.", annotations = cjson.empty_array } } },
	})
	assert_eq(rendered, "Plain answer.")
end)

test("codex timeout defaults allow long active streams", function()
	local deadlines = codex._default_deadlines({})
	assert_eq(deadlines.first_byte, 25)
	assert_eq(deadlines.total, 600)
	assert_eq(deadlines.idle, 60)
end)

test("websocket responses use a shorter absolute failover deadline", function()
	local deadlines = codex._websocket_deadlines({})
	assert_eq(deadlines.first_byte, 5)
	assert_eq(deadlines.idle, 60)
	assert_eq(deadlines.total, 180)
end)

test("websocket response deadline preserves a stricter caller override", function()
	local deadlines = codex._websocket_deadlines({ deadlines = { total = 45 } })
	assert_eq(deadlines.total, 45)
end)

test("codex first byte timeout stays long for large context", function()
	local deadlines = codex._default_deadlines({
		system_prompt = string.rep("s", 12000),
		messages = {
			{ role = "user", text = string.rep("m", 12000) },
		},
	})
	assert_eq(deadlines.first_byte, 180)
end)

test("codex explicit first byte timeout override wins", function()
	local deadlines = codex._default_deadlines({
		deadlines = {
			first_byte = 12,
		},
	})
	assert_eq(deadlines.first_byte, 12)
end)

test("request body defaults codex service tier to priority", function()
	local body = codex._request_body({
		session_id = "lca-session-123",
		messages = {
			{ role = "user", text = "hi" },
		},
	})
	if not body:find('"service_tier":"priority"', 1, true) then
		error("missing default priority service tier: " .. body)
	end
end)

test("request body keeps explicit service tier override", function()
	local body = codex._request_body({
		session_id = "lca-session-123",
		service_tier = "default",
		messages = {
			{ role = "user", text = "hi" },
		},
	})
	if not body:find('"service_tier":"default"', 1, true) then
		error("missing explicit service tier override: " .. body)
	end
end)

test("prompt cache key is clamped and sanitized", function()
	local key = codex._prompt_cache_key({
		session_id = "lca session with spaces and symbols !@#$%^&*()" .. string.rep("x", 80),
	})
	if #key > 64 then
		error("prompt cache key should be clamped to 64 chars, got " .. tostring(#key))
	end
	if key:find(" ") or key:find("!") then
		error("prompt cache key should be sanitized: " .. key)
	end
end)

test("codex headers include cache affinity identifiers", function()
	local headers = codex._headers({ access = "token", account_id = "acct" }, {
		session_id = "lca-session-123",
	})
	local seen = {}
	for _, header in ipairs(headers) do
		seen[header[1]] = header[2]
	end
	assert_eq(seen.session_id, "lca-session-123")
	assert_eq(seen["x-client-request-id"], "lca-session-123")
	assert_eq(seen["OpenAI-Beta"], "responses=experimental")
end)

test("usage parser keeps cached, output, and total tokens", function()
	local usage = codex._usage_from_payload([[{"type":"response.completed","response":{"usage":{"input_tokens":1000,"output_tokens":80,"total_tokens":1080,"input_tokens_details":{"cached_tokens":256,"cache_write_tokens":512}}}}]])
	assert_eq(usage.prompt_tokens, 1000)
	assert_eq(usage.cached_tokens, 256)
	assert_eq(usage.cache_available, true)
	assert_eq(usage.cache_write_tokens, 512)
	assert_eq(usage.output_tokens, 80)
	assert_eq(usage.total_tokens, 1080)
end)

test("usage parser distinguishes missing cache telemetry from a zero hit", function()
	local missing = codex._usage_from_payload([[{"type":"response.completed","response":{"usage":{"input_tokens":1000,"output_tokens":10}}}]])
	assert_eq(missing.cached_tokens, 0)
	assert_eq(missing.cache_available, false)
	local zero = codex._usage_from_payload([[{"type":"response.completed","response":{"usage":{"input_tokens":1000,"output_tokens":10,"input_tokens_details":{"cached_tokens":0}}}}]])
	assert_eq(zero.cached_tokens, 0)
	assert_eq(zero.cache_available, true)
end)

test("usage parser accepts prompt token details cache shape", function()
	local usage = codex._usage_from_payload([[{"type":"response.completed","usage":{"prompt_tokens":1200,"completion_tokens":90,"total_tokens":1290,"prompt_tokens_details":{"cached_tokens":512}}}]])
	assert_eq(usage.prompt_tokens, 1200)
	assert_eq(usage.cached_tokens, 512)
	assert_eq(usage.cache_write_tokens, 0)
	assert_eq(usage.output_tokens, 90)
	assert_eq(usage.total_tokens, 1290)
end)

test("hosted web search events report model activity", function()
	local activities = {}
	local stats = codex._new_sse_stats()
	local event_type = codex._process_event_payload(
		[[{"type":"response.web_search_call.searching","item_id":"ws_123","output_index":2}]],
		function() end,
		nil,
		stats,
		nil,
		function(activity) activities[#activities + 1] = activity end
	)
	assert_eq(event_type, "response.web_search_call.searching")
	assert_eq(#activities, 1)
	assert_eq(activities[1].type, "web_search")
	assert_eq(activities[1].phase, "searching")
	assert_eq(activities[1].id, "ws_123")
	assert_eq(activities[1].output_index, 2)
end)

io.write("\n" .. dim("─────────────────────────────────────") .. "\n")
io.write(string.format("  %s passed, %s failed\n",
	green(tostring(passed)), failed > 0 and red(tostring(failed)) or tostring(failed)))
io.write("\n")
os.exit(failed > 0 and 1 or 0)
