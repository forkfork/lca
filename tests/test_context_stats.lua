#!/usr/bin/env lua

local script_dir = arg[0]:match("^(.*)/[^/]+$") or "."
local project_dir = script_dir .. "/.."
package.path = project_dir .. "/lua/?.lua;" .. project_dir .. "/lua/?/init.lua;" .. project_dir .. "/lua/?/?.lua;" .. package.path
pcall(require, "luarocks.loader")

local shell = require("agent.util.shell")

local passed = 0
local failed = 0

local function green(s) return "\27[32m" .. s .. "\27[0m" end
local function red(s) return "\27[31m" .. s .. "\27[0m" end
local function dim(s) return "\27[2m" .. s .. "\27[0m" end

local function write_file(path, content)
	local f = assert(io.open(path, "w"))
	f:write(content)
	f:close()
end

local function capture(command)
	local pipe = assert(io.popen(command, "r"))
	local output = pipe:read("*a")
	local ok = pipe:close()
	return output, ok
end

local function assert_contains(text, needle, message)
	if not text:find(needle, 1, true) then
		error((message or "missing text") .. ": " .. needle .. "\noutput:\n" .. text)
	end
end

local tmp_dir = os.tmpname() .. "_lca_context_stats_tests"
os.execute("rm -rf " .. shell.quote(tmp_dir))
os.execute("mkdir -p " .. shell.quote(tmp_dir))

local function run_test(name, fn)
	io.write(dim("  " .. name .. " "))
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

io.write("\n" .. dim("═══ Context Stats Tests ═══") .. "\n\n")

run_test("context stats summarizes session and codex log", function()
	local session_path = tmp_dir .. "/session.json"
	local log_path = tmp_dir .. "/lca.log"
	write_file(session_path, [[
{
  "messages": [
    {"role":"user","text":"hello"},
    {"role":"assistant","text":"<tool_call name=\"read\">\n{\"path\":\"README.md\"}\n</tool_call>"},
    {"role":"user","tool_name":"read","text":"<tool_result name=\"read\" status=\"ok\" path=\"README.md\">line one\nline two</tool_result>"}
  ],
  "last_usage": {"prompt_tokens":1000,"cached_tokens":400,"output_tokens":50,"total_tokens":1050,"message_index":2},
  "usage_history": [
    {"prompt_tokens":1000,"cached_tokens":100,"output_tokens":10,"total_tokens":1010,"message_index":1,"cached_percent":10},
    {"prompt_tokens":1000,"cached_tokens":400,"output_tokens":50,"total_tokens":1050,"message_index":2,"cached_percent":40}
  ],
  "compaction_details": {"read_files":["README.md"],"modified_files":[]}
}
]])
	write_file(log_path, [[
[codex] attempt 1/2 model=gpt-5.5 reasoning=(default) service_tier=(default) cache_key=(set:lca-test) messages=3 roles=assistant=1,user=2 message_chars=100 longest_message=50 system_prompt_chars=20 body_bytes=200 prefix_hashes="4096=aaaa full=bbbb"
[codex] prefix stability cache_key=(set:lca-test) 4096=new 16384=missing 32768=missing 65536=missing full=new
[codex] prefix stability cache_key=(set:lca-test) 4096=same 16384=missing 32768=missing 65536=missing full=changed
[codex] attempt 1 succeeded http_status=200 response_chars=10 response_bytes=100 timing=connect=0.001 tls=0.002 write=0.003 first_byte=0.500 headers=0.500 total=1.000
[codex] prompt cache prompt_tokens=1000 cached_tokens=400 cached=40.0%
[codex] prompt cache usage unavailable reason=early_cutoff
[codex] canonicalized tool response chars=20->10
[context] slim audit messages=2 bytes_removed=8000 approx_tokens_saved=2000 session_tokens=12000 reasons="large-old-message=2" labels="tool:read=2" files="read=1 modified=0"
]])

	local command = "lua " .. shell.quote(project_dir .. "/scripts/context_stats.lua") ..
		" --session " .. shell.quote(session_path) ..
		" --log " .. shell.quote(log_path) ..
		" --top 2"
	local output = capture(command)
	assert_contains(output, "lca context stats")
	assert_contains(output, "last usage:")
	assert_contains(output, "usage history:")
	assert_contains(output, "cache trend:")
	assert_contains(output, "latest cache:")
	assert_contains(output, "early_cutoff=1")
	assert_contains(output, "slim audits:")
	assert_contains(output, "latest slim:")
	assert_contains(output, "4096")
	assert_contains(output, "same=1 changed=0 new=1")
	assert_contains(output, "README.md")
end)

os.execute("rm -rf " .. shell.quote(tmp_dir))

io.write("\n" .. dim("─────────────────────────────────────") .. "\n")
io.write(string.format("  %s passed, %s failed\n\n",
	green(tostring(passed)), failed > 0 and red(tostring(failed)) or tostring(failed)))

os.exit(failed > 0 and 1 or 0)
