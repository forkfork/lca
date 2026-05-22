local providers = require("agent.providers")
local parallel = require("agent.parallel")
local protocol = require("agent.tool_protocol")
local system_prompt = require("agent.system_prompt")

local core = {}

local MAX_TOOL_STEPS = 40
local MAX_BATCH_SIZE = 6

local function get_provider(credentials_path)
	local provider = providers.load(credentials_path)
	return provider
end

-- Transcript logging
local transcript_file = nil

function core.set_transcript(path)
	if path then
		transcript_file = io.open(path, "w")
	else
		if transcript_file then
			transcript_file:close()
		end
		transcript_file = nil
	end
end

local function log(fmt, ...)
	if not transcript_file then return end
	transcript_file:write(string.format(fmt, ...) .. "\n")
	transcript_file:flush()
end

local function log_separator(label)
	log("\n" .. string.rep("=", 70))
	log("  %s", label)
	log(string.rep("=", 70))
end

function core.run_once(prompt, options)
	if not prompt or prompt == "" then
		error("prompt is required")
	end

	local provider = get_provider(options.credentials_path)
	local response = provider.complete({
		credentials_path = options.credentials_path,
		model = options.model,
		reasoning_effort = options.reasoning_effort,
		system_prompt = options.system_prompt or system_prompt.build({ cwd = options.cwd or "." }),
		messages = {
			{
				role = "user",
				text = prompt,
			},
		},
	}, options.on_token)

	return response.text
end

function core.run_session(session, on_token, on_tool, on_thinking)
	local provider = get_provider(session.credentials_path)
	local events = {}

	log_separator("SESSION START")
	log("Messages in context: %d", #session.messages)

	local total_tool_executions = 0
	local repl_ok, repl_mod = pcall(require, "agent.repl")

	for step = 1, MAX_TOOL_STEPS do
		-- Check for cancellation
		if repl_ok and repl_mod.cancelled then
			log_separator("CANCELLED BY USER")
			return {
				text = "",
				events = events,
			}
		end

		log_separator(string.format("LLM CALL #%d", step))
		log("Sending %d messages to model", #session.messages)

		if step > 1 and on_thinking then
			on_thinking()
		end

		local response = provider.complete({
			credentials_path = session.credentials_path,
			model = session.model,
			reasoning_effort = session.reasoning_effort,
			system_prompt = system_prompt.build({ cwd = session.cwd }),
			messages = session.messages,
		}, on_token)

		-- Check for cancellation after LLM call
		if repl_ok and repl_mod.cancelled then
			log_separator("CANCELLED BY USER")
			return {
				text = response.text or "",
				events = events,
			}
		end

		log("\n--- ASSISTANT RESPONSE ---")
		log("%s", response.text)

		local raw_tool_calls = protocol.extract_all_tool_calls(response.text)
		-- Filter out tool calls with invalid names (e.g. examples in prose)
		local registry = require("agent.tool_registry")
		local tool_calls = {}
		for _, tc in ipairs(raw_tool_calls) do
			if registry.is_valid(tc.name) then
				tool_calls[#tool_calls + 1] = tc
			end
		end
		if #tool_calls == 0 then
			local text = protocol.strip_tool_calls(response.text)
			log_separator("NO TOOL CALL - RETURNING TEXT")
			return {
				text = text,
				events = events,
			}
		end

		log("\n--- %d TOOL CALL(S) EXTRACTED ---", #tool_calls)
		for i, tc in ipairs(tool_calls) do
			log("  [%d] %s", i, tc.name)
			if tc.args then
				for k, v in pairs(tc.args) do
					local vs = tostring(v)
					if #vs > 120 then vs = vs:sub(1, 117) .. "..." end
					log("      %s = %s", k, vs)
				end
			end
		end

		-- Enforce tool budget and per-batch cap
		local batch = {}
		for i, tc in ipairs(tool_calls) do
			total_tool_executions = total_tool_executions + 1
			if total_tool_executions > MAX_TOOL_STEPS then
				log("TOOL BUDGET HIT mid-batch at call %d/%d", i, #tool_calls)
				break
			end
			if #batch >= MAX_BATCH_SIZE then
				log("BATCH CAP reached (%d), dropping remaining %d calls", MAX_BATCH_SIZE, #tool_calls - i + 1)
				break
			end
			batch[#batch + 1] = tc
		end

		-- Only store the tool call XML in the session — discard surrounding prose
		-- which is pre-result speculation/hallucination
		local clean_response = protocol.extract_only_tool_calls_text(response.text)

		-- Execute tool calls (parallel for read-only, sequential for mutating)
		session:add_assistant(clean_response)

		local MUTATING_TOOLS = { edit = true, write = true, run = true }

		local function batch_on_tool(event)
			if MUTATING_TOOLS[event.name] or (event.result and event.result.is_error) then
				log("\n--- TOOL RESULT: %s ---", event.name)
				log("is_error: %s", tostring(event.result.is_error))
				log("summary: %s", tostring(event.result.summary))
				local content_str = event.result.content or ""
				if #content_str > 500 then
					log("content: %s... [%d chars total]", content_str:sub(1, 500), #content_str)
				else
					log("content: %s", content_str)
				end
			end
			events[#events + 1] = event
			if on_tool then
				on_tool(event)
			end
		end

		local batch_results = parallel.execute_batch(batch, { cwd = session.cwd }, batch_on_tool)

		for i, tc in ipairs(batch) do
			local result = batch_results[i]
			if result then
				local msg = protocol.tool_result_message(tc.name, result, tc.args)
				session:add_tool_result(tc.name, msg)
			end
		end

		-- Check for cancellation after tool execution
		if repl_ok and repl_mod.cancelled then
			log_separator("CANCELLED BY USER")
			return {
				text = "",
				events = events,
			}
		end

		if total_tool_executions >= MAX_TOOL_STEPS then
			break
		end
	end

	log_separator("TOOL BUDGET EXHAUSTED")
	session:add_user("Tool budget reached. Stop using tools now and answer from the information already gathered.")
	local response = provider.complete({
		credentials_path = session.credentials_path,
		model = session.model,
		reasoning_effort = session.reasoning_effort,
		system_prompt = system_prompt.build({ cwd = session.cwd }),
		messages = session.messages,
	}, on_token)
	local text = protocol.strip_tool_calls(response.text)

	log("\n--- FINAL RESPONSE ---")
	log("%s", text)

	return {
		text = text ~= "" and text or "Stopped after " .. MAX_TOOL_STEPS .. " tool steps.",
		events = events,
	}
end

return core
