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

test("canonical tool text strips stray close tag and prose", function()
	local raw = table.concat({
		'<tool_call name="read">',
		'{"path":"fake_tmux.py","offset":1,"limit":260}',
		"</tool_call>",
		"</tool_call>I hit a malformed tool-call message, so nothing ran.",
	}, "\n")
	local expected = table.concat({
		'<tool_call name="read">',
		'{"path":"fake_tmux.py","offset":1,"limit":260}',
		"</tool_call>",
	}, "\n")
	assert_eq(codex._canonical_tool_text(raw), expected)
end)

test("canonical tool text keeps multiple complete tool calls", function()
	local raw = table.concat({
		'<tool_call name="read">',
		'{"path":"fake_tmux.py","offset":1,"limit":260}',
		"</tool_call>",
		'<tool_call name="read">',
		'{"path":"README.md","offset":1,"limit":170}',
		"</tool_call>",
		"Trailing speculation should not enter history.",
	}, "\n")
	local canonical = codex._canonical_tool_text(raw)
	if canonical:find("Trailing speculation", 1, true) then
		error("canonical tool text retained trailing prose: " .. canonical)
	end
	assert(canonical:find('"path":"fake_tmux.py"', 1, true), "missing first call")
	assert(canonical:find('"path":"README.md"', 1, true), "missing second call")
end)

test("canonical debug summary records raw and canonical tool signatures", function()
	local raw = table.concat({
		'<tool_call name="ls">',
		'{"path":"/tmp/project"}',
		"</tool_call>",
		'<tool_call name="ls">',
		'{"path":"/tmp/project"}',
		"</tool_call>",
		"Trailing prose",
	}, "\n")
	local canonical = codex._canonical_tool_text(raw)
	local summary = codex._canonical_tool_debug_summary(raw, canonical)
	if not summary:find('raw_calls="2 calls: ls%(/tmp/project%), ls%(/tmp/project%)"') then
		error("raw duplicate signatures missing from summary: " .. summary)
	end
	if not summary:find('canonical_calls="2 calls: ls%(/tmp/project%), ls%(/tmp/project%)"') then
		error("canonical duplicate signatures missing from summary: " .. summary)
	end
	if not summary:find('raw_sample="', 1, true) or not summary:find('canonical_sample="', 1, true) then
		error("summary should include bounded raw and canonical samples: " .. summary)
	end
end)

test("partial salvage keeps only fully closed tool calls", function()
	local partial = table.concat({
		'<tool_call name="ls">',
		'{"path":"."}',
		"</tool_call>",
		'<tool_call name="write">',
		'{"path":"agent_flow_tui.py"}',
		"#!/usr/bin/env python3",
		"print('still streaming')",
	}, "\n")
	local salvaged = codex._complete_tool_calls_prefix(partial)
	assert(salvaged:find('<tool_call name="ls">', 1, true), "missing complete ls call")
	if salvaged:find("agent_flow_tui.py", 1, true) then
		error("salvage kept incomplete write call: " .. salvaged)
	end
	if salvaged:find("</tool_call>%s*$") == nil then
		error("salvage should end at a real close tag: " .. salvaged)
	end
end)

test("partial salvage does not synthesize close tags", function()
	local partial = table.concat({
		'<tool_call name="write">',
		'{"path":"agent_flow_tui.py"}',
		"print('unterminated')",
	}, "\n")
	local salvaged = codex._complete_tool_calls_prefix(partial)
	assert_eq(salvaged, "")
end)

test("partial salvage does not truncate raw content at literal close text", function()
	local partial = table.concat({
		'<tool_call name="write">',
		'{"path":"agent_flow_tui.py"}',
		'print("</tool_call>")',
		"print('after literal close')",
	}, "\n")
	local salvaged = codex._complete_tool_calls_prefix(partial)
	assert_eq(salvaged, "")
end)

test("partial salvage rejects literal tool markup in raw content", function()
	local partial = table.concat({
		'<tool_call name="write">',
		'{"path":"agent_flow_tui.py"}',
		"print('bad')",
		'<tool_call name="run">',
		'{"command":"echo nested"}',
		"</tool_call>",
		"</tool_call>",
	}, "\n")
	local salvaged = codex._salvage_partial_tool_response({ partial }, { kind = "timeout", phase = "chunk_size" })
	assert_eq(salvaged, nil)
end)

test("post-tool tail classifier cuts prose after extra close", function()
	assert_eq(codex._post_tool_tail_kind(" \n"), "whitespace")
	assert_eq(codex._post_tool_tail_kind("</tool_call>\n"), "extra_close")
	assert_eq(codex._post_tool_tail_kind("</tool_call>I hit a malformed message"), "extra_close_then_prose")
	assert_eq(codex._post_tool_tail_kind("I will explain now"), "prose")
	assert_eq(codex._post_tool_tail_kind("<tool_call"), "partial_next_tool")
	assert_eq(codex._post_tool_tail_kind('<tool_call name="read">'), "next_tool")
end)

test("early cutoff tolerates small post-tool prose to preserve usage", function()
	assert_eq(codex._should_cut_after_tool("prose", 4), false)
	assert_eq(codex._should_cut_after_tool("extra_close_then_prose", 4), false)
	assert_eq(codex._should_cut_after_tool("next_tool", 1000), false)
	assert_eq(codex._should_cut_after_tool("prose", 801), true)
end)

test("stream cap counts only unique complete valid tool calls", function()
	local text = table.concat({
		'<tool_call name="ls">', '{"path":"."}', '</tool_call>',
		'<tool_call name="ls">', '{"path":"."}', '</tool_call>',
		'<tool_call name="not_a_tool">', '{}', '</tool_call>',
		'<tool_call name="read">', '{"path":"README.md"}', '</tool_call>',
		'<tool_call name="run">', '{"command":"true"}', '</tool_call>',
		'<tool_call name="write">', '{"path":"a.txt"}', 'one', '</tool_call>',
		'<tool_call name="write">', '{"path":"a.txt"}', 'two', '</tool_call>',
	}, "\n")
	assert_eq(codex._unique_complete_valid_tool_call_count(text), 5)
	local stats = codex._complete_valid_tool_call_stats(text)
	assert_eq(stats.total, 6)
	assert_eq(stats.unique, 5)
	assert_eq(stats.duplicates, 1)
end)

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

test("codex defaults streaming to the core execution batch size", function()
	assert_eq(codex._default_stream_tool_call_cap, 10)
	assert_eq(codex._default_stream_duplicate_call_cap, 3)
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
	assert_eq(usage.cache_write_tokens, 512)
	assert_eq(usage.output_tokens, 80)
	assert_eq(usage.total_tokens, 1080)
end)

test("usage parser accepts prompt token details cache shape", function()
	local usage = codex._usage_from_payload([[{"type":"response.completed","usage":{"prompt_tokens":1200,"completion_tokens":90,"total_tokens":1290,"prompt_tokens_details":{"cached_tokens":512}}}]])
	assert_eq(usage.prompt_tokens, 1200)
	assert_eq(usage.cached_tokens, 512)
	assert_eq(usage.cache_write_tokens, 0)
	assert_eq(usage.output_tokens, 90)
	assert_eq(usage.total_tokens, 1290)
end)

io.write("\n" .. dim("─────────────────────────────────────") .. "\n")
io.write(string.format("  %s passed, %s failed\n",
	green(tostring(passed)), failed > 0 and red(tostring(failed)) or tostring(failed)))
io.write("\n")
os.exit(failed > 0 and 1 or 0)
