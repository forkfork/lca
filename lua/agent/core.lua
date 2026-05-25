local providers = require("agent.providers")
local compaction = require("agent.compaction")
local parallel = require("agent.parallel")
local protocol = require("agent.tool_protocol")
local system_prompt = require("agent.system_prompt")
local path_util = require("agent.util.path")
local json = require("agent.util.json")

local core = {}

local MAX_TOOL_STEPS = 40
local MAX_BATCH_SIZE = 6
local SLIM_CONTEXT_TOKENS = tonumber(os.getenv("LCA_SLIM_CONTEXT_TOKENS") or "") or 60000
local MAX_CONSECUTIVE_READ_ONLY_BATCHES = tonumber(os.getenv("LCA_MAX_READ_ONLY_BATCHES") or "") or 5

local DIRECT_RETURN_TOOLS = {
	job_output = true,
	job_status = true,
	job_stop = true,
	job_wait = true,
}

local function last_user_text(session)
	for i = #session.messages, 1, -1 do
		if session.messages[i].role == "user" and not session.messages[i].tool_name then
			return session.messages[i].text or ""
		end
	end
	return ""
end

local function direct_tool_result_text(session, batch, batch_results)
	if #batch ~= 1 then return nil end
	local tc = batch[1]
	local result = batch_results[1]
	if not result or result.is_error then return nil end
	if DIRECT_RETURN_TOOLS[tc.name] then
		return result.content or ""
	end
	if tc.name == "run" then
		local command = (tc.args and tc.args.command) or ""
		local prompt = last_user_text(session):lower()
		if command:match("^%s*curl%s") or prompt:match("^%s*curl%s") or prompt:find("curl it", 1, true) then
			return result.content or ""
		end
	end
	return nil
end

local READ_ONLY_TOOLS = {
	find = true,
	grep = true,
	job_output = true,
	job_status = true,
	ls = true,
	read = true,
}

local function batch_is_read_only(batch)
	if #batch == 0 then return false end
	for _, tc in ipairs(batch) do
		if not READ_ONLY_TOOLS[tc.name] then
			return false
		end
	end
	return true
end

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

function core.debug_log(fmt, ...)
	log(fmt, ...)
end

local function log_separator(label)
	log("\n" .. string.rep("=", 70))
	log("  %s", label)
	log(string.rep("=", 70))
end

