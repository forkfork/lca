#!/usr/bin/env lua

local script_dir = arg[0]:match("^(.*)/[^/]+$") or "."
local project_dir = script_dir .. "/.."
package.path = project_dir .. "/lua/?.lua;" .. project_dir .. "/lua/?/init.lua;" .. project_dir .. "/lua/?/?.lua;" .. package.path
pcall(require, "luarocks.loader")

local session_module = require("agent.session")
local shell = require("agent.util.shell")

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

local tmp_dir = os.tmpname() .. "_lca_session_tests"
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

local function write_file(path, content)
	local file = assert(io.open(path, "w"))
	file:write(content)
	file:close()
end

io.write("\n" .. dim("═══ Session Tests ═══") .. "\n\n")

run_test("session id is saved and loaded", function()
	local path = tmp_dir .. "/session.json"
	local first = session_module.create({ session_id = "lca-test-session" })
	first:add_user("hello")
	local ok, err = first:save(path)
	if not ok then
		error(err)
	end

	local second = session_module.create({})
	local loaded, load_err = second:load(path)
	if not loaded then
		error(load_err)
	end

	assert_eq(second.id, "lca-test-session")
	assert_eq(second.messages[1].text, "hello")
end)

run_test("compaction details are saved and loaded", function()
	local path = tmp_dir .. "/session-details.json"
	local first = session_module.create({ session_id = "lca-test-session" })
	first.compaction_details = {
		read_files = { "README.md" },
		modified_files = { "app.lua" },
	}
	local ok, err = first:save(path)
	if not ok then
		error(err)
	end

	local second = session_module.create({})
	local loaded, load_err = second:load(path)
	if not loaded then
		error(load_err)
	end

	assert_eq(second.compaction_details.read_files[1], "README.md")
	assert_eq(second.compaction_details.modified_files[1], "app.lua")
end)

run_test("usage-aware estimate uses last usage plus trailing messages", function()
	local session = session_module.create({})
	session:add_user("before")
	session:add_assistant("assistant response")
	session:record_usage({
		prompt_tokens = 1000,
		cached_tokens = 256,
		output_tokens = 100,
		total_tokens = 1100,
	}, #session.messages)
	session:add_tool_result("read", string.rep("x", 400))

	local tokens, details = session:estimated_model_input_tokens_usage_aware()
	assert_eq(details.usage_tokens, 1100)
	assert_eq(details.message_index, 2)
	if tokens <= 1100 then
		error("expected trailing tool result tokens to be added")
	end
end)

run_test("usage history is saved and loaded", function()
	local path = tmp_dir .. "/session-usage-history.json"
	local first = session_module.create({ session_id = "lca-test-session" })
	first:record_usage({ prompt_tokens = 1000, cached_tokens = 100, output_tokens = 10, total_tokens = 1010 }, 1)
	first:record_usage({ prompt_tokens = 1000, cached_tokens = 500, output_tokens = 10, total_tokens = 1010 }, 2)
	local ok, err = first:save(path)
	if not ok then
		error(err)
	end

	local second = session_module.create({})
	local loaded, load_err = second:load(path)
	if not loaded then
		error(load_err)
	end

	assert_eq(#second.usage_history, 2)
	assert_eq(second.usage_history[1].cached_percent, 10)
	assert_eq(second.usage_history[2].cached_percent, 50)
	assert_eq(second.last_usage.cached_tokens, 500)
end)

run_test("system prompt is frozen for cache stability", function()
	local path = tmp_dir .. "/session-system-prompt.json"
	local cache_project_dir = tmp_dir .. "/project"
	os.execute("mkdir -p " .. shell.quote(cache_project_dir))
	local first = session_module.create({ session_id = "lca-test-session" })
	first.cwd = cache_project_dir

	local prompt_before = first:get_system_prompt()
	local file = io.open(cache_project_dir .. "/pyproject.toml", "w")
	assert(file)
	file:write("[project]\nname = \"later\"\n")
	file:close()
	local prompt_after = first:get_system_prompt()
	assert_eq(prompt_after, prompt_before)

	local ok, err = first:save(path)
	if not ok then
		error(err)
	end

	local second = session_module.create({})
	local loaded, load_err = second:load(path)
	if not loaded then
		error(load_err)
	end
	assert_eq(second:get_system_prompt(), prompt_before)
end)

run_test("loaded session remaps stale codex model for deepseek credentials", function()
	local credentials_path = tmp_dir .. "/deepseek-credentials.json"
	write_file(credentials_path, [[{
		"provider": "deepseek",
		"providers": {
			"deepseek": { "provider": "deepseek", "apiKey": "test", "model": "deepseek-v4-flash" }
		}
	}]])
	local path = tmp_dir .. "/session-deepseek-model.json"
	write_file(path, [[{
		"id": "lca-test-session",
		"model": "gpt-5.5",
		"credentials_path": "]] .. credentials_path .. [[",
		"messages": []
	}]])

	local loaded_session = session_module.create({ credentials_path = credentials_path })
	local loaded, load_err = loaded_session:load(path)
	if not loaded then
		error(load_err)
	end
	assert_eq(loaded_session.model, "deepseek-v4-flash")
end)

os.execute("rm -rf " .. shell.quote(tmp_dir))

io.write("\n" .. dim("─────────────────────────────────────") .. "\n")
io.write(string.format("  %s passed, %s failed\n\n",
	green(tostring(passed)), failed > 0 and red(tostring(failed)) or tostring(failed)))

os.exit(failed > 0 and 1 or 0)
