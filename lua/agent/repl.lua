local commands = require("agent.commands")
local compaction = require("agent.compaction")
local context_limits = require("agent.context_limits")
local core = require("agent.core")
local jobs = require("agent.jobs")
local protocol = require("agent.tool_protocol")
local session_module = require("agent.session")
local ui = require("agent.ui")
local socket = require("socket")
local uv = require("luv")
local ln_ok, ln = pcall(require, "linenoise-luv")
if not ln_ok then ln = nil end

local logo_ok, logo = pcall(require, "logo")
if not logo_ok then logo = nil end

local repl = {}
local history_path = ".lca-history"
local AUTO_COMPACT_MIN_NEW_MESSAGES = tonumber(os.getenv("LCA_AUTO_COMPACT_MIN_NEW_MESSAGES") or "") or 10

-- Cancellation state: set by SIGINT handler, checked by core loop
repl.cancelled = false
-- Track whether we're in an active operation (LLM call / tool execution)
repl.busy = false

local editing = false

function repl.cleanup_terminal()
	if ln and editing then
		pcall(function() ln.editsetchanged(nil) end)
		pcall(function() ln.editstop() end)
		editing = false
	end
	pcall(function() io.write("\27[0m\27[?25h") end)
	pcall(function() io.flush() end)
	os.execute("stty sane 2>/dev/null")
end

if ln then
	pcall(function() ln.historyload(history_path) end)
	pcall(function() ln.historysetmaxlen(1000) end)
end
local function trim(value)
	return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- ─── Logo Animation ────────────────────────────────────────────────────────

local logo_active = false
local logo_lines_up = 0

local function start_logo_animation()
	if not logo then return end
	logo.oc = 3
	logo.hpos = 0
	logo.hdir = 1
	logo_lines_up = ui.header_lines - 1
	logo_active = true
end

local function stop_logo_animation()
	if not logo_active then return end
	logo_active = false
end

-- ─── Readline ──────────────────────────────────────────────────────────────

local function read_prompt(session)
	ui.clear_thinking()

	if not ln then
		io.write(ui.plain_prompt(session))
		io.flush()
		local line = io.read("*l")
		return line and trim(line) or nil
	end

	ln.editstart(ui.plain_prompt(session))
	editing = true

	local result_line = nil
	local done = false

	local anim_timer = nil
	local function start_anim()
		if not logo_active or anim_timer then return end
		anim_timer = uv.new_timer()
		anim_timer:start(55, 55, function()
			logo.render(logo_lines_up)
		end)
	end
	local function pause_anim()
		if not anim_timer then return end
		anim_timer:stop()
		if not anim_timer:is_closing() then anim_timer:close() end
		anim_timer = nil
	end

	-- Resume/pause animation based on buffer content
	if logo_active then
		ln.editsetchanged(function(_, len)
			if len == 0 then
				start_anim()
			else
				pause_anim()
			end
		end)
		start_anim()
	end

	-- Use stdin poll so editfeed() is only called when data is available
	local stdin_poll = uv.new_poll(0)
	stdin_poll:start("r", function()
		local line, more = ln.editfeed()
		if more then return end
		-- Line submitted or EOF
		pause_anim()
		ln.editsetchanged(nil)
		stdin_poll:stop()
		if not stdin_poll:is_closing() then stdin_poll:close() end
		if line then
			line = trim(line)
			if line ~= "" then
				ln.historyadd(line)
				pcall(function() ln.historysave(history_path) end)
			end
			result_line = line
		end
		done = true
	end)

	while not done do
		uv.run("once")
	end

	-- Restore terminal to cooked mode so normal output works
	repl.cleanup_terminal()
	if result_line ~= nil then
		io.write("\r\n")
	end
	io.flush()

	return result_line
end


