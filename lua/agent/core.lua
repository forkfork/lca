local providers = require("agent.providers")
local compaction = require("agent.compaction")
local context_limits = require("agent.context_limits")
local parallel = require("agent.parallel")
local protocol = require("agent.tool_protocol")
local system_prompt = require("agent.system_prompt")
local path_util = require("agent.util.path")
local json = require("agent.util.json")
local uv = require("luv")
local operational_state = require("agent.operational_state")

local core = {}

local MAX_TOOL_STEPS = 40
local MAX_BATCH_SIZE = 10
local MAX_READ_ONLY_BATCH_SIZE = 7
local SLIM_CONTEXT_TOKENS = 60000
local NORMAL_TOOL_RESERVE = 12
local NORMAL_FAILURE_RECOVERY_STEPS = 12

local function last_user_text(session)
	for i = #session.messages, 1, -1 do
		if session.messages[i].role == "user" and not session.messages[i].tool_name then
			return session.messages[i].text or ""
		end
	end
	return ""
end

local function research_build_request(text)
	text = tostring(text or ""):lower()
	local asks_for_research = text:find("search", 1, true)
		or text:find("research", 1, true)
		or text:find("look up", 1, true)
		or text:find("current docs", 1, true)
		or text:find("documentation", 1, true)
	local asks_for_build = text:find("build", 1, true)
		or text:find("create", 1, true)
		or text:find("implement", 1, true)
		or text:find("setup", 1, true)
		or text:find("set up", 1, true)
		or text:find("demo", 1, true)
	return asks_for_research ~= nil and asks_for_build ~= nil
end

local READ_ONLY_TOOLS = {
	find = true,
	grep = true,
	job_output = true,
	job_status = true,
	ls = true,
	read = true,
}

local FILE_MUTATION_TOOLS = {
	edit = true,
	multi_edit = true,
	write = true,
}

local function file_target(tc, cwd)
	local args = tc.args or {}
	if not args.path or args.path == "" then return nil end
	return path_util.resolve(args.path, cwd or ".")
end

-- A model sometimes emits a useful mutation and then speculative follow-up reads in
-- one response. Tool results are unavailable while that response is being generated,
-- so execute the coherent prefix instead of allowing a later read to invalidate the
-- earlier mutation in parallel.execute_batch.
local function dependency_safe_prefix(batch, cwd)
	local mutated = {}
	for index, tc in ipairs(batch) do
		local target = file_target(tc, cwd)
		if tc.name == "read" and target and mutated[target] then
			local prefix = {}
			for i = 1, index - 1 do prefix[i] = batch[i] end
			return prefix, #batch - index + 1, target
		end
		if FILE_MUTATION_TOOLS[tc.name] and target then
			mutated[target] = true
		end
	end
	return batch, 0, nil
end

local function batch_is_read_only(batch)
	if #batch == 0 then return false end
	for _, tc in ipairs(batch) do
		if not READ_ONLY_TOOLS[tc.name] then
			return false
		end
	end
	return true
end

local function batch_is_workspace_inventory(batch)
	if #batch == 0 then return false end
	for _, tc in ipairs(batch) do
		if tc.name ~= "ls" and tc.name ~= "find" and tc.name ~= "grep" then
			return false
		end
	end
	return true
end

local function workspace_is_blank(cwd)
	local scan = uv.fs_scandir(cwd or ".")
	if not scan then return false end
	while true do
		local name = uv.fs_scandir_next(scan)
		if not name then return true end
		if name ~= ".git" and name ~= ".gitkeep" then return false end
	end
end

local function get_provider(credentials_path)
	local provider = providers.load(credentials_path)
	return provider
end

-- Transcript logging
local transcript_file = nil
local structured_file = nil
local trace_sequence, trace_turn = 0, 0

local function checked_log_write(file, text)
	assert(file:write(text))
	assert(file:flush())
end

local function trace(kind, data)
	if not structured_file then return end
	trace_sequence = trace_sequence + 1
	local seconds, micros = uv.gettimeofday()
	checked_log_write(structured_file, json.encode({
		version = 1, sequence = trace_sequence, event = kind,
		timestamp = os.date("!%Y-%m-%dT%H:%M:%S", seconds) .. string.format(".%06dZ", micros),
		monotonic_ms = uv.hrtime() / 1000000, turn_id = trace_turn, data = data,
	}) .. "\n")
