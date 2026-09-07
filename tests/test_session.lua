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

run_test("new Codex sessions default to Astra with native tools", function()
	local default = session_module.create({})
	assert_eq(default.model, "gpt-6-astra")
	assert_eq(default.native_tool_calling, true)
	assert_eq(default.grep_evidence, true)
	assert_eq(session_module.create({ grep_evidence = false }).grep_evidence, false)
	assert_eq(default.stale_edit_evidence, true)
	assert_eq(session_module.create({ stale_edit_evidence = false }).stale_edit_evidence, false)
end)

run_test("retired experiments cannot be enabled in new sessions", function()
	for _, key in ipairs({ "delegate_readonly_enabled", "tool_dag_enabled", "readonly_fork_join_enabled", "delegate_readonly_profile" }) do
		local ok, err = pcall(session_module.create, { [key] = key == "delegate_readonly_profile" and "compact_luna" or true })
		assert_eq(ok, false, key)
		assert(tostring(err):find("retired experiment option", 1, true), tostring(err))
	end
end)

run_test("old experiment sessions resume without retired flags or cached guidance", function()
	local path = tmp_dir .. "/retired-experiments.json"
	local data = session_module.create({}):serialize()
	data.system_prompt_version = 25
	data.system_prompt_native_tools = true
	data.system_prompt = "Prefer delegate_readonly and dependency DAGs."
	data.system_prompt_delegate_readonly = true
	data.system_prompt_tool_dag = true
	data.delegate_readonly_enabled = true
	data.delegate_readonly_profile = "compact_luna"
	data.tool_dag_enabled = true
	data.readonly_fork_join_enabled = true
	write_file(path, require("cjson").encode(data))
	local resumed = session_module.create({})
	assert(resumed:load(path))
	for _, key in ipairs({ "delegate_readonly_enabled", "delegate_readonly_profile", "tool_dag_enabled", "readonly_fork_join_enabled" }) do
		assert_eq(resumed[key], nil, key)
		assert_eq(resumed:serialize()[key], nil, "resaved " .. key)
	end
	local prompt = resumed:get_system_prompt()
	assert_eq(prompt:find("Prefer delegate_readonly", 1, true), nil)
	assert_eq(prompt:find("dependency DAGs", 1, true), nil)
end)

run_test("Astra reasoning mapping is model-aware", function()
	for _, effort in ipairs({ "low", "medium", "high", "xhigh", "max" }) do
		assert_eq(session_module.create({ reasoning_effort = effort }).reasoning_effort, effort)
	end
	for _, effort in ipairs({ "none", "minimal" }) do
		assert_eq(session_module.create({ reasoning_effort = effort }).reasoning_effort, "low")
	end
	assert_eq(session_module.create({ model = "gpt-5.6-sol", reasoning_effort = "none" }).reasoning_effort, "none")
	assert_eq(pcall(session_module.create, { model = "gpt-5.6-sol", reasoning_effort = "max" }), false)
	assert_eq(pcall(session_module.create, { reasoning_effort = "ultra" }), false)
end)

run_test("resume rebuilds a different model's prompt and maps old reasoning", function()
	local path = tmp_dir .. "/session-sol-to-astra.json"
	local original = session_module.create({ model = "gpt-5.6-sol", reasoning_effort = "none" })
	original:get_system_prompt()
	assert(original:save(path))
	local resumed = session_module.create({})
	assert(resumed:load(path))
	assert_eq(resumed.reasoning_effort, "low")
	assert_eq(resumed.system_prompt, nil)
	assert(resumed:get_system_prompt():find("Runtime: model=gpt-6-astra", 1, true))
end)

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