function repl.run(options)
	local session = session_module.create(options)
	ui.header(session, { animated_logo = (logo ~= nil) })
	start_logo_animation()
	local last_auto_compact_messages

	local function auto_load()
		local ok, err = session:load()
		if ok then
			ui.muted(session:load_message())
		elseif err and not err:match("No such file") and not err:match("no such file") then
			ui.error(err)
		end
	end

	auto_load()
	last_auto_compact_messages = #session.messages
	if context_limits.auto_compact_threshold(session.model) > 0 and session:estimated_model_input_tokens_usage_aware() >= context_limits.auto_compact_threshold(session.model) then
		last_auto_compact_messages = math.max(0, #session.messages - AUTO_COMPACT_MIN_NEW_MESSAGES)
	end

	jobs.prune(session.cwd)

	local function running_jobs_summary(verb)
		local running = jobs.running(session.cwd)
		if #running == 0 then return end
		if ui.background_jobs_summary then
			ui.background_jobs_summary(running, verb)
		else
			local noun = #running == 1 and "background job" or "background jobs"
			local parts = { tostring(#running) .. " " .. noun .. " " .. verb }
			for _, job in ipairs(running) do
				local display = jobs.display(job)
				local port = display.port ~= "" and (" " .. display.port) or ""
				parts[#parts + 1] = "  " .. display.id .. port .. " " .. display.label
			end
			ui.muted(table.concat(parts, "\n"))
		end
	end

	running_jobs_summary("running")

	local function auto_save()
		if #session.messages > 0 then
			local ok, err = session:save()
			if ok then
				ui.muted("session auto-saved to " .. session.DEFAULT_SESSION_FILE)
			else
				ui.error("auto-save failed: " .. (err or "unknown"))
			end
		end
	end

	local function exit_jobs_summary()
		running_jobs_summary("still running")
	end

	local function maybe_auto_compact()
		local auto_compact_tokens = context_limits.auto_compact_threshold(session.model)
		if auto_compact_tokens <= 0 then return end
		if #session.messages == 0 then return end
		local new_messages = #session.messages - last_auto_compact_messages
		if new_messages < AUTO_COMPACT_MIN_NEW_MESSAGES then return end
		local tokens = session:estimated_model_input_tokens_usage_aware()
		if tokens < auto_compact_tokens then return end

		ui.model_progress("compacting session  ~" .. tostring(math.floor(tokens / 1000)) .. "k / ~" .. tostring(math.floor(auto_compact_tokens / 1000)) .. "k tokens")
		local ok, compacted, msgs_removed, new_tokens = pcall(function()
			return compaction.compact(session, { bypass_threshold = true })
		end)
		if not ok then
			ui.error("auto-compact failed: " .. tostring(compacted))
			last_auto_compact_messages = #session.messages
		elseif compacted then
			ui.compaction(msgs_removed, new_tokens)
			last_auto_compact_messages = #session.messages
		else
			ui.muted("auto-compact skipped")
			last_auto_compact_messages = #session.messages
		end
	end

	local signal_handles = {}
	local posix_signal_ok, posix_signal = pcall(require, "posix.signal")
	local function close_signal_handles()
		for _, handle in ipairs(signal_handles) do
			if not handle:is_closing() then
				handle:stop()
				handle:close()
			end
		end
		signal_handles = {}
	end

	local function graceful_exit(code, quiet)
		stop_logo_animation()
		repl.cleanup_terminal()
		if quiet then
			pcall(auto_save)
			pcall(exit_jobs_summary)
		else
			io.write("\n")
			auto_save()
			exit_jobs_summary()
		end
		close_signal_handles()
		os.exit(code or 0)
	end

	local function install_signal(name, callback)
		local handle = uv.new_signal()
		local ok = pcall(function()
			handle:start(name, callback)
		end)
		if ok then
			signal_handles[#signal_handles + 1] = handle
		else
			if not handle:is_closing() then handle:close() end
		end
	end

	local function handle_sigint()
		if repl.busy then
			if repl.cancelled then
				repl.cleanup_terminal()
				os.exit(130)
			end
			-- Cancel the current operation, return to prompt. If the provider or
			-- active tool cannot observe cancellation promptly, a second Ctrl-C exits.
			repl.cancelled = true
			pcall(function()
				io.write("\n")
				ui.muted("  ⏎ cancelling; press Ctrl-C again to exit")
				io.flush()
			end)
		else
			-- Not busy — exit the REPL
			graceful_exit(0)
		end
	end

	-- Install Ctrl-C and termination handlers. These are best-effort: hard kills
	-- and some suspended SSH failures cannot run process cleanup.
	if posix_signal_ok and posix_signal and posix_signal.signal then
		posix_signal.signal(posix_signal.SIGINT, handle_sigint)
	else
		install_signal("sigint", handle_sigint)
	end
	install_signal("sighup", function()
		graceful_exit(0, true)
	end)
	install_signal("sigterm", function()
		graceful_exit(0, true)
	end)
	while true do
		-- Reset cancellation flag at the top of each prompt cycle
		repl.cancelled = false
		local line = read_prompt(session)
		if line == nil then
			stop_logo_animation()
			repl.cleanup_terminal()
			io.write("\n")
			auto_save()
			exit_jobs_summary()
			close_signal_handles()
			return
		end

		if line ~= "" then
			stop_logo_animation()
			if line:sub(1, 1) == "/" then
				local command_result = commands.dispatch(line, session, ui)
				if command_result == true then
					repl.cleanup_terminal()
					auto_save()
					exit_jobs_summary()
					close_signal_handles()
					return
				elseif command_result == "run" then
					line = ""
				else
					line = nil
				end
			end

			if line ~= nil then
				session:add_user(line)
			end

			if line ~= nil and (line ~= "" or session.messages[#session.messages]) then
				ui.turn_separator(session)
				ui.thinking(#session.messages, "thinking")

				local token_count = 0
				local first_token = true
				local start_time = socket.gettime()
				local first_token_time = nil
				local in_tool_call = false
				local in_thinking = false
				local has_seen_tool_call = false
				local turn_has_seen_tool_call = false
				local stream_buf = ""
				local stream_seen = ""
				local spinner_active = true
				local tool_header_shown = false
				local hidden_tool_bytes = 0
				local hidden_tool_last_report = 0
				local hidden_tool_name = nil
				local hidden_tool_start_pos = nil
				local hidden_tool_target = nil
				local hidden_tool_last_label = nil
				local hidden_tool_displayed = false
				local planned_tool_names = {}
				local planned_tool_seen = {}
				local planned_tool_scan_pos = 1
				local live_model_progress = false
				local live_model_progress_text = nil
				local live_model_progress_timer = nil
				local live_model_progress_last_token_at = 0
				local LIVE_PROGRESS_STALE_AFTER = 0.6

				local function live_model_progress_color()
					if live_model_progress_last_token_at > 0 and socket.gettime() - live_model_progress_last_token_at <= LIVE_PROGRESS_STALE_AFTER then
						return "green"
					end
					return "orange"
				end

				local function label_with_current_plan(base)
					local wolf = session.flow == "insanitywolf" and "🐺 " or ""
					local current_plan, current_index
					if ui.plan_current then
						current_plan, current_index = ui.plan_current(session.plan)
					end
					if not current_plan then
						return wolf .. tostring(base or "")
					end
					current_plan = tostring(current_plan):gsub("%s+", " ")
					if #current_plan > 48 then
						current_plan = current_plan:sub(1, 45) .. "..."
					end
					local prefix = ""
					if current_index then
						prefix = ((ui.plan_ref and ui.plan_ref(current_index)) or ("#" .. tostring(current_index))) .. " "
					end
					return {
						highlight = wolf .. prefix .. current_plan,
						after = " · " .. tostring(base or ""),
					}
				end

				local function stop_live_model_progress_timer()
					if not live_model_progress_timer then return end
					if not live_model_progress_timer:is_closing() then
						live_model_progress_timer:stop()
						live_model_progress_timer:close()
					end
					live_model_progress_timer = nil
				end

				local function ensure_live_model_progress_timer()
					if live_model_progress_timer then return end
					live_model_progress_timer = uv.new_timer()
					live_model_progress_timer:start(120, 120, function()
						if not live_model_progress or not live_model_progress_text then
							stop_live_model_progress_timer()
							return
						end
						ui.model_progress_live(label_with_current_plan(live_model_progress_text), live_model_progress_color())
					end)
				end

				local function show_model_progress_live(text)
					live_model_progress_text = text
					ui.model_progress_live(label_with_current_plan(text), live_model_progress_color())
					live_model_progress = true
					ensure_live_model_progress_timer()
				end

				local function clear_live_model_progress()
					if not live_model_progress then return end
					stop_live_model_progress_timer()
					ui.clear_model_progress()
					live_model_progress = false
					live_model_progress_text = nil
					live_model_progress_last_token_at = 0
				end

				local function write_visible(text)
					if not text or text == "" then return end
					clear_live_model_progress()
					io.write(text)
					io.flush()
				end

				local function planned_tool_label()
					local limit = math.min(#planned_tool_names, 5)
					local visible = {}
					for i = 1, limit do
						visible[#visible + 1] = planned_tool_names[i]
					end
					local text = table.concat(visible, ", ")
					if #planned_tool_names > limit then
						text = text .. ", +" .. tostring(#planned_tool_names - limit)
					end
					if #planned_tool_names == 1 then
						return "planning tool: " .. text
					end
					return "planning tools: " .. text
				end

				local function scan_planned_tools()
					local changed = false
					while true do
						local start_at, end_at, name = stream_seen:find('<tool_call%s+name%s*=%s*"([^"]+)"', planned_tool_scan_pos)
						if not start_at then break end
						planned_tool_scan_pos = end_at + 1
						if name and name ~= "" and not planned_tool_seen[name] then
							planned_tool_seen[name] = true
							planned_tool_names[#planned_tool_names + 1] = name
							changed = true
						end
					end
					if changed then
						show_model_progress_live(planned_tool_label())
					end
				end

				local function inside_fenced_code(pos)
					local in_fence = false
					local line_start = 1
					while line_start < pos do
						local line_end = stream_seen:find("\n", line_start, true) or (#stream_seen + 1)
						if stream_seen:sub(line_start, line_start + 2) == "```" then
							in_fence = not in_fence
						end
						line_start = line_end + 1
					end
					return in_fence
				end

				local function find_unfenced(pattern)
					local search_from = 1
					local buffer_start = #stream_seen - #stream_buf + 1
					while true do
						local found = stream_buf:find(pattern, search_from)
						if not found then
							return nil
						end
						if not inside_fenced_code(buffer_start + found - 1) then
							return found
						end
						search_from = found + 1
					end
				end

				local function compact_bytes(bytes)
					if bytes < 1024 then
						return tostring(bytes) .. "B"
					end
					return string.format("%.1fkB", bytes / 1024)
				end

				local function expects_large_tool_args(name)
					return name == "edit" or name == "write" or name == "run" or name == "shell"
				end

				local function unescape_json_fragment(value)
					value = tostring(value or "")
					value = value:gsub('\\"', '"'):gsub("\\\\", "\\")
					return value
				end

				local function basename(value)
					value = tostring(value or "")
					return value:match("([^/]+)$") or value
				end

				local function hidden_tool_text()
					if not hidden_tool_start_pos then
						return stream_buf
					end
					return stream_seen:sub(hidden_tool_start_pos)
				end

				local function detect_hidden_tool_target()
					if hidden_tool_target then
						return hidden_tool_target
					end
					local text = hidden_tool_text()
					local path_value = text:match('"path"%s*:%s*"([^"]+)"')
					if path_value and path_value ~= "" then
						hidden_tool_target = basename(unescape_json_fragment(path_value))
						return hidden_tool_target
					end
					local command_value = text:match('"command"%s*:%s*"([^"]+)"')
					if command_value and command_value ~= "" then
						command_value = unescape_json_fragment(command_value):gsub("%s+", " "):gsub("^%s+", "")
						if #command_value > 36 then
							command_value = command_value:sub(1, 33) .. "..."
						end
						hidden_tool_target = command_value
						return hidden_tool_target
					end
					return nil
				end

				local function hidden_tool_label()
					local name = hidden_tool_name or "tool"
					local target = detect_hidden_tool_target()
					if target and target ~= "" then
						return name .. " " .. target
					end
					return name
				end

				local function finish_hidden_tool_progress()
					if expects_large_tool_args(hidden_tool_name) and hidden_tool_bytes >= 4096 then
						clear_live_model_progress()
						ui.model_progress("received " .. hidden_tool_label() .. "  " .. compact_bytes(hidden_tool_bytes))
					end
					hidden_tool_name = nil
					hidden_tool_start_pos = nil
					hidden_tool_target = nil
					hidden_tool_last_label = nil
					hidden_tool_displayed = false
					hidden_tool_bytes = 0
					hidden_tool_last_report = 0
				end

				local function note_hidden_tool_progress(delta)
					if not delta or delta == "" then return end
					scan_planned_tools()
					if not hidden_tool_name then
						hidden_tool_name = hidden_tool_text():match('<tool_call%s+name%s*=%s*"([^"]+)"')
					end
					if not expects_large_tool_args(hidden_tool_name) then
						return
					end
					hidden_tool_bytes = hidden_tool_bytes + #delta
					local label = hidden_tool_label()
					local should_report = not hidden_tool_displayed
						or label ~= hidden_tool_last_label
						or hidden_tool_bytes - hidden_tool_last_report >= 512
					if should_report then
						show_model_progress_live("receiving " .. label .. "... " .. compact_bytes(hidden_tool_bytes) .. " streamed")
						hidden_tool_last_report = hidden_tool_bytes
						hidden_tool_last_label = label
						hidden_tool_displayed = true
					end
				end

				local function on_token(text)
					if spinner_active then
						ui.clear_thinking()
						spinner_active = false
						first_token_time = socket.gettime()
					end
					if first_token then
						first_token = false
					end
					token_count = token_count + 1
					live_model_progress_last_token_at = socket.gettime()

					if ui.is_debug() then
						io.write(text)
						io.flush()
						return
					end

					-- Filter out <tool_call name="...">, <thinking>, and post-tool-call text.
					stream_buf = stream_buf .. text
					stream_seen = stream_seen .. text
					scan_planned_tools()
					if in_tool_call then
						note_hidden_tool_progress(text)
					end

					-- Accumulate at least 20 chars before processing to avoid
					-- splitting tags across flushes. The longest prefix we need
					-- to detect is '<tool_call name="' (17 chars).
					if #stream_buf < 20 and not stream_buf:find("[\n>]") then
						-- Small buffer with no definitive boundaries — wait for more
						return
					end

					while #stream_buf > 0 do
						if in_tool_call then
							local close = stream_buf:find("</tool_call>")
							if close then
								stream_buf = stream_buf:sub(close + 12)
								in_tool_call = false
								finish_hidden_tool_progress()
							else
								if #stream_buf > 12 then
									stream_buf = stream_buf:sub(-12)
								end
								break
							end
						elseif in_thinking then
							local close = stream_buf:find("</thinking>")
							if close then
								stream_buf = stream_buf:sub(close + 11)
								in_thinking = false
							else
								if #stream_buf > 11 then
									stream_buf = stream_buf:sub(-11)
								end
								break
							end
						elseif has_seen_tool_call or turn_has_seen_tool_call then
							stream_buf = ""
							break
						else
							-- Match full tag syntax only
							local tool_open = find_unfenced('<tool_call%s+name%s*=%s*"')
							local think_open = find_unfenced("<thinking>") or find_unfenced("<thinking ")

							local first_pos = #stream_buf + 1
							local first_tag = nil
							if think_open and think_open < first_pos then
								first_tag = "thinking"
								first_pos = think_open
							end
							if tool_open and tool_open < first_pos then
								first_tag = "tool_call"
								first_pos = tool_open
							end

							if first_tag == "tool_call" then
								if first_pos > 1 then
									write_visible(stream_buf:sub(1, first_pos - 1))
								end
								has_seen_tool_call = true
								turn_has_seen_tool_call = true
								stream_buf = stream_buf:sub(first_pos)
								in_tool_call = true
								local buffer_start = #stream_seen - #stream_buf + 1
								hidden_tool_start_pos = buffer_start
								hidden_tool_name = stream_buf:match('<tool_call%s+name%s*=%s*"([^"]+)"')
								hidden_tool_bytes = 0
								hidden_tool_last_report = 0
								hidden_tool_target = nil
								note_hidden_tool_progress(stream_buf)
							elseif first_tag == "thinking" then
								if first_pos > 1 then
									write_visible(stream_buf:sub(1, first_pos - 1))
								end
								stream_buf = stream_buf:sub(first_pos)
								in_thinking = true
							else
								-- Hold back a trailing partial that could become a tag.
								-- Look for the last '<' that could be start of our tags.
								local last_lt = nil
								local search_from = 1
								while true do
									local pos = stream_buf:find("<", search_from)
									if not pos then break end
									last_lt = pos
									search_from = pos + 1
								end

								if last_lt then
									local tail = stream_buf:sub(last_lt)
									local is_prefix = false
									local base = "<tool_call "
									local think = "<thinking>"
									if #tail <= #think and think:sub(1, #tail) == tail then
										is_prefix = true
									elseif #tail <= #base and base:sub(1, #tail) == tail then
										is_prefix = true
									elseif tail:match("^<tool_call%s") and #tail <= 22 then
										is_prefix = true
									end
									if is_prefix then
										write_visible(stream_buf:sub(1, last_lt - 1))
										stream_buf = tail
										break
									end
								end

								-- No partial tag — flush everything
								write_visible(stream_buf)
								stream_buf = ""
							end
						end
					end
				end

				local function on_tool(event)
					if spinner_active then
						ui.clear_thinking()
						spinner_active = false
					end
					clear_live_model_progress()
					ui.clear_model_progress()
					if not tool_header_shown then
						ui.tool_header()
						tool_header_shown = true
					end
					ui.tool(event)
				end

				local function on_thinking(info)
					if tool_header_shown then
						ui.tool_summary()
						tool_header_shown = false
					end
					if info and info.status then
						ui.clear_model_progress()
						ui.model_progress(info.status)
					end
					if info and info.checkpoint_summary and ui.checkpoint then
						ui.checkpoint(info.checkpoint_summary, {
							cycle = info.checkpoint_cycle,
							tokens = info.checkpoint_tokens,
						})
					end
					local tool_count_text = "tool results"
					if info and info.tools and info.tools >= 4 then
						tool_count_text = tostring(info.tools) .. " tool results"
					end
					ui.thinking(#session.messages, label_with_current_plan("reviewing " .. tool_count_text))
					spinner_active = true
					in_tool_call = false
					in_thinking = false
					has_seen_tool_call = false
					stream_buf = ""
					hidden_tool_bytes = 0
					hidden_tool_last_report = 0
					hidden_tool_name = nil
					hidden_tool_start_pos = nil
					hidden_tool_target = nil
					hidden_tool_last_label = nil
					hidden_tool_displayed = false
					planned_tool_names = {}
					planned_tool_seen = {}
					planned_tool_scan_pos = 1
					live_model_progress = false
					live_model_progress_text = nil
					stop_live_model_progress_timer()
				end

				repl.busy = true
				repl.cancelled = false
				local ok, result = pcall(function()
					return core.run_session(session, on_token, on_tool, on_thinking)
				end)
				repl.busy = false
				stop_live_model_progress_timer()

				-- Flush any held-back partial content from the stream filter
				if #stream_buf > 0 and not has_seen_tool_call and not turn_has_seen_tool_call and not in_tool_call and not in_thinking then
					write_visible(stream_buf)
				end
				stream_buf = ""

				if repl.cancelled then
					-- Operation was cancelled by Ctrl-C
					repl.cancelled = false
					if spinner_active then
						ui.clear_thinking()
					end
					io.write("\n")
					ui.muted("  ⏎ cancelled")
					io.write("\n")
					-- Remove the user message we just added since we didn't get a response
					if session.messages[#session.messages] and session.messages[#session.messages].role == "user" then
						table.remove(session.messages)
					end
				elseif ok then
					local elapsed = socket.gettime() - start_time
					if spinner_active then
						ui.clear_thinking()
						spinner_active = false
					end
					if not first_token and turn_has_seen_tool_call and result.text ~= "" then
						local visible_text = protocol.strip_tool_results(protocol.strip_tool_calls(result.text))
						if visible_text ~= "" then
							clear_live_model_progress()
							io.write(visible_text)
							io.write(visible_text:sub(-1) == "\n" and "" or "\n")
						end
					elseif not first_token and result.text:sub(-1) ~= "\n" then
						clear_live_model_progress()
						io.write("\n")
					end
					if tool_header_shown then
						ui.tool_summary()
					end
					if not first_token then
						local ttft = first_token_time and (first_token_time - start_time) or elapsed
						ui.stream_stats(token_count, elapsed, ttft, result._response_meta)
					end
					session:add_assistant(result.text)

					maybe_auto_compact()

					io.write("\n")
				else
					if not first_token then
						io.write("\n")
					else
						ui.clear_thinking()
						io.write("\n")
					end
					-- Don't show error if it was a cancellation
					if not tostring(result):find("cancelled") then
						ui.error(tostring(result))
					else
						ui.muted("  ⏎ cancelled")
						io.write("\n")
					end
				end
			end
		end
	end
end

return repl
