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

test("codex timeout defaults allow long active streams", function()
	local deadlines = codex._default_deadlines({})
	assert_eq(deadlines.first_byte, 25)
	assert_eq(deadlines.total, 600)
	assert_eq(deadlines.idle, 60)
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
	local usage = codex._usage_from_payload([[{"type":"response.completed","response":{"usage":{"input_tokens":1000,"output_tokens":80,"total_tokens":1080,"input_tokens_details":{"cached_tokens":256}}}}]])
	assert_eq(usage.prompt_tokens, 1000)
	assert_eq(usage.cached_tokens, 256)
	assert_eq(usage.output_tokens, 80)
	assert_eq(usage.total_tokens, 1080)
end)

test("usage parser accepts prompt token details cache shape", function()
	local usage = codex._usage_from_payload([[{"type":"response.completed","usage":{"prompt_tokens":1200,"completion_tokens":90,"total_tokens":1290,"prompt_tokens_details":{"cached_tokens":512}}}]])
	assert_eq(usage.prompt_tokens, 1200)
	assert_eq(usage.cached_tokens, 512)
	assert_eq(usage.output_tokens, 90)
	assert_eq(usage.total_tokens, 1290)
end)

io.write("\n" .. dim("─────────────────────────────────────") .. "\n")
io.write(string.format("  %s passed, %s failed\n",
	green(tostring(passed)), failed > 0 and red(tostring(failed)) or tostring(failed)))
io.write("\n")
os.exit(failed > 0 and 1 or 0)
