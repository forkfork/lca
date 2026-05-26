#!/usr/bin/env lua

local script_dir = arg[0]:match("^(.*)/[^/]+$") or "."
local project_dir = script_dir .. "/.."
package.path = project_dir .. "/lua/?.lua;" .. project_dir .. "/lua/?/init.lua;" .. project_dir .. "/lua/?/?.lua;" .. package.path
pcall(require, "luarocks.loader")

local parallel = require("agent.parallel")
local read_tool = require("agent.tools.read")
local shell = require("agent.util.shell")

local passed = 0
local failed = 0

local function green(s) return "\27[32m" .. s .. "\27[0m" end
local function red(s) return "\27[31m" .. s .. "\27[0m" end
local function dim(s) return "\27[2m" .. s .. "\27[0m" end

local function split_lines(text)
	return read_tool.split_lines(text)
end

local function write_file(path, content)
	local f = assert(io.open(path, "w"))
	f:write(content)
	f:close()
end

local function read_file(path)
	local f = assert(io.open(path, "r"))
	local content = f:read("*a")
	f:close()
	return content
end

local function assert_eq(actual, expected, message)
	if actual ~= expected then
		error((message or "values differ") .. "\nexpected: " .. tostring(expected) .. "\nactual: " .. tostring(actual))
	end
end

local function assert_contains(text, needle, message)
	if not text:find(needle, 1, true) then
		error((message or "missing text") .. ": " .. needle)
	end
end

local function assert_lines(path, expected)
	local actual_lines = split_lines(read_file(path))
	for index, line in ipairs(expected) do
		assert_eq(actual_lines[index], line, path .. " line " .. tostring(index))
	end
end

local function edit_call(path, start_line, end_line, lines, replacement)
	return {
		name = "edit",
		args = {
			path = path,
			start_line = start_line,
			start_tag = read_tool.line_tag(start_line, lines[start_line]),
			end_line = end_line,
			end_tag = read_tool.line_tag(end_line, lines[end_line]),
			_raw_content = replacement,
		},
	}
end

local tmp_dir = os.tmpname() .. "_lca_parallel_tests"
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

io.write("\n" .. dim("═══ Parallel Executor Tests ═══") .. "\n\n")

run_test("allows non-overlapping same-file edits in one batch", function()
	local path = tmp_dir .. "/same.txt"
	write_file(path, "one\ntwo\nthree\n")
	local lines = split_lines(read_file(path))

	local calls = {
		edit_call(path, 1, 1, lines, "one\ninserted"),
		edit_call(path, 3, 3, lines, "THREE"),
	}
	local results = parallel.execute_batch(calls, { cwd = tmp_dir })

	assert_eq(results[1].is_error, false, "first edit should succeed")
	assert_eq(results[2].is_error, false, "second edit should succeed")
	assert_lines(path, { "one", "inserted", "two", "THREE" })
end)