end

function core.set_transcript(path)
	local old_text, old_structured = transcript_file, structured_file
	transcript_file, structured_file = nil, nil
	local text_ok, text_err, structured_ok, structured_err = true, nil, true, nil
	if old_text then text_ok, text_err = old_text:close() end
	if old_structured then structured_ok, structured_err = old_structured:close() end
	assert(text_ok, text_err)
	assert(structured_ok, structured_err)
	if path then
		local file = assert(io.open(path, "w"))
		local sidecar, err = io.open(path .. ".jsonl", "w")
		if not sidecar then file:close(); error(err) end
		transcript_file, structured_file = file, sidecar
		trace_sequence, trace_turn = 0, 0
		trace("log_open", { readable_path = path, pid = uv.getpid(), cwd = uv.cwd() })
	end
end

local function log(fmt, ...)
	if not transcript_file then return end
	checked_log_write(transcript_file, string.format(fmt, ...) .. "\n")
end

function core.debug_log(fmt, ...)
	log(fmt, ...)
end

local function log_separator(label)
	log("\n" .. string.rep("=", 70))
	log("  %s", label)
	log(string.rep("=", 70))
end

-- Shared by the tool loop and context summarization so both are replayable.
function core.complete_logged(provider, request, on_token, model_call_id)
	model_call_id = model_call_id or (tostring(trace_turn) .. ":summary:" .. tostring(trace_sequence + 1))
	trace("model_request", { model_call_id = model_call_id, session_id = request.session_id,
		model = request.model, reasoning_effort = request.reasoning_effort, service_tier = request.service_tier,
		tool_scope = request.tool_scope, system_prompt = request.system_prompt, messages = request.messages,
		native_tool_pair_closure = request.native_tool_pair_closure })
	local previous_protocol = request.on_protocol
	if structured_file then
		request.on_protocol = function(kind, data)
			trace(kind, { model_call_id = model_call_id, payload = data })
			if previous_protocol then previous_protocol(kind, data) end
		end
	end
	local response_ok, response = pcall(provider.complete, request, on_token)
	if not response_ok then
		trace("model_error", { model_call_id = model_call_id, error = tostring(response) })
		error(response, 0)
	end
	trace("model_response", { model_call_id = model_call_id, response = response })
	return response
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

local function is_false_tool_protocol_apology(text)
	text = tostring(text or ""):lower()
	return text:find("tool results didn", 1, true) ~= nil
		or text:find("tool execution results weren", 1, true) ~= nil
		or text:find("previous tool-call turn was emitted incorrectly", 1, true) ~= nil
		or text:find("mixed tool calls in a final response", 1, true) ~= nil
		or text:find("malformed `update_plan`", 1, true) ~= nil
		or text:find("malformed update_plan", 1, true) ~= nil
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
		if key ~= "_raw_content" and key ~= "node_id" and key ~= "depends_on" then
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

