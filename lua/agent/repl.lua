local commands = require("agent.commands")
local compaction = require("agent.compaction")
local core = require("agent.core")
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

-- Cancellation state: set by SIGINT handler, checked by core loop
repl.cancelled = false
-- Track whether we're in an active operation (LLM call / tool execution)
repl.busy = false

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

local function read_prompt()
	ui.clear_thinking()

	if not ln then
		io.write(ui.plain_prompt())
		io.flush()
		local line = io.read("*l")
		return line and trim(line) or nil
	end

	ln.editstart(ui.plain_prompt())

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
		ln.editsetchanged(function(buf, len)
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
	pcall(function() ln.editstop() end)
	os.execute("stty sane 2>/dev/null")
	io.flush()

	return result_line
end


function repl.run(options)
	local session = session_module.create(options)
	ui.header(session, { animated_logo = (logo ~= nil) })
	start_logo_animation()

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

	-- Install SIGINT (Ctrl-C) handler
	local sigint = uv.new_signal()
	sigint:start("sigint", function()
		if repl.busy then
			-- Cancel the current operation, return to prompt
			repl.cancelled = true
		else
			-- Not busy — exit the REPL
			stop_logo_animation()
			pcall(function() ln.editstop() end)
			io.write("\n")
			auto_save()
			sigint:stop()
			sigint:close()
			os.exit(0)
		end
	end)
	while true do
		-- Reset cancellation flag at the top of each prompt cycle
		repl.cancelled = false
		local line = read_prompt()
		if line == nil then
			stop_logo_animation()
			io.write("\n")
			auto_save()
			return
		end

		if line ~= "" then
			stop_logo_animation()
			if line:sub(1, 1) == "/" then
				local command_result = commands.dispatch(line, session, ui)
				if command_result == true then
					auto_save()
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
				ui.turn_separator()
				ui.thinking(#session.messages)

				local token_count = 0
				local first_token = true
				local start_time = socket.gettime()
				local first_token_time = nil
				local in_tool_call = false
				local in_thinking = false
				local has_seen_tool_call = false
				local stream_buf = ""
				local spinner_active = true
				local tool_header_shown = false

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

					if ui.is_debug() then
						io.write(text)
						io.flush()
						return
					end

					-- Filter out <tool_call name="...">, <thinking>, and post-tool-call text.
					stream_buf = stream_buf .. text

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
						elseif has_seen_tool_call then
							stream_buf = ""
							break
						else
							-- Match full tag syntax only
							local tool_open = stream_buf:find('<tool_call%s+name%s*=%s*"')
							local think_open = stream_buf:find("<thinking>") or stream_buf:find("<thinking ")

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
									io.write(stream_buf:sub(1, first_pos - 1))
									io.flush()
								end
								has_seen_tool_call = true
								stream_buf = stream_buf:sub(first_pos)
								in_tool_call = true
							elseif first_tag == "thinking" then
								if first_pos > 1 then
									io.write(stream_buf:sub(1, first_pos - 1))
									io.flush()
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
										io.write(stream_buf:sub(1, last_lt - 1))
										io.flush()
										stream_buf = tail
										break
									end
								end

								-- No partial tag — flush everything
								io.write(stream_buf)
								io.flush()
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
					if not tool_header_shown then
						ui.tool_header()
						tool_header_shown = true
					end
					ui.tool(event)
				end

				local function on_thinking()
					if tool_header_shown then
						ui.tool_summary()
						tool_header_shown = false
					end
					ui.thinking(#session.messages)
					spinner_active = true
					in_tool_call = false
					in_thinking = false
					has_seen_tool_call = false
					stream_buf = ""
				end

				repl.busy = true
				repl.cancelled = false
				local ok, result = pcall(function()
					return core.run_session(session, on_token, on_tool, on_thinking)
				end)
				repl.busy = false

				-- Flush any held-back partial content from the stream filter
				if #stream_buf > 0 and not has_seen_tool_call and not in_tool_call and not in_thinking then
					io.write(stream_buf)
					io.flush()
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
					if not first_token and result.text:sub(-1) ~= "\n" then
						io.write("\n")
					end
					if tool_header_shown then
						ui.tool_summary()
					end
					if not first_token then
						local ttft = first_token_time and (first_token_time - start_time) or elapsed
						ui.stream_stats(token_count, elapsed, ttft)
					end
					session:add_assistant(result.text)

					-- Check if compaction is needed
					local compacted, msgs_removed, new_tokens = compaction.compact(session)
					if compacted then
						ui.compaction(msgs_removed, new_tokens)
					end

					io.write("\n")
				else
					if not first_token then
						io.write("\n")
					else
						ui.clear_thinking()
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