run_test("loading repairs native function calls without matching outputs", function()
	local path = tmp_dir .. "/session-orphan-call.json"
	local first = session_module.create({ session_id = "lca-orphan-session" })
	first:add_assistant("tool batch", {
		{ type = "reasoning", id = "rs_1", encrypted_content = "opaque" },
		{ type = "function_call", call_id = "call_ok", name = "read", arguments = '{"path":"README.md"}' },
		{ type = "function_call", call_id = "call_orphan", name = "read", arguments = '{"path":"missing.md"}' },
	})
	first:add_tool_result("read", "contents", "call_ok")
	assert(first:save(path))

	local second = session_module.create({})
	assert(second:load(path))
	assert_eq(second.native_history_repairs, 1)
	assert_eq(#second.messages[1].provider_items, 2)
	assert_eq(second.messages[1].provider_items[2].call_id, "call_ok")
	if not second:load_message(path):find("repaired 1 orphaned tool call", 1, true) then
		error("load message did not disclose native history repair")
	end
end)

run_test("fresh default save archives the previous project session", function()
	local uv = require("luv")
	local original_cwd = assert(uv.cwd())
	local project = tmp_dir .. "/fresh-project"
	os.execute("mkdir -p " .. shell.quote(project))
	assert(uv.chdir(project))
	local ok, err = pcall(function()
		local previous = session_module.create({ session_id = "lca-previous" })
		previous:add_user("old work")
		assert(previous:save())
		local fresh = session_module.create({ session_id = "lca-fresh" })
		fresh:add_user("new work")
		assert(fresh:save())
		local archived = assert(io.open(session_module.SESSION_ARCHIVE_DIR .. "/lca-previous.json", "r"))
		local content = archived:read("*a")
		archived:close()
		if not content:find("old work", 1, true) then error("previous session was not archived") end
		local latest = session_module.create({})
		assert(latest:load())
		assert_eq(latest.id, "lca-fresh")
	end)
	uv.chdir(original_cwd)
	if not ok then error(err) end
end)

run_test("resume command loads an explicit prior session", function()
	local commands = require("agent.commands")
	local path = tmp_dir .. "/resume-session.json"
	local previous = session_module.create({ session_id = "lca-resumed" })
	previous:add_user("resume me")
	assert(previous:save(path))
	local fresh = session_module.create({ session_id = "lca-fresh" })
	local notices = {}
	commands.dispatch("/resume " .. path, fresh, {
		muted = function(message) notices[#notices + 1] = message end,
		error = function(message) error(message) end,
	})
	assert_eq(fresh.id, "lca-resumed")
	assert_eq(fresh.messages[1].text, "resume me")
	if not notices[1]:find("session loaded", 1, true) then error("resume did not report loaded session") end
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

run_test("turn ast evidence is saved and loaded", function()
	local path = tmp_dir .. "/session-turn-ast.json"
	local first = session_module.create({ session_id = "lca-test-session" })
	first.last_turn_ast_summary = "intent=ok(create Lua auth API)\nchanges=ok(1 file saved  app.lua)"
	first.last_turn_ast_snapshot = {
		kind = "turn",
		status = "ok",
		children = {
			{ kind = "changes", status = "ok", summary = "1 file saved  app.lua" },
		},
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

	assert_eq(second.last_turn_ast_summary, first.last_turn_ast_summary)
	assert_eq(second.last_turn_ast_snapshot.kind, "turn")
	assert_eq(second.last_turn_ast_snapshot.children[1].kind, "changes")
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

run_test("system prompt bounds duplicate verification evidence", function()
	local s = session_module.create({ model = "gpt-5.6-sol" })
	local prompt = s:get_system_prompt()
	if not prompt:find("Runtime: model=gpt-5.6-sol Linux ", 1, true) then
		error("compact runtime identity missing")
	end
	if not prompt:find("## Verification sufficiency", 1, true) then
		error("verification sufficiency section missing")
	end
	if not prompt:find("do not rerun unchanged checks", 1, true) then
		error("duplicate verification boundary missing")
	end
	if not prompt:find("run the relevant documented verification once", 1, true) then
		error("post-fix verification requirement missing")
	end
	if not prompt:find("ground high-risk contract seams", 1, true) then
		error("external API grounding boundary missing")
	end
	if not prompt:find("still perform safe static checks", 1, true) then
		error("do-not-run static verification boundary missing")
	end
	if not prompt:find("use at most one inventory call", 1, true) then
		error("blank-workspace inspection boundary missing")
	end
	if not prompt:find("at most three focused searches", 1, true) then
		error("web research boundary missing")
	end
	if not prompt:find("explicit acceptance checklist", 1, true) then
		error("researched requirements checklist missing")
	end
	if not prompt:find("Separate fast deterministic local checks", 1, true) then
		error("external verification separation missing")
	end
	if not prompt:find("syntax checks and static builds do not prove deployability", 1, true) then
		error("deployment evidence boundary missing")
	end
end)

run_test("native tools cannot be disabled", function()
	local native = session_module.create({ model = "gpt-5.6-sol", native_tool_calling = false })
	assert_eq(native.native_tool_calling, true)
end)

run_test("retired saved runtime choices are ignored on resume", function()
	local path = tmp_dir .. "/session-native-tools.json"
	write_file(path, [[{
		"id": "lca-old-runtime",
		"model": "gpt-5.5",
		"native_tool_calling": false,
		"credentials_path": "/tmp/deepseek.json",
		"messages": []
	}]])
	local second = session_module.create({})
	assert(second:load(path))
	assert_eq(second.model, "gpt-6-astra")
	assert_eq(second.native_tool_calling, true)
	assert_eq(second.credentials_path, session_module.create({}).credentials_path)
end)

run_test("legacy inherited GPT-5.5 sessions migrate to Astra", function()
	local path = tmp_dir .. "/session-legacy-default-model.json"
	write_file(path, [[{
		"id": "lca-legacy-default",
		"model": "gpt-5.5",
		"native_tool_calling": false,
		"native_tool_calling_explicit": false,
		"messages": []
	}]])
	local migrated = session_module.create({})
	assert(migrated:load(path))
	assert_eq(migrated.model, "gpt-6-astra")
	assert_eq(migrated.native_tool_calling, true)
end)

run_test("unsupported models are rejected", function()
	local ok, err = pcall(session_module.create, { model = "gpt-5.5" })
	assert_eq(ok, false)
	if not tostring(err):find("unsupported model", 1, true) then error(err) end
end)

run_test("eval launch tier overrides a saved session model", function()
	local path = tmp_dir .. "/session-launch-model.json"
	write_file(path, [[{ "id": "old", "model": "gpt-5.5", "messages": [] }]])
	local launched = session_module.create({ model = "gpt-5.6-terra" })
	assert(launched:load(path))
	assert_eq(launched.model, "gpt-5.6-terra")
	assert_eq(launched.native_tool_calling, true)
end)

run_test("old saved system prompt is rebuilt after prompt version changes", function()
	local path = tmp_dir .. "/session-old-system-prompt.json"
	write_file(path, [[{
		"id": "lca-test-session",
		"model": "gpt-5.5",
		"messages": [],
		"system_prompt": "old prompt without new tools",
		"system_prompt_version": 1
	}]])

	local loaded_session = session_module.create({})
	local loaded, load_err = loaded_session:load(path)
	if not loaded then
		error(load_err)
	end
	assert_eq(loaded_session.system_prompt, nil)
	assert_eq(loaded_session.model, "gpt-6-astra")
	local rebuilt = loaded_session:get_system_prompt()
	if rebuilt == "old prompt without new tools" then
		error("old prompt was not rebuilt")
	end
	if not rebuilt:find("update_plan", 1, true) then
		error("rebuilt prompt does not include update_plan")
	end
	assert_eq(loaded_session.system_prompt_version, session_module.SYSTEM_PROMPT_VERSION)
end)

run_test("controlled experiment knobs survive session handoff", function()
	local path = tmp_dir .. "/session-experiment.json"
	local first = session_module.create({
		session_id = "lca-experiment-session",
		read_only_batch_cap = 4,
		read_batch_bytes = 48000,
	})
	local ok, err = first:save(path)
	if not ok then error(err) end
	local second = session_module.create({})
	local loaded, load_err = second:load(path)
	if not loaded then error(load_err) end
	assert_eq(second.read_only_batch_cap, 4)
	assert_eq(second.read_batch_bytes, 48000)
end)

run_test("removed autonomous command is unknown and leaves session unchanged", function()
	local commands = require("agent.commands")
	local errors, help = {}, {}
	local ui = {
		muted = function(message) help[#help + 1] = message end,
		block = function(message) help[#help + 1] = message end,
		error = function(message) errors[#errors + 1] = message end,
	}
	local s = session_module.create({ session_id = "lca-test-session" })
	s.cwd = tmp_dir
	local prompt = s:get_system_prompt()
	local count = #s.messages
	for _, command in ipairs({ "/insanitywolf", "/insanitywolf on", "/insanitywolf off" }) do
		assert_eq(commands.dispatch(command, s, ui), false)
	end
	assert_eq(#errors, 3)
	assert(errors[1]:find("unknown command", 1, true))
	assert_eq(#s.messages, count)
	assert_eq(s:get_system_prompt(), prompt)
	commands.dispatch("/help", s, ui)
	assert(not table.concat(help, "\n"):find("insanitywolf", 1, true))
end)

os.execute("rm -rf " .. shell.quote(tmp_dir))

io.write("\n" .. dim("─────────────────────────────────────") .. "\n")
io.write(string.format("  %s passed, %s failed\n\n",
	green(tostring(passed)), failed > 0 and red(tostring(failed)) or tostring(failed)))

os.exit(failed > 0 and 1 or 0)