local function sorted_count_string(counts)
	local keys = {}
	for key in pairs(counts or {}) do
		keys[#keys + 1] = key
	end
	table.sort(keys)
	local parts = {}
	for _, key in ipairs(keys) do
		parts[#parts + 1] = tostring(key) .. "=" .. tostring(counts[key])
	end
	return #parts > 0 and table.concat(parts, ",") or "(none)"
end

local function clean_assistant_text(text)
	return protocol.strip_tool_results(protocol.strip_tool_calls(text or ""))
end

local function compact_log_text(text, max_len)
	text = tostring(text or "")
	text = text:gsub("\r", "\\r"):gsub("\n", "\\n")
	max_len = max_len or 1200
	if #text > max_len then
		return text:sub(1, max_len) .. "...[" .. tostring(#text) .. " chars]"
	end
	return text
end

local function attr(text, name)
	return tostring(text or ""):match(name .. '="([^"]*)"')
end

local function normalized_number(value, fallback)
	local number = tonumber(value)
	if not number then
		number = fallback
	end
	return tostring(math.floor(number or 0))
end

local function read_key(path, offset, limit)
	if not path or path == "" then
		return nil
	end
	return table.concat({
		path,
		normalized_number(offset, 1),
		normalized_number(limit, -1),
	}, "\0")
end

local function tool_call_key(tc)
	if not tc or not tc.name then
		return nil
	end
	local args = tc.args or {}
	local encoded_args = {}
	for key, value in pairs(args) do
		if key ~= "_raw_content" then
			encoded_args[key] = value
		end
	end
	local ok, encoded = pcall(json.encode, encoded_args)
	if not ok then
		encoded = tostring(tc.raw or "")
	end
	return table.concat({
		tostring(tc.name),
		tostring(encoded),
		tostring(args._raw_content or ""),
	}, "\0")
end

local function tool_calls_text(tool_calls)
	local parts = {}
	for _, tc in ipairs(tool_calls or {}) do
		local args = {}
		for key, value in pairs(tc.args or {}) do
			if key ~= "_raw_content" then
				args[key] = value
			end
		end
		local ok, encoded = pcall(json.encode, args)
		if not ok then
			encoded = tc.raw or "{}"
		end
		parts[#parts + 1] = '<tool_call name="' .. tostring(tc.name) .. '">'
		parts[#parts + 1] = encoded
		local raw_content = tc.args and tc.args._raw_content
		if raw_content ~= nil then
			parts[#parts + 1] = tostring(raw_content)
		end
		parts[#parts + 1] = "</tool_call>"
	end
	return table.concat(parts, "\n")
end

local function recent_read_keys(session)
	local keys = {}
	local modified = {}
	for i = #session.messages, 1, -1 do
		local message = session.messages[i]
		if message and message.tool_name then
			local path = attr(message.text, "path")
			local resolved = path and path_util.resolve(path, session.cwd or ".")
			if resolved and (message.tool_name == "edit" or message.tool_name == "write") then
				modified[resolved] = true
			elseif resolved
				and message.tool_name == "read"
				and not message.slimmed
				and not modified[resolved]
				and not tostring(message.text or ""):find("Read skipped;", 1, true)
				and not tostring(message.text or ""):find("Duplicate read skipped;", 1, true) then
				local key = read_key(resolved, attr(message.text, "offset"), attr(message.text, "limit"))
				if key and not keys[key] then
					keys[key] = {
						path = path,
						offset = attr(message.text, "offset"),
						limit = attr(message.text, "limit"),
						message_index = i,
					}
				end
			end
		end
	end
	return keys
end

function core.run_once(prompt, options)
	if not prompt or prompt == "" then
		error("prompt is required")
	end

	local provider = get_provider(options.credentials_path)
	local response = provider.complete({
		credentials_path = options.credentials_path,
		session_id = options.session_id,
		model = options.model,
		reasoning_effort = options.reasoning_effort,
		service_tier = options.service_tier,
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
	local consecutive_read_only_batches = 0
	local read_only_guard_used = false
	local last_response_meta = nil
	local repl_ok, repl_mod = pcall(require, "agent.repl")

	local function response_meta(response)
		if not response then return last_response_meta end
		return {
			_transport = response._transport,
			_transport_reused = response._transport_reused,
			_transport_fallback = response._transport_fallback,
			_response_bytes = response._response_bytes,
			_http_status = response._http_status,
		}
	end

	for step = 1, MAX_TOOL_STEPS do
		-- Check for cancellation
		if repl_ok and repl_mod.cancelled then
			log_separator("CANCELLED BY USER")
			return {
				text = "",
				events = events,
				_response_meta = last_response_meta,
			}
		end

		if step > 1 and on_thinking then
			on_thinking({
				step = step,
				messages = #session.messages,
				tools = total_tool_executions,
			})
		end

		if SLIM_CONTEXT_TOKENS > 0 and session:estimated_session_tokens() >= SLIM_CONTEXT_TOKENS then
			local slimmed, changed, bytes_removed, slim_details = compaction.slim_history(session)
			if slimmed then
				local reason_counts = {}
				local label_counts = {}
				for _, detail in ipairs(slim_details or {}) do
					local reason = tostring(detail.reason or "unknown")
					local label = tostring(detail.label or "message")
					reason_counts[reason] = (reason_counts[reason] or 0) + 1
					label_counts[label] = (label_counts[label] or 0) + 1
				end
				local file_ops = compaction.file_operations(session.messages, session.compaction_details)
				log("[context] slim audit messages=%d bytes_removed=%d approx_tokens_saved=%d session_tokens=%d reasons=\"%s\" labels=\"%s\" files=\"read=%d modified=%d\"",
					changed,
					bytes_removed,
					math.floor(bytes_removed / 4),
					session:estimated_session_tokens(),
					sorted_count_string(reason_counts),
					sorted_count_string(label_counts),
					#(file_ops.read_files or {}),
					#(file_ops.modified_files or {})
				)
				for _, detail in ipairs(slim_details or {}) do
					local path = detail.path and (" path=" .. tostring(detail.path)) or ""
					log("[context] slim detail #%d %s%s reason=%s bytes=%d->%d",
						tonumber(detail.index) or 0,
						tostring(detail.label or "message"),
						path,
						tostring(detail.reason or "unknown"),
						tonumber(detail.before) or 0,
						tonumber(detail.after) or 0
					)
				end
				if on_thinking then
					on_thinking({
						step = step,
						messages = #session.messages,
						tools = total_tool_executions,
						status = "slimmed context  " .. tostring(changed) .. " messages",
					})
				end
			end
		end
		do
			local coalesced, coalesced_count, coalesced_bytes = compaction.coalesce_slimmed_history(session)
			if coalesced then
				log("[context] coalesced slimmed history messages=%d bytes_removed=%d remaining_messages=%d session_tokens=%d",
					coalesced_count,
					coalesced_bytes,
					#session.messages,
					session:estimated_session_tokens()
				)
				if on_thinking then
					on_thinking({
						step = step,
						messages = #session.messages,
						tools = total_tool_executions,
						status = "coalesced context  " .. tostring(coalesced_count) .. " messages",
					})
				end
			end
		end

		log_separator(string.format("LLM CALL #%d", step))
		log("Sending %d messages to model", #session.messages)

		local response = provider.complete({
			credentials_path = session.credentials_path,
			session_id = session.id,
			model = session.model,
			reasoning_effort = session.reasoning_effort,
			service_tier = session.service_tier,
			system_prompt = session.get_system_prompt and session:get_system_prompt() or system_prompt.build({ cwd = session.cwd }),
			messages = session.messages,
		}, on_token)
		last_response_meta = response_meta(response)

		-- Check for cancellation after LLM call
		if repl_ok and repl_mod.cancelled then
			log_separator("CANCELLED BY USER")
			return {
				text = response.text or "",
				events = events,
				_response_meta = last_response_meta,
			}
		end

		log("\n--- ASSISTANT RESPONSE ---")
		log("%s", response.text)
		if response._partial_salvage then
			local salvaged_calls = tonumber(response._partial_salvaged_calls) or 0
			log("[codex] using salvaged partial response tool_calls=%d response_bytes=%d",
				salvaged_calls,
				tonumber(response._response_bytes) or 0
			)
			if on_thinking then
				on_thinking({
					step = step,
					messages = #session.messages,
					tools = total_tool_executions,
					status = "salvaged partial response  " .. tostring(salvaged_calls) .. " tools",
				})
			end
		end

		local raw_tool_calls = protocol.extract_all_tool_calls(response.text)
		-- Filter out tool calls with invalid names (e.g. examples in prose)
		local registry = require("agent.tool_registry")
		local tool_calls = {}
		local invalid_tool_names = {}
		for _, tc in ipairs(raw_tool_calls) do
			if registry.is_valid(tc.name) then
				tool_calls[#tool_calls + 1] = tc
			else
				invalid_tool_names[#invalid_tool_names + 1] = tostring(tc.name)
			end
		end
		if #raw_tool_calls > 0 or (response.text or ""):find("<tool_call", 1, true) then
			log("[tool-protocol] raw_calls=%d valid_calls=%d invalid_names=%s contains_open=%s contains_close=%s response_sample=%s",
				#raw_tool_calls,
				#tool_calls,
				#invalid_tool_names > 0 and table.concat(invalid_tool_names, ",") or "(none)",
				tostring((response.text or ""):find("<tool_call", 1, true) ~= nil),
				tostring((response.text or ""):find("</tool_call>", 1, true) ~= nil),
				compact_log_text(response.text, 1200)
			)
		elseif #raw_tool_calls == 0 then
			log("[tool-protocol] no tool calls response_sample=%s", compact_log_text(response.text, 1200))
		end
		local protocol_ok, protocol_err = protocol.validate_tool_calls(tool_calls)
		if not protocol_ok then
			local text = "Tool call blocked: " .. protocol_err
			log_separator("TOOL PROTOCOL VIOLATION")
			log("[tool-protocol] violation=%s response_sample=%s",
				tostring(protocol_err),
				compact_log_text(response.text, 2000)
			)
			log("%s", text)
			return {
				text = text,
				events = events,
				_response_meta = last_response_meta,
			}
		end
		if #tool_calls == 0 then
			local text = clean_assistant_text(response.text)
			if session.record_usage then
				session:record_usage(response._usage, #session.messages)
			end
			log_separator("NO TOOL CALL - RETURNING TEXT")
			return {
				text = text,
				events = events,
				_response_meta = last_response_meta,
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
		local seen_tool_calls = {}
		for i, tc in ipairs(tool_calls) do
			local key = tool_call_key(tc)
			if key and seen_tool_calls[key] then
				log("DUPLICATE TOOL CALL dropped at call %d/%d: %s", i, #tool_calls, tc.name)
				goto continue_tool_call
			end
			if key then
				seen_tool_calls[key] = true
			end
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
			::continue_tool_call::
		end
		local read_only_batch = batch_is_read_only(batch)
		if read_only_batch then
			consecutive_read_only_batches = consecutive_read_only_batches + 1
		else
			consecutive_read_only_batches = 0
			read_only_guard_used = false
		end
		local guard_read_only_loop = read_only_batch
			and MAX_CONSECUTIVE_READ_ONLY_BATCHES > 0
			and consecutive_read_only_batches > MAX_CONSECUTIVE_READ_ONLY_BATCHES
		if guard_read_only_loop then
			local tool_names = {}
			for _, tc in ipairs(batch) do
				tool_names[#tool_names + 1] = tc.name
			end
			log("[context] read-only loop guard batches=%d tools=%s",
				consecutive_read_only_batches,
				table.concat(tool_names, ",")
			)
			if read_only_guard_used then
				local text = "Stopped after repeated read-only tool batches. Make a change, run a verification command, or explain the blocker instead of reading more context."
				log_separator("READ-ONLY TOOL LOOP STOPPED")
				log("%s", text)
				return {
					text = text,
					events = events,
					_response_meta = last_response_meta,
				}
			end
			read_only_guard_used = true
			session:add_user(table.concat({
				"Read-only loop guard: you have repeatedly called read-only tools without making changes.",
				"Do not call read, grep, find, ls, job_status, or job_output again for this task unless you first make a concrete edit/write/run action or explain exactly what blocks progress.",
				"Use the context already gathered. If enough information is available, make the edit now.",
			}, "\n"))
			if on_thinking then
				on_thinking({
					step = step,
					messages = #session.messages,
					tools = total_tool_executions,
					status = "read-only loop guard",
				})
			end
		else

			-- Only store the actually executed tool calls. The model can emit
			-- duplicates or calls past the batch cap; keeping those in history
			-- teaches the next turn the wrong continuation.
			local clean_response = tool_calls_text(batch)

			-- Execute tool calls (parallel for read-only, sequential for mutating)
			session:add_assistant(clean_response)
			if session.record_usage then
				session:record_usage(response._usage, #session.messages)
			end

			local MUTATING_TOOLS = { edit = true, write = true, run = true }

			local function batch_on_tool(event)
				if event.phase == "start" then
					log("\n--- TOOL START: %s ---", event.name)
					if event.args then
						for k, v in pairs(event.args) do
							local vs = tostring(v)
							if #vs > 120 then vs = vs:sub(1, 117) .. "..." end
							log("      %s = %s", k, vs)
						end
					end
				elseif MUTATING_TOOLS[event.name] or (event.result and event.result.is_error) then
					log("\n--- TOOL RESULT: %s ---", event.name)
					log("is_error: %s", tostring(event.result and event.result.is_error))
					log("summary: %s", tostring(event.result and event.result.summary))
					local content_str = (event.result and event.result.content) or ""
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

			local batch_results = parallel.execute_batch(batch, {
				cwd = session.cwd,
				recent_read_keys = recent_read_keys(session),
			}, batch_on_tool)

			for i, tc in ipairs(batch) do
				local result = batch_results[i]
				if result then
					local msg = protocol.tool_result_message(tc.name, result, tc.args)
					session:add_tool_result(tc.name, msg)
				end
			end

			local direct_text = direct_tool_result_text(session, batch, batch_results)
			if direct_text then
				log_separator("DIRECT TOOL RESULT - RETURNING TEXT")
				log("%s", direct_text)
				return {
					text = direct_text,
					events = events,
					_response_meta = last_response_meta,
				}
			end

			-- Check for cancellation after tool execution
			if repl_ok and repl_mod.cancelled then
				log_separator("CANCELLED BY USER")
				return {
					text = "",
					events = events,
					_response_meta = last_response_meta,
				}
			end
		end

		if total_tool_executions >= MAX_TOOL_STEPS then
			break
		end
	end

	log_separator("TOOL BUDGET EXHAUSTED")
	session:add_user("Tool budget reached. Stop using tools now and answer from the information already gathered.")
	local response = provider.complete({
		credentials_path = session.credentials_path,
		session_id = session.id,
		model = session.model,
		reasoning_effort = session.reasoning_effort,
		service_tier = session.service_tier,
		system_prompt = session.get_system_prompt and session:get_system_prompt() or system_prompt.build({ cwd = session.cwd }),
		messages = session.messages,
	}, on_token)
	last_response_meta = response_meta(response)
	local text = clean_assistant_text(response.text)
	if session.record_usage then
		session:record_usage(response._usage, #session.messages)
	end

	log("\n--- FINAL RESPONSE ---")
	log("%s", text)

	return {
		text = text ~= "" and text or "Stopped after " .. MAX_TOOL_STEPS .. " tool steps.",
		events = events,
		_response_meta = last_response_meta,
	}
end

return core