run_test("emits one result event per grouped same-file edit", function()
	local path = tmp_dir .. "/same-events.txt"
	write_file(path, "one\ntwo\nthree\n")
	local lines = split_lines(read_file(path))
	local events = {}

	local calls = {
		edit_call(path, 1, 1, lines, "ONE"),
		edit_call(path, 3, 3, lines, "THREE"),
	}
	local results = parallel.execute_batch(calls, { cwd = tmp_dir }, function(event)
		if event.phase ~= "start" then
			events[#events + 1] = event
		end
	end)

	assert_eq(results[1].is_error, false, "first edit should succeed")
	assert_eq(results[2].is_error, false, "second edit should succeed")
	assert_eq(#events, 2, "each grouped edit should emit exactly one result event")
	assert_eq(events[1].name, "edit")
	assert_eq(events[2].name, "edit")
	assert_lines(path, { "ONE", "two", "THREE" })
end)

run_test("blocks same-batch read and edit of one file", function()
	local path = tmp_dir .. "/read-then-edit.txt"
	write_file(path, "one\ntwo\n")
	local lines = split_lines(read_file(path))

	local calls = {
		{ name = "read", args = { path = path } },
		edit_call(path, 1, 1, lines, "ONE"),
	}
	local results = parallel.execute_batch(calls, { cwd = tmp_dir })

	assert_eq(results[1].is_error, false, "read should still execute")
	assert_eq(results[2].is_error, true, "edit should be blocked")
	assert_eq(results[2].summary, "dependent batch mutation")
	assert_eq(results[2].ui_state, "deferred")
	assert_contains(results[2].content, "both reads and modifies")
	assert_contains(results[2].content, "next turn")
	assert_lines(path, { "one", "two" })
end)

run_test("blocks same-batch read and write of one file", function()
	local path = tmp_dir .. "/read-then-write.txt"
	write_file(path, "one\ntwo\n")

	local calls = {
		{ name = "read", args = { path = path } },
		{ name = "write", args = { path = path, _raw_content = "ONE\nTWO" } },
	}
	local results = parallel.execute_batch(calls, { cwd = tmp_dir })

	assert_eq(results[1].is_error, false, "read should still execute")
	assert_eq(results[2].is_error, true, "write should be blocked")
	assert_eq(results[2].summary, "dependent batch mutation")
	assert_eq(results[2].ui_state, "deferred")
	assert_lines(path, { "one", "two" })
end)

run_test("rejects overlapping same-file edits in one batch", function()
	local path = tmp_dir .. "/overlap.txt"
	write_file(path, "one\ntwo\nthree\n")
	local lines = split_lines(read_file(path))

	local calls = {
		edit_call(path, 1, 2, lines, "ONE\nTWO"),
		edit_call(path, 2, 3, lines, "TWO\nTHREE"),
	}
	local results = parallel.execute_batch(calls, { cwd = tmp_dir })

	assert_eq(results[1].is_error, false, "first edit should succeed")
	assert_eq(results[2].is_error, true, "overlapping edit should be rejected")
	assert_eq(results[2].summary, "stale batch mutation")
	assert_contains(results[2].content, "Re-read the file")
	assert_lines(path, { "ONE", "TWO", "three" })
end)

run_test("allows same-file mutation after failed previous mutation", function()
	local path = tmp_dir .. "/failed-first.txt"
	write_file(path, "alpha\nbeta\n")
	local lines = split_lines(read_file(path))

	local calls = {
		{
			name = "edit",
			args = {
				path = path,
				start_line = 1,
				start_tag = "BAD!",
				end_line = 1,
				end_tag = read_tool.line_tag(1, lines[1]),
				_raw_content = "ALPHA",
			},
		},
		edit_call(path, 2, 2, lines, "BETA"),
	}
	local results = parallel.execute_batch(calls, { cwd = tmp_dir })

	assert_eq(results[1].is_error, true, "first edit should fail")
	assert_eq(results[2].is_error, false, "second edit should still execute")
	assert_lines(path, { "alpha", "BETA" })
end)

run_test("skips later run after failed edit", function()
	local path = tmp_dir .. "/failed-edit-then-run.txt"
	local marker = tmp_dir .. "/should-not-exist"
	write_file(path, "alpha\n")
	local lines = split_lines(read_file(path))

	local calls = {
		{
			name = "edit",
			args = {
				path = path,
				start_line = 1,
				start_tag = "BAD!",
				end_line = 1,
				end_tag = read_tool.line_tag(1, lines[1]),
				_raw_content = "ALPHA",
			},
		},
		{ name = "run", args = { command = "touch " .. shell.quote(marker) } },
	}
	local results = parallel.execute_batch(calls, { cwd = tmp_dir })

	assert_eq(results[1].is_error, true, "edit should fail")
	assert_eq(results[2].is_error, true, "run should be skipped")
	assert_eq(results[2].summary, "skipped after failed mutation")
	assert_eq(results[2].ui_state, "deferred")
	assert_contains(results[2].content, "earlier edit/write")
	local f = io.open(marker, "r")
	if f then
		f:close()
		error("run executed despite failed edit")
	end
end)

run_test("allows mutations to different files in one batch", function()
	local path_a = tmp_dir .. "/a.txt"
	local path_b = tmp_dir .. "/b.txt"
	write_file(path_a, "a1\na2\n")
	write_file(path_b, "b1\nb2\n")
	local lines_a = split_lines(read_file(path_a))
	local lines_b = split_lines(read_file(path_b))

	local calls = {
		edit_call(path_a, 1, 1, lines_a, "A1"),
		edit_call(path_b, 1, 1, lines_b, "B1"),
	}
	local results = parallel.execute_batch(calls, { cwd = tmp_dir })

	assert_eq(results[1].is_error, false, "first file edit should succeed")
	assert_eq(results[2].is_error, false, "second file edit should succeed")
	assert_lines(path_a, { "A1", "a2" })
	assert_lines(path_b, { "B1", "b2" })
end)

run_test("emits start events only for potentially slow tools", function()
	local path = tmp_dir .. "/events.txt"
	write_file(path, "needle\n")
	local events = {}
	local calls = {
		{ name = "grep", args = { path = path, pattern = "needle" } },
		{ name = "read", args = { path = path } },
	}

	local results = parallel.execute_batch(calls, { cwd = tmp_dir }, function(event)
		events[#events + 1] = {
			name = event.name,
			phase = event.phase or "result",
		}
	end)

	assert_eq(results[1].is_error, false, "grep should succeed")
	assert_eq(results[2].is_error, false, "read should succeed")
	assert_eq(events[1].name, "grep")
	assert_eq(events[1].phase, "start")
	assert_eq(events[2].name, "grep")
	assert_eq(events[2].phase, "result")
	assert_eq(events[3].name, "read")
	assert_eq(events[3].phase, "result")
	assert_eq(#events, 3)
end)

run_test("deduplicates identical shell tool calls in one batch", function()
	local events = {}
	local calls = {
		{ name = "ls", args = { path = tmp_dir } },
		{ name = "ls", args = { path = tmp_dir } },
	}

	local results = parallel.execute_batch(calls, { cwd = tmp_dir }, function(event)
		events[#events + 1] = {
			name = event.name,
			phase = event.phase or "result",
		}
	end)

	assert_eq(results[1].is_error, false, "first ls should succeed")
	assert_eq(results[2].is_error, false, "duplicate ls should receive reused result")
	assert_eq(results[1].content, results[2].content, "duplicate result content should match")
	assert_eq(events[1].name, "ls")
	assert_eq(events[1].phase, "start")
	assert_eq(events[2].name, "ls")
	assert_eq(events[2].phase, "result")
	assert_eq(#events, 2)
end)

run_test("missing ls target is non-error context", function()
	local missing = tmp_dir .. "/does-not-exist"
	local calls = {
		{ name = "ls", args = { path = missing } },
		{ name = "grep", args = { path = tmp_dir, pattern = "nothing" } },
	}
	local results = parallel.execute_batch(calls, { cwd = tmp_dir })
	assert_eq(results[1].is_error, false, "missing ls target should be context, not failure")
	assert_eq(results[1].summary, "missing")
end)

run_test("deduplicates identical read tool calls in one batch", function()
	local path = tmp_dir .. "/dedupe-read.txt"
	write_file(path, "one\ntwo\nthree\n")
	local events = {}
	local calls = {
		{ name = "read", args = { path = path, offset = 1, limit = 2 } },
		{ name = "read", args = { path = path, offset = 1, limit = 2 } },
	}

	local results = parallel.execute_batch(calls, { cwd = tmp_dir }, function(event)
		events[#events + 1] = {
			name = event.name,
			phase = event.phase or "result",
			summary = event.result and event.result.summary,
		}
	end)

	assert_eq(results[1].is_error, false, "first read should succeed")
	assert_eq(results[2].is_error, false, "duplicate read should receive marker result")
	assert_contains(results[1].content, "1:")
	assert_eq(results[2].summary, "duplicate read")
	assert_contains(results[2].content, "same result as tool call #1")
	assert_eq(#events, 1, "duplicate read should not emit a second result event")
	assert_eq(events[1].name, "read")
	assert_eq(events[1].summary, "2 lines")
end)

run_test("skips exact read already visible in recent context", function()
	local path = tmp_dir .. "/already-read.txt"
	write_file(path, "one\ntwo\nthree\n")
	local key = path .. "\0" .. "1" .. "\0" .. "2"
	local events = {}

	local results = parallel.execute_batch({
		{ name = "read", args = { path = path, offset = 1, limit = 2 } },
	}, {
		cwd = tmp_dir,
		recent_read_keys = {
			[key] = { message_index = 12 },
		},
	}, function(event)
		events[#events + 1] = event
	end)

	assert_eq(results[1].is_error, false)
	assert_eq(results[1].summary, "already in context")
	assert_contains(results[1].content, "message #12")
	assert_eq(#events, 0, "already-visible read should not emit a tool event")
end)

run_test("executes different read range even when file was recently read", function()
	local path = tmp_dir .. "/different-read-range.txt"
	write_file(path, "one\ntwo\nthree\n")
	local key = path .. "\0" .. "1" .. "\0" .. "1"

	local results = parallel.execute_batch({
		{ name = "read", args = { path = path, offset = 2, limit = 1 } },
	}, {
		cwd = tmp_dir,
		recent_read_keys = {
			[key] = { message_index = 12 },
		},
	})

	assert_eq(results[1].is_error, false)
	assert_eq(results[1].summary, "1 lines")
	assert_contains(results[1].content, "2:")
end)

run_test("caps total read output in one batch", function()
	local path_a = tmp_dir .. "/read-budget-a.txt"
	local path_b = tmp_dir .. "/read-budget-b.txt"
	local wide = string.rep("x", 500)
	local lines = {}
	for _ = 1, 80 do
		lines[#lines + 1] = wide
	end
	write_file(path_a, table.concat(lines, "\n") .. "\n")
	write_file(path_b, table.concat(lines, "\n") .. "\n")

	local calls = {
		{ name = "read", args = { path = path_a, offset = 1, limit = 80 } },
		{ name = "read", args = { path = path_b, offset = 1, limit = 80 } },
		{ name = "read", args = { path = path_a, offset = 20, limit = 80 } },
	}

	local results = parallel.execute_batch(calls, { cwd = tmp_dir })

	assert_eq(results[1].is_error, false, "first read should succeed")
	assert_eq(results[2].is_error, false, "second read should succeed or be capped quietly")
	assert_eq(results[3].is_error, false, "budget cap should be non-error")
	assert_eq(results[3].summary, "read budget reached")
	assert_eq(results[3].ui_state, "deferred")
	assert_contains(results[3].content, "Read batch output budget reached")
end)

os.execute("rm -rf " .. shell.quote(tmp_dir))

io.write("\n" .. dim("─────────────────────────────────────") .. "\n")
io.write(string.format("  %s passed, %s failed\n\n",
	green(tostring(passed)), failed > 0 and red(tostring(failed)) or tostring(failed)))

os.exit(failed > 0 and 1 or 0)
