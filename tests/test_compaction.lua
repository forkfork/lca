#!/usr/bin/env lua

local script_dir = arg[0]:match("^(.*)/[^/]+$") or "."
local project_dir = script_dir .. "/.."
package.path = project_dir .. "/lua/?.lua;" .. project_dir .. "/lua/?/init.lua;" .. project_dir .. "/lua/?/?.lua;" .. package.path
pcall(require, "luarocks.loader")

local compaction = require("agent.compaction")

local passed = 0
local failed = 0

local function green(s) return "\27[32m" .. s .. "\27[0m" end
local function red(s) return "\27[31m" .. s .. "\27[0m" end
local function dim(s) return "\27[2m" .. s .. "\27[0m" end

local function assert_eq(actual, expected, message)
	if actual ~= expected then
		error((message or "values differ") .. "\nexpected: " .. tostring(expected) .. "\nactual: " .. tostring(actual))
	end
end

local function assert_contains(text, needle, message)
	if not tostring(text or ""):find(needle, 1, true) then
		error((message or "missing text") .. ": " .. needle)
	end
end

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

io.write("\n" .. dim("═══ Compaction Tests ═══") .. "\n\n")

run_test("file operations distinguish read-only and modified files", function()
	local details = compaction.file_operations({
		{
			role = "assistant",
			text = table.concat({
				'<tool_call name="read">',
				'{"path":"README.md"}',
				"</tool_call>",
				'<tool_call name="edit">',
				'{"path":"app.lua","start_line":1,"end_line":1}',
				"print('hi')",
				"</tool_call>",
			}, "\n"),
		},
		{
			role = "user",
			tool_name = "write",
			text = '<tool_result name="write" status="ok" path="README.md">ok</tool_result>',
		},
	})

	assert_eq(#details.read_files, 0, "README.md was modified, so it should not remain read-only")
	assert_eq(#details.modified_files, 2)
	assert_eq(details.modified_files[1], "README.md")
	assert_eq(details.modified_files[2], "app.lua")
end)

run_test("coalesced slimmed history carries file operation tags", function()
	local session = {
		messages = {
			{ role = "user", text = "start" },
			{
				role = "user",
				tool_name = "read",
				slimmed = true,
				text = '<tool_result name="read" status="ok" path="README.md">old read</tool_result>',
			},
			{
				role = "user",
				tool_name = "edit",
				slimmed = true,
				text = '<tool_result name="edit" status="ok" path="app.lua">old edit</tool_result>',
			},
			{ role = "user", text = "recent 1" },
			{ role = "assistant", text = "recent 2" },
		},
	}

	local changed = compaction.coalesce_slimmed_history(session, {
		target_messages = 3,
		keep_recent_messages = 2,
	})
	assert_eq(changed, true)
	local text = table.concat((function()
		local parts = {}
		for _, message in ipairs(session.messages) do
			parts[#parts + 1] = message.text or ""
		end
		return parts
	end)(), "\n")
	assert_contains(text, "<read-files>")
	assert_contains(text, "README.md")
	assert_contains(text, "<modified-files>")
	assert_contains(text, "app.lua")
end)

run_test("slimming preserves recent read working set per path", function()
	local big_read = '<tool_result name="read" status="ok" path="app.lua">' .. string.rep("x", 5000) .. "</tool_result>"
	local session = {
		messages = {
			{ role = "user", text = "start" },
			{ role = "user", tool_name = "read", text = big_read },
			{ role = "user", tool_name = "read", text = big_read },
			{ role = "user", tool_name = "read", text = big_read },
			{ role = "user", tool_name = "read", text = big_read },
			{ role = "assistant", text = "recent" },
		},
		estimated_session_tokens = function(self)
			local total = 0
			for _, message in ipairs(self.messages) do
				total = total + math.ceil(#(message.text or "") / 4)
			end
			return total
		end,
	}

	local slimmed, changed = compaction.slim_history(session, {
		keep_recent_messages = 1,
		keep_reads_per_path = 2,
		large_message_bytes = 1000,
		target_session_tokens = 1,
	})
	assert_eq(slimmed, true)
	assert_eq(changed, 2)
	if session.messages[4].slimmed or session.messages[5].slimmed then
		error("latest two app.lua reads should remain exact")
	end
	if not session.messages[2].slimmed or not session.messages[3].slimmed then
		error("older reads should still be eligible for slimming")
	end
end)

run_test("summary prompt includes recent turn ast evidence", function()
	local prompt = compaction._build_summary_prompt(
		{
			{ role = "user", text = "create app" },
			{ role = "assistant", text = "done" },
		},
		nil,
		{
			last_turn_ast_summary = "intent=ok(create app)\nchanges=ok(1 file saved  app.lua)\nverify=error(1 check)",
		},
		{}
	)
	assert_contains(prompt, "<recent-turn-ast>")
	assert_contains(prompt, "changes=ok(1 file saved  app.lua)")
	assert_contains(prompt, "Use it as grounding evidence")
end)

io.write("\n" .. dim("─────────────────────────────────────") .. "\n")
io.write(string.format("  %s passed, %s failed\n\n",
	green(tostring(passed)), failed > 0 and red(tostring(failed)) or tostring(failed)))

os.exit(failed > 0 and 1 or 0)