local function provider_items_for_batch(output_items, batch)
	if type(output_items) ~= "table" then return nil end
	local accepted = {}
	for _, call in ipairs(batch or {}) do
		if call.native_call_id then accepted[call.native_call_id] = true end
	end
	local filtered = {}
	for _, item in ipairs(output_items) do
		if item.type ~= "function_call" or accepted[item.call_id] then
			filtered[#filtered + 1] = item
		end
	end
	return filtered
end

local function recent_read_keys(session)
	local keys = {}
	local modified = {}
	for i = #session.messages, 1, -1 do
		local message = session.messages[i]
		if message and message.tool_name then
			local path = attr(message.text, "path")
			local resolved = path and path_util.resolve(path, session.cwd or ".")
			if resolved and FILE_MUTATION_TOOLS[message.tool_name] then
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

function core.run_session(session, on_token, on_tool, on_thinking, on_wait, control)
	local provider = get_provider(session.credentials_path)
	local events = {}
	local turn_clock_ns = uv.hrtime()
	control = control or {}
	trace_turn = trace_turn + 1
	operational_state.begin_turn(session)
	trace("turn_start", { session_id = session.id, cwd = session.cwd, messages = session.messages })

	log_separator("SESSION START")
	log("Messages in context: %d", #session.messages)

	local total_tool_executions = 0
	local last_batch_tool_executions = 0
	local last_response_meta = nil
	local normal_budget_warned = false
	local normal_recovery_activated = false
	local normal_closure_activated = false
	local false_protocol_apology_retries = 0
	local requested_task = last_user_text(session)
	local completion_audit_used = false
	local completion_audit_active = false
	local had_successful_file_mutation = false
	local blank_workspace = workspace_is_blank(session.cwd)
	local function is_cancelled()
		if type(control.cancelled) == "function" then
			return control.cancelled() == true
		end
		return false
	end
	local tool_call_sequence = 0
	local max_tool_steps = MAX_TOOL_STEPS
	local intra_turn_compactions = 0
	local turn_usage = {
		prompt_tokens = 0,
		cached_tokens = 0,
		cache_write_tokens = 0,
		output_tokens = 0,
		total_tokens = 0,
		model_calls = 0,
		usage_calls = 0,
		cache_available = true,
	}

	local function track_response_usage(response)
		turn_usage.model_calls = turn_usage.model_calls + 1
		local usage = response and response._usage
		if type(usage) ~= "table" then
			turn_usage.cache_available = false
			return
		end
		turn_usage.usage_calls = turn_usage.usage_calls + 1
		turn_usage.prompt_tokens = turn_usage.prompt_tokens + (tonumber(usage.prompt_tokens) or 0)
		turn_usage.cached_tokens = turn_usage.cached_tokens + (tonumber(usage.cached_tokens) or 0)
		turn_usage.cache_write_tokens = turn_usage.cache_write_tokens + (tonumber(usage.cache_write_tokens) or 0)
		turn_usage.output_tokens = turn_usage.output_tokens + (tonumber(usage.output_tokens) or 0)
		turn_usage.total_tokens = turn_usage.total_tokens + (tonumber(usage.total_tokens)
			or ((tonumber(usage.prompt_tokens) or 0) + (tonumber(usage.output_tokens) or 0)))
		if usage.cache_available ~= true then turn_usage.cache_available = false end
	end

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

	local function prepare_model_context(step)
		local tokens = session:estimated_model_input_tokens_usage_aware()
		local threshold = tonumber(session.context_compaction_threshold)
			or context_limits.auto_compact_threshold(session.model)
		local enabled = session.intra_turn_compaction ~= false
		if session.context_compaction_threshold ~= nil or session.context_hard_limit ~= nil then
			log("[context] reserve check step=%d tokens=%d threshold=%d enabled=%s messages=%d",
				step, tokens, threshold, tostring(enabled), #session.messages)
		end
		if enabled and threshold > 0 and tokens >= threshold then
			log("[context] intra-turn compaction requested step=%d tokens=%d threshold=%d messages=%d",
				step, tokens, threshold, #session.messages)
			local ok, compacted, removed, remaining = pcall(function()
				return compaction.compact(session, {
					bypass_threshold = true,
					keep_recent_tokens = session.compaction_keep_recent_tokens,
					preserve_active_turn = true,
				})
			end)
			if not ok then
				log("[context] intra-turn compaction failed: %s", tostring(compacted))
			elseif compacted then
				intra_turn_compactions = intra_turn_compactions + 1
				session.context_compaction_count = (tonumber(session.context_compaction_count) or 0) + 1
				log("[context] intra-turn compaction complete step=%d removed=%d remaining_tokens=%d messages=%d",
					step, tonumber(removed) or 0, tonumber(remaining) or 0, #session.messages)
				if on_thinking then
					on_thinking({
						step = step,
						messages = #session.messages,
						tools = last_batch_tool_executions,
						total_tools = total_tool_executions,
						status = "compacted active turn context",
					})
				end
			else
				log("[context] intra-turn compaction skipped step=%d (no completed history)", step)
			end
			tokens = session:estimated_model_input_tokens_usage_aware()
		end

		local hard_limit = tonumber(session.context_hard_limit)
			or context_limits.max_input_tokens(session.model)
		if hard_limit and hard_limit > 0 and tokens >= hard_limit then
			local text = string.format(
				"Stopped before exceeding the context limit (%d estimated tokens >= %d). Context could not be reduced below the limit without splitting the active turn.",
				tokens,
				hard_limit
			)
			log("[context] hard limit stopped model call step=%d tokens=%d limit=%d", step, tokens, hard_limit)
			return false, text
		end
		return true
	end

	local step = 0
	while step < max_tool_steps do
		step = step + 1
		if control.before_step then control.before_step(session) end
		-- Check for cancellation
		if is_cancelled() then
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
				tools = last_batch_tool_executions,
				total_tools = total_tool_executions,
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
						tools = last_batch_tool_executions,
						total_tools = total_tool_executions,
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
						tools = last_batch_tool_executions,
						total_tools = total_tool_executions,
						status = "coalesced context  " .. tostring(coalesced_count) .. " messages",
					})
				end
			end
			end

			local context_ok, context_error = prepare_model_context(step)
			if not context_ok then
				return {
					text = context_error,
					events = events,
					_response_meta = last_response_meta,
					_context_compactions = intra_turn_compactions,
				}
			end

			log_separator(string.format("LLM CALL #%d", step))
		log("Sending %d messages to model", #session.messages)

		local request = {
			credentials_path = session.credentials_path,
			session_id = session.id,
			model = session.model,
			reasoning_effort = session.reasoning_effort,
			service_tier = session.service_tier,
			tool_scope = session.tool_scope,
			system_prompt = session.get_system_prompt and session:get_system_prompt() or system_prompt.build({ cwd = session.cwd, model = session.model }),
			messages = operational_state.request_messages(session),
			native_tool_calling = true,
			native_tool_pair_closure = session.native_tool_pair_closure ~= false,
			cancelled = is_cancelled,
			on_wait = on_wait,
			on_activity = control.on_model_activity,
		}
		if control.on_request then control.on_request(request) end
		local model_call_id = tostring(trace_turn) .. ":" .. tostring(step)
		local response = core.complete_logged(provider, request, on_token, model_call_id)
		track_response_usage(response)
		if control.on_response then control.on_response(response) end
		last_response_meta = response_meta(response)

		-- Check for cancellation after LLM call
		if is_cancelled() then
			log_separator("CANCELLED BY USER")
			return {
				text = response.text or "",
				events = events,
				_response_meta = last_response_meta,
				_cancelled = true,
				_cancelled_after_response = true,
				_response_bytes = response._response_bytes,
			}
		end

		log("\n--- ASSISTANT RESPONSE ---")
		log("%s", response.text)

		local raw_tool_calls = response._native_tool_calls or {}
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
		if completion_audit_active then
			local retained = {}
			local dropped_inventory = 0
			for _, tc in ipairs(tool_calls) do
				if tc.name == "ls" or tc.name == "find" then
					dropped_inventory = dropped_inventory + 1
				else
					retained[#retained + 1] = tc
				end
			end
			if dropped_inventory > 0 then
				tool_calls = retained
				session:add_user(table.concat({
					"Completion-audit inventory guard: redundant ls/find calls were not executed.",
					"Do not reconfirm filenames or workspace contents already established by mutation results. Use the existing evidence and finish the audit, or run only a specific missing validation.",
				}, "\n"))
				if #tool_calls == 0 then
					if on_thinking then
						on_thinking({
							step = step,
							messages = #session.messages,
							tools = 0,
							total_tools = total_tool_executions,
							status = "completion inventory blocked",
						})
					end
					goto continue_session_loop
				end
			end
		end
		log("[tool-protocol] native_calls=%d valid_calls=%d invalid_names=%s output_items=%d",
			#raw_tool_calls, #tool_calls,
			#invalid_tool_names > 0 and table.concat(invalid_tool_names, ",") or "(none)",
			#(response._output_items or {}))
		-- Native calls are already framed by the provider. XML inside arguments is data.

		if #tool_calls == 0 then
			local text = clean_assistant_text(response.text)
			if total_tool_executions > 0 and false_protocol_apology_retries < 2 and is_false_tool_protocol_apology(text) then
				false_protocol_apology_retries = false_protocol_apology_retries + 1
				log_separator("FALSE TOOL PROTOCOL APOLOGY - CONTINUING")
				log("[tool-protocol] false_apology_retry=%d text=%s", false_protocol_apology_retries, compact_log_text(text, 1200))
				session:add_user(table.concat({
					"Your last response incorrectly claimed the previous tool-call turn was malformed or missing tool results.",
					"The tool results were available and already processed by the harness.",
					"Do not apologize for tool protocol. Continue from the actual tool results and either make the next required tool call or give the final user-facing summary.",
				}, "\n"))
				if on_thinking then
					on_thinking({
						step = step,
						messages = #session.messages,
						tools = last_batch_tool_executions,
						total_tools = total_tool_executions,
						status = "ignored false tool protocol apology",
					})
				end
				goto continue_session_loop
			end
			if session.completion_audit ~= false
				and not completion_audit_used
				and had_successful_file_mutation
				and research_build_request(requested_task)
			then
				completion_audit_used = true
				completion_audit_active = true
				-- The audit needs one bounded round even when implementation consumed the
				-- final ordinary round; it may spend that allowance on one narrow check.
				max_tool_steps = max_tool_steps + 1
				log_separator("RESEARCH BUILD COMPLETION AUDIT")
				session:add_user(table.concat({
					"Harness completion audit: do not return the previous completion summary yet.",
					"Compare the original request, primary-source requirements discovered during research, implementation, and actual tool evidence.",
					"Check that mandatory current platform/API requirements became acceptance criteria and that each completion claim has matching evidence.",
					"Use tools now only for a safe, specific missing check or narrow fix. Otherwise give the final answer, clearly separating what was written, locally executed, statically checked, and externally deployed or invoked.",
					"Do not use ls or find to reconfirm filenames or workspace contents already established by successful mutation results.",
					"Do not describe the result as complete when a required external path was not exercised; lead with what is actually proven and name the exact unverified boundary.",
				}, "\n"))
				if on_thinking then
					on_thinking({
						step = step,
						messages = #session.messages,
						tools = last_batch_tool_executions,
						total_tools = total_tool_executions,
						status = "completion evidence audit",
					})
				end
				goto continue_session_loop
			end
			if session.record_usage then
				session:record_usage(response._usage, #session.messages)
			end
			-- Plans are transient progress UI; the final answer closes them.
			session.plan = nil
			session.journey = nil
			log_separator("NO TOOL CALL - RETURNING TEXT")
			return {
				text = text,
				events = events,
				_usage = response._usage,
				_turn_usage = turn_usage,
				_response_meta = last_response_meta,
				_context_compactions = intra_turn_compactions,
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

		local raw_read_only_batch = batch_is_read_only(tool_calls)
		local guard_blank_inventory = session.blank_workspace_inventory_guard ~= false
			and blank_workspace
			and total_tool_executions == 0
			and #tool_calls > 1
			and batch_is_workspace_inventory(tool_calls)
		local read_only_batch_cap = tonumber(session.read_only_batch_cap)
		if read_only_batch_cap == nil then read_only_batch_cap = MAX_READ_ONLY_BATCH_SIZE end
		read_only_batch_cap = math.max(0, math.floor(read_only_batch_cap))
		local effective_batch_cap = raw_read_only_batch and read_only_batch_cap > 0
			and math.min(MAX_BATCH_SIZE, read_only_batch_cap)
			or MAX_BATCH_SIZE
		if guard_blank_inventory then effective_batch_cap = 1 end

		-- Enforce tool budget and per-batch cap
		local batch = {}
		local dropped_for_batch_cap = 0
		local dropped_for_duplicate = 0
		local dropped_for_dependency = 0
		local dependency_target
		local seen_tool_calls = {}
		for i, tc in ipairs(tool_calls) do
			local key = tool_call_key(tc)
			if key and seen_tool_calls[key] then
				dropped_for_duplicate = dropped_for_duplicate + 1
				log("DUPLICATE TOOL CALL dropped at call %d/%d: %s", i, #tool_calls, tc.name)
				goto continue_tool_call
			end
			if key then
				seen_tool_calls[key] = true
			end
			if #batch >= effective_batch_cap then
				dropped_for_batch_cap = #tool_calls - i + 1
				log("BATCH CAP reached (%d), dropping remaining %d calls", effective_batch_cap, dropped_for_batch_cap)
				break
			end
			if total_tool_executions >= max_tool_steps then
				log("TOOL BUDGET HIT mid-batch at call %d/%d", i, #tool_calls)
				break
			end
			total_tool_executions = total_tool_executions + 1
			tool_call_sequence = tool_call_sequence + 1
			tc.runtime_call_id = tc.native_call_id or ("tool-" .. tostring(tool_call_sequence))
			batch[#batch + 1] = tc
			::continue_tool_call::
		end
		batch, dropped_for_dependency, dependency_target = dependency_safe_prefix(batch, session.cwd)
		if dropped_for_dependency > 0 then
			total_tool_executions = total_tool_executions - dropped_for_dependency
			log("DEPENDENCY PREFIX stopped before read-after-mutation target=%s deferred=%d",
				tostring(dependency_target), dropped_for_dependency)
		end
		if dropped_for_duplicate >= 2 or (dropped_for_duplicate > 0 and dropped_for_duplicate >= math.ceil(#tool_calls / 2)) then
			session:add_user(table.concat({
				"Duplicate tool-call guard: you repeated " .. tostring(dropped_for_duplicate) .. " identical tool call" .. (dropped_for_duplicate == 1 and "" or "s") .. " in the previous response.",
				"Only unique calls were executed.",
				"Continue from the executed tool results. Do not repeat identical tool calls unless a prior result explicitly requires a retry.",
			}, "\n"))
			if on_thinking then
				on_thinking({
					step = step,
					messages = #session.messages,
					tools = #batch,
					total_tools = total_tool_executions,
					status = "duplicate tool calls dropped  " .. tostring(dropped_for_duplicate),
				})
			end
		end
		do
			-- Read-only investigation is legitimate progress. Duplicate-read handling
			-- and the general tool budget bound repetition without requiring edits.

			-- Only store the actually executed tool calls. The model can emit
			-- duplicates or calls past the batch cap; keeping those in history
			-- teaches the next turn the wrong continuation.
			local clean_response = tool_calls_text(batch)

			-- Execute tool calls (parallel for read-only, sequential for mutating)
			session:add_assistant(clean_response, provider_items_for_batch(response._output_items, batch))
			if session.record_usage then
				session:record_usage(response._usage, #session.messages)
			end

			local MUTATING_TOOLS = { edit = true, multi_edit = true, write = true, run = true }

			local tool_started_ns = {}
			local function batch_on_tool(event)
				local observed_ns = uv.hrtime()
				event.phase = event.phase or "finish"
				event.model_call_id = step
				event.batch_id = step
				event.observed_at_ms = math.floor((observed_ns - turn_clock_ns) / 1000000)
				local event_id = tostring(event.call_id or (event.name .. ":" .. tostring(event.model_index or "?")))
				if event.phase == "start" then
					tool_started_ns[event_id] = observed_ns
					log("\n--- TOOL START: %s ---", event.name)
					if event.args then
						for k, v in pairs(event.args) do
							local vs = tostring(v)
							if #vs > 120 then vs = vs:sub(1, 117) .. "..." end
							log("      %s = %s", k, vs)
						end
					end
				elseif event.phase == "progress" then
					local progress = type(event.progress) == "table" and event.progress or {}
					if progress.output_bytes ~= nil then
						log("--- TOOL PROGRESS: %s elapsed_ms=%s output_bytes=%s output_chunks=%s ---",
							event.name, tostring(progress.elapsed_ms), tostring(progress.output_bytes), tostring(progress.output_chunks))
					else
						log("--- TOOL PROGRESS: %s elapsed_ms=%s ---", event.name, tostring(progress.elapsed_ms))
					end
				else
					local started_ns = tool_started_ns[event_id]
					if started_ns then event.duration_ms = math.floor((observed_ns - started_ns) / 1000000) end
					tool_started_ns[event_id] = nil
					if MUTATING_TOOLS[event.name] or event.name:match("^job_") or (event.result and event.result.is_error) then
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
				end
				events[#events + 1] = event
				operational_state.observe(session, event)
				trace("tool_event", { model_call_id = model_call_id, event = event })
				if on_tool then
					on_tool(event)
				end
			end

			trace("tool_batch", { model_call_id = model_call_id, calls = batch })
			local batch_results = parallel.execute_batch(batch, {
				cwd = session.cwd,
				session = session,
				recent_read_keys = recent_read_keys(session),
				cancelled = is_cancelled,
				on_wait = on_wait,
			}, batch_on_tool)
			last_batch_tool_executions = #batch

			local batch_failed = false
			for i, tc in ipairs(batch) do
				local result = batch_results[i]
				if result then
					if result.is_error then batch_failed = true end
					if FILE_MUTATION_TOOLS[tc.name] and not result.is_error then
						had_successful_file_mutation = true
					end
					local msg = protocol.tool_result_message(tc.name, result, tc.args)
					trace("tool_result", { model_call_id = model_call_id, call_id = tc.runtime_call_id,
						model_index = i, name = tc.name, args = tc.args, result = result, model_message = msg })
					session:add_tool_result(tc.name, msg, tc.native_call_id)
				end
			end
			if batch_failed
				and not normal_recovery_activated
				and total_tool_executions >= (MAX_TOOL_STEPS - NORMAL_TOOL_RESERVE)
			then
				normal_recovery_activated = true
				max_tool_steps = MAX_TOOL_STEPS + NORMAL_FAILURE_RECOVERY_STEPS
				session:add_user(table.concat({
					"Recovery tool budget activated after a late tool or verification failure.",
					"Stop broad research and scope expansion. Diagnose the observed failure, apply the smallest coherent fix, rerun the narrow verification, then finish the requested validation or documentation.",
					"You have up to " .. tostring(NORMAL_FAILURE_RECOVERY_STEPS) .. " additional tool calls. Do not claim completion unless the relevant check passes.",
				}, "\n"))
				if on_thinking then
					on_thinking({
						step = step,
						messages = #session.messages,
						tools = last_batch_tool_executions,
						total_tools = total_tool_executions,
						status = "late failure recovery budget",
					})
				end
			end
			if dropped_for_batch_cap > 0 and dropped_for_dependency == 0 then
				local cap_message
				if guard_blank_inventory then
					cap_message = table.concat({
						"Blank-workspace inventory guard: only the first inspection call ran; " .. tostring(dropped_for_batch_cap) .. " redundant inventory calls were deferred.",
						"The workspace has no project files. Do not repeat ls, find, or grep against the root; begin the requested research, plan, or implementation.",
					}, "\n")
				elseif raw_read_only_batch and effective_batch_cap < MAX_BATCH_SIZE then
					cap_message = table.concat({
						"Read-only batch cap reached: only the first " .. tostring(effective_batch_cap) .. " inspection calls ran; " .. tostring(dropped_for_batch_cap) .. " later calls were deferred.",
						"Stop broad workspace inventory. Use the context already gathered and make the next concrete edit/write/run action, or explain the specific blocker.",
					}, "\n")
				else
					cap_message = "Batch cap reached: only the first " .. tostring(effective_batch_cap) .. " tool calls ran; " .. tostring(dropped_for_batch_cap) .. " later calls were deferred. Continue with at most " .. tostring(effective_batch_cap) .. " tool calls in the next batch."
				end
				session:add_user(cap_message)
				if on_thinking then
					on_thinking({
						step = step,
						messages = #session.messages,
						tools = last_batch_tool_executions,
						total_tools = total_tool_executions,
						status = (raw_read_only_batch and effective_batch_cap < MAX_BATCH_SIZE and "read-only batch cap deferred  " or "batch cap deferred  ") .. tostring(dropped_for_batch_cap) .. " tools",
					})
				end
			end
			if dropped_for_dependency > 0 then
				local total_deferred = dropped_for_dependency + dropped_for_batch_cap
				session:add_user(table.concat({
					"Tool dependency boundary reached: only the first " .. tostring(#batch) .. " calls ran; " .. tostring(total_deferred) .. " later calls were deferred.",
					"A later read targeted a file modified earlier in the same response, but mutation results were not yet available while that response was generated.",
					"Continue from the executed results. Re-read the modified file now if needed, then make any remaining changes in a new batch.",
				}, "\n"))
				if on_thinking then
					on_thinking({
						step = step,
						messages = #session.messages,
						tools = last_batch_tool_executions,
						total_tools = total_tool_executions,
						status = "dependency boundary deferred  " .. tostring(dropped_for_dependency) .. " tools",
					})
				end
			end

			-- Check for cancellation after tool execution
			if is_cancelled() then
				log_separator("CANCELLED BY USER")
				return {
					text = "",
					events = events,
					_response_meta = last_response_meta,
				}
			end
		end

		if not normal_budget_warned
			and total_tool_executions >= (MAX_TOOL_STEPS - NORMAL_TOOL_RESERVE)
		then
			normal_budget_warned = true
			session:add_user(table.concat({
				"Normal-mode tool budget reserve reached.",
				"Do not begin broad research, inventory, or scope expansion. Use the remaining base budget for the shortest complete closure path: implement the essential slice, run the narrowest relevant check, fix observed failures, rerun that check, and finish required documentation.",
				"A late tool or verification failure can activate a bounded recovery allowance, but unused base budget is not evidence that the task is complete.",
			}, "\n"))
			if on_thinking then
				on_thinking({
					step = step,
					messages = #session.messages,
					tools = last_batch_tool_executions,
					total_tools = total_tool_executions,
					status = "normal tool reserve",
				})
			end
		end

		if total_tool_executions >= max_tool_steps then
			if not normal_closure_activated
				and not normal_recovery_activated
			then
				normal_closure_activated = true
				max_tool_steps = MAX_TOOL_STEPS + NORMAL_FAILURE_RECOVERY_STEPS
				session:add_user(table.concat({
					"Base tool budget reached with an implementation still in progress.",
					"A bounded closure allowance is now active. Use it only to finish already-started essential files, generate required build artifacts or lockfiles, run the narrowest relevant validation, fix observed failures, and rerun that validation.",
					"Do not start new research, optional features, examples, or documentation expansion. Do not hand verification commands back to the user when they can be run here.",
					"You have up to " .. tostring(NORMAL_FAILURE_RECOVERY_STEPS) .. " additional tool calls. Completion requires validation evidence, not merely written files.",
				}, "\n"))
				if on_thinking then
					on_thinking({
						step = step,
						messages = #session.messages,
						tools = last_batch_tool_executions,
						total_tools = total_tool_executions,
						status = "implementation closure allowance",
					})
				end
			else
				break
			end
		end
		::continue_session_loop::
	end

	log_separator("TOOL BUDGET EXHAUSTED")
	if normal_recovery_activated then
		session:add_user(table.concat({
			"Recovery tool budget exhausted.",
			"Stop using tools now and report the exact failing or incomplete verification without implying completion.",
		}, "\n"))
	elseif normal_closure_activated then
		session:add_user(table.concat({
			"Implementation closure allowance exhausted.",
			"Stop using tools now and report the exact incomplete artifact or validation without implying completion.",
		}, "\n"))
	else
		session:add_user("Tool budget reached. Stop using tools now and answer from the information already gathered.")
	end
	if control.before_step then control.before_step(session) end
	local final_context_ok, final_context_error = prepare_model_context(max_tool_steps + 1)
	if not final_context_ok then
		return {
			text = final_context_error,
			events = events,
			_response_meta = last_response_meta,
			_context_compactions = intra_turn_compactions,
		}
	end
	local request = {
		credentials_path = session.credentials_path,
		session_id = session.id,
		model = session.model,
		reasoning_effort = session.reasoning_effort,
		service_tier = session.service_tier,
		tool_scope = session.tool_scope,
		native_tool_calling = true,
		system_prompt = session.get_system_prompt and session:get_system_prompt() or system_prompt.build({ cwd = session.cwd, model = session.model }),
		messages = operational_state.request_messages(session),
		cancelled = is_cancelled,
		on_wait = on_wait,
		on_activity = control.on_model_activity,
	}
	if control.on_request then control.on_request(request) end
	local response = provider.complete(request, on_token)
	track_response_usage(response)
	if control.on_response then control.on_response(response) end
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
		_output_items = response._output_items,
		_usage = response._usage,
		_turn_usage = turn_usage,
		_response_meta = last_response_meta,
		_context_compactions = intra_turn_compactions,
	}
end

core._dependency_safe_prefix = dependency_safe_prefix

return core
