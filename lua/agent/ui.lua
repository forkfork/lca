local ui = {}

local DEBUG = os.getenv("LCA_DEBUG") == "1"

local colors = {
	reset = "\27[0m",
	bold = "\27[1m",
	dim = "\27[2m",
	italic = "\27[3m",
	green = "\27[32m",
	orange = "\27[38;5;208m",
	red = "\27[31m",
	cyan = "\27[36m",
	yellow = "\27[33m",
	magenta = "\27[35m",
	blue = "\27[34m",
	white = "\27[37m",
}

local function supports_color()
	return os.getenv("NO_COLOR") == nil and os.getenv("TERM") ~= "dumb"
end

function ui.is_debug()
	return DEBUG
end

local function color(name, text)
	if not supports_color() then
		return text
	end
	return colors[name] .. text .. colors.reset
end

local function styled(names, text)
	if not supports_color() then
		return text
	end
	local seq = {}
	for _, name in ipairs(names) do
		seq[#seq + 1] = colors[name] or ""
	end
	return table.concat(seq) .. text .. colors.reset
end

-- ─── Terminal Geometry ───────────────────────────────────────────────────────

local term_width = 80

local function refresh_term_size()
	local cols = tonumber(os.getenv("COLUMNS"))
	if cols then
		term_width = cols
		return
	end
	local h = io.popen("tput cols 2>/dev/null")
	if h then
		cols = tonumber(h:read("*a"))
		h:close()
		if cols then term_width = cols end
	end
end

refresh_term_size()

function ui.get_width()
	return term_width
end

-- ─── Box Drawing ────────────────────────────────────────────────────────────

local box = {
	tl = "╭", tr = "╮", bl = "╰", br = "╯",
	h = "─", v = "│",
}

local function hrule(width, label)
	if not label or label == "" then
		return box.h:rep(width)
	end
	local inner = " " .. label .. " "
	local inner_len = #label + 2
	local left = 3
	local right = width - left - inner_len
	if right < 2 then right = 2 end
	return box.h:rep(left) .. inner .. box.h:rep(right)
end

-- ─── Tool Colors ────────────────────────────────────────────────────────────

local TOOL_COLORS = {
	read   = "green",
	ls     = "green",
	find   = "green",
	grep   = "cyan",
	edit   = "yellow",
	write  = "yellow",
	run    = "cyan",
	shell  = "cyan",
	job_start = "blue",
	job_status = "blue",
	job_output = "blue",
	job_stop = "blue",
	job_wait = "blue",
	update_plan = "magenta",
}

local TOOL_VERBS = {
	read   = "reading",
	ls     = "listing",
	find   = "searching",
	grep   = "matching",
	edit   = "editing",
	write  = "writing",
	run    = "running",
	shell  = "executing",
	update_plan = "planning",
}

local function tool_color(name)
	return TOOL_COLORS[name] or "blue"
end

local function tool_verb(name)
	return TOOL_VERBS[name] or "calling"
end

local function visible_len(value)
	return #(tostring(value or ""):gsub("\27%[[%d;]*m", ""))
end

local function pad_right(value, width)
	value = tostring(value or "")
	local pad = width - visible_len(value)
	if pad > 0 then
		return value .. (" "):rep(pad)
	end
	return value
end

-- ─── ASCII Banner ───────────────────────────────────────────────────────────

local BANNER_SUB = "  lua coding agent"

ui.header_lines = 0

function ui.header(session, opts)
	opts = opts or {}
	local lines = 0
	io.write("\n"); lines = lines + 1
	if opts.animated_logo then
		for _ = 1, 4 do
			io.write("\n"); lines = lines + 1
		end
	else
		local BANNER = {
			"  \xe2\x94\x83  \xe2\x94\x8c\xe2\x94\x80 \xe2\x94\x8c\xe2\x94\x80\xe2\x94\x90",
			"  \xe2\x94\x83  \xe2\x94\x82  \xe2\x94\x9c\xe2\x94\x80\xe2\x94\xa4",
			"  \xe2\x94\x97\xe2\x94\x81 \xe2\x94\x94\xe2\x94\x80 \xe2\x94\x82 \xe2\x94\x82",
		}
		for _, line in ipairs(BANNER) do
			io.write(color("cyan", line) .. "\n"); lines = lines + 1
		end
		io.write("\n"); lines = lines + 1
	end
	io.write(color("dim", BANNER_SUB) .. "\n"); lines = lines + 1
	io.write("\n"); lines = lines + 1

	local w = math.min(term_width, 72)
	io.write(color("dim", box.tl .. hrule(w - 2, session.model) .. box.tr) .. "\n"); lines = lines + 1
	io.write(color("dim", box.v) .. "  " .. color("dim", session.cwd))
	local path_len = #session.cwd
	local pad = w - 4 - path_len
	if pad > 0 then io.write((" "):rep(pad)) end
	io.write(color("dim", box.v) .. "\n"); lines = lines + 1
	io.write(color("dim", box.bl .. box.h:rep(w - 2) .. box.br) .. "\n"); lines = lines + 1
	io.write("\n"); lines = lines + 1
	ui.muted("  type /help for commands"); lines = lines + 1
	io.write("\n"); lines = lines + 1
	ui.header_lines = lines
end

-- ─── Prompt ─────────────────────────────────────────────────────────────────

function ui.prompt()
	return color("cyan", "> ")
end

function ui.plain_prompt(session)
	-- linenoise-luv counts prompt bytes, not terminal display columns.
	-- Multibyte Unicode prompts (for example "☽ ") make cursor redraw/backspace
	-- positions drift, so keep the editable prompt ASCII-only.
	local flow = session and session.flow or "off"
	if flow == "insanitywolf" then
		return "lca insanitywolf > "
	end
	return "lca > "
end

-- ─── Turn Separator ─────────────────────────────────────────────────────────

local turn_number = 0

function ui.turn_separator(session)
	turn_number = turn_number + 1
	refresh_term_size()
	local w = math.min(term_width, 72)
	local ts = os.date("%H:%M")
	local label = string.format("turn %d · %s", turn_number, ts)
	if session and session.token_status then
		label = label .. " · " .. session:token_status()
	end
	io.write("\r\27[K" .. color("dim", hrule(w, label)) .. "\n\n")
end

-- ─── Thinking / Spinner ─────────────────────────────────────────────────────

local uv = require("luv")

local spinner_timer = nil
local spinner_frame = 0
local streaming_text = false
local ACTIVE_GLYPHS = { "◐", "◓", "◑", "◒" }
local spinner_started_at = 0
local spinner_label = "thinking"

local spinner_active_flag = false
local last_token_time = 0
local STALL_THRESHOLD = 3.0

local function render_label(label)
	if type(label) ~= "table" then
		return color("dim", tostring(label or ""))
	end
	local before = tostring(label.before or "")
	local highlight = tostring(label.highlight or "")
	local after = tostring(label.after or "")
	return color("dim", before) .. styled({ "bold", "white" }, highlight) .. color("dim", after)
end

function ui.thinking(_message_count, label)
	spinner_frame = 0
	streaming_text = false
	spinner_active_flag = true
	last_token_time = 0
	spinner_started_at = uv.hrtime() / 1e9
	spinner_label = label or "thinking"

	if spinner_timer then
		if not spinner_timer:is_closing() then
			spinner_timer:stop()
			spinner_timer:close()
		end
		spinner_timer = nil
	end

	spinner_timer = uv.new_timer()
	spinner_timer:start(0, 120, function()
		if not spinner_active_flag then return end
		spinner_frame = spinner_frame + 1

		-- Stall detection: tokens were flowing but stopped
		if streaming_text and last_token_time > 0 then
			local now = uv.hrtime() / 1e9
			local stalled = now - last_token_time
			if stalled >= STALL_THRESHOLD then
				local pulse = ACTIVE_GLYPHS[(spinner_frame % #ACTIVE_GLYPHS) + 1]
				local secs = math.floor(stalled)
				io.write("\r\27[K  " .. color("cyan", pulse) .. " " .. color("cyan", pad_right("model", 10)) .. color("dim", "waiting  " .. tostring(secs) .. "s"))
				io.flush()
			end
			return
		end

		if streaming_text then return end

		local glyph = ACTIVE_GLYPHS[(spinner_frame % #ACTIVE_GLYPHS) + 1]
		local elapsed = uv.hrtime() / 1e9 - spinner_started_at
		io.write("\r\27[K  " .. color("cyan", glyph) .. " " .. color("cyan", pad_right("model", 10)) .. render_label(spinner_label) .. color("dim", "  " .. string.format("%.1fs", elapsed)))
		io.flush()
	end)
end

function ui.suppress_spinner()
	streaming_text = true
	last_token_time = uv.hrtime() / 1e9
end

function ui.token_received()
	last_token_time = uv.hrtime() / 1e9
end

function ui.clear_thinking()
	streaming_text = true
	spinner_active_flag = false
	if spinner_timer then
		if not spinner_timer:is_closing() then
			spinner_timer:stop()
			spinner_timer:close()
		end
		spinner_timer = nil
	end
	io.write("\r\27[K")
	io.flush()
end

-- ─── Stream Stats ───────────────────────────────────────────────────────────

local function transport_label(meta)
	meta = meta or {}
	local transport = meta._transport
	if transport == "websocket" then
		return meta._transport_reused and "ws reused" or "ws"
	elseif transport == "http" then
		return meta._transport_fallback and "http fallback" or "http"
	end
	return nil
end

function ui.stream_stats(tokens, elapsed, ttft, meta)
	local tps = elapsed > 0 and (tokens / elapsed) or 0
	local transport = transport_label(meta)
	local suffix = transport and (" · " .. transport) or ""
	io.write(color("dim", string.format("  (%d tokens, %.1fs, TTFT %.2fs, %.0f tok/s%s)", tokens, elapsed, ttft, tps, suffix)) .. "\n")
end

-- ─── Compaction ─────────────────────────────────────────────────────────────

local rail_line
local rail_block

function ui.compaction(msgs_removed, new_tokens)
	io.write(color("dim", string.format("  [compacted: %d messages summarized, ~%dk tokens retained]", msgs_removed, math.floor(new_tokens / 1000))) .. "\n")
end

local function extract_summary_section(text, heading)
	local source = tostring(text or "")
	local escaped = heading:gsub("([^%w])", "%%%1")
	local start_pos = source:find("\n## " .. escaped, 1, false)
	if not start_pos and source:sub(1, #heading + 3) == "## " .. heading then
		start_pos = 1
	end
	if not start_pos then
		return nil
	end
	local content_start = source:find("\n", start_pos, true)
	if not content_start then
		return nil
	end
	content_start = content_start + 1
	local next_heading = source:find("\n## ", content_start, true)
	local section = next_heading and source:sub(content_start, next_heading - 1) or source:sub(content_start)
	section = section:gsub("^%s+", ""):gsub("%s+$", "")
	return section ~= "" and section or nil
end

function ui.checkpoint(summary, opts)
	opts = opts or {}
	local label = "insanitywolf tucked the chaos away"
	if opts.cycle then
		label = label .. "  " .. tostring(opts.cycle) .. "/5"
	end
	local tokens = tonumber(opts.tokens)
	if tokens then
		label = label .. "  ~" .. tostring(math.floor((tokens + 500) / 1000)) .. "k tokens kept"
	end
	rail_line("◌", "magenta", "checkpoint", label)
	local next_steps = extract_summary_section(summary, "Next Steps")
	local critical = extract_summary_section(summary, "Critical Context")
	if next_steps then
		rail_block("next", next_steps, { max_lines = 8, max_width = 120, max_bytes = 1800 })
	end
	if critical then
		rail_block("context", critical, { max_lines = 5, max_width = 120, max_bytes = 1000 })
	end
end

-- ─── Assistant Output ───────────────────────────────────────────────────────

function ui.assistant(text)
	io.write(text)
	if text:sub(-1) ~= "\n" then
		io.write("\n")
	end
	io.write("\n")
end

function ui.block(text)
	io.write(text)
	if text:sub(-1) ~= "\n" then
		io.write("\n")
	end
end

function ui.jobs(list)
	local jobs = require("agent.jobs")
	local running = 0
	local failed = 0
	for _, job in ipairs(list) do
		if job.status == "running" and job.alive == true then
			running = running + 1
		elseif job.status == "failed_to_start" or job.status == "timed_out" then
			failed = failed + 1
		end
	end
	local summary = tostring(#list) .. " job" .. (#list == 1 and "" or "s")
	if running > 0 then
		summary = summary .. "  " .. tostring(running) .. " running"
	end
	if failed > 0 then
		summary = summary .. "  " .. tostring(failed) .. " failed"
	end
	io.write("  " .. color("cyan", "◉") .. " " .. color("cyan", pad_right("background", 11)) .. color("dim", summary) .. "\n")
	io.write("  " .. color("dim", "┆ " .. pad_right("id", 10) .. pad_right("status", 17) .. pad_right("age", 8) .. pad_right("port", 8) .. pad_right("act", 8) .. "command") .. "\n")
	for _, job in ipairs(list) do
		local d = jobs.display(job)
		local icon = "◇"
		local status_color = "dim"
		if d.status == "running" then
			icon = "◉"
			status_color = "green"
		elseif d.status == "failed_to_start" or d.status == "timed_out" then
			icon = "✗"
			status_color = "red"
		elseif d.status == "stopped" then
			icon = "■"
			status_color = "yellow"
		elseif d.status == "exited" then
			icon = "◆"
			status_color = "cyan"
		end
		local status = d.status
		if d.timeout ~= "" then
			status = status .. "/t:" .. d.timeout
		end
		local line = pad_right(d.id, 10)
			.. pad_right(status, 17)
			.. pad_right(d.age, 8)
			.. pad_right(d.port, 8)
			.. pad_right(d.activity, 8)
			.. d.label
		io.write("  " .. color(status_color, icon) .. " " .. color("dim", line) .. "\n")
	end
end

function ui.background_jobs_summary(list, verb)
	local jobs = require("agent.jobs")
	if not list or #list == 0 then return end
	local noun = #list == 1 and "job" or "jobs"
	io.write("  " .. color("cyan", "◉") .. " " .. color("cyan", pad_right("background", 11)) .. color("dim", tostring(#list) .. " " .. noun .. " " .. tostring(verb or "running")) .. "\n")
	for _, job in ipairs(list) do
		local d = jobs.display(job)
		local port = d.port ~= "" and (d.port .. "  ") or ""
		io.write("  " .. color("dim", "┆ " .. pad_right(d.id, 10)) .. color("dim", port .. d.label) .. "\n")
	end
end

local function job_status_style(status)
	if status == "running" then
		return "◉", "green"
	elseif status == "failed_to_start" or status == "timed_out" then
		return "✗", "red"
	elseif status == "stopped" then
		return "■", "yellow"
	elseif status == "exited" then
		return "◆", "cyan"
	end
	return "◇", "dim"
end

local function job_detail_field(label, value)
	if value == nil or value == "" then return end
	io.write("  " .. color("dim", "┆ " .. pad_right(label, 9)) .. color("dim", tostring(value)) .. "\n")
end

local function job_num(value)
	if value == nil then return nil end
	local n = tonumber(value)
	if n then return tostring(math.floor(n)) end
	return tostring(value)
end

function ui.job_detail(job, opts)
	opts = opts or {}
	local jobs = require("agent.jobs")
	local d = jobs.display(job)
	local glyph, status_color = job_status_style(d.status)
	local headline = d.status
	if job.exit_code ~= nil then
		headline = headline .. " " .. tostring(job.exit_code)
	end
	if d.port ~= "" then
		headline = headline .. "  " .. d.port
	end
	headline = headline .. "  " .. d.label
	io.write("  " .. color(status_color, glyph) .. " " .. color(status_color, pad_right(d.id, 10)) .. color("dim", headline) .. "\n")
	job_detail_field("age", d.age)
	job_detail_field("cwd", job.cwd)
	job_detail_field("pid", job_num(job.pid))
	job_detail_field("pgid", job_num(job.pgid))
	job_detail_field("alive", tostring(job.alive == true))
	if job.timeout ~= nil then
		job_detail_field("timeout", tostring(math.floor(tonumber(job.timeout) or 0)) .. "ms")
	end
	job_detail_field("started", job.started_at)
	job_detail_field("finished", job.finished_at)
	job_detail_field("command", job.command)
	if opts.paths ~= false then
		job_detail_field("stdout", job.stdout)
		job_detail_field("stderr", job.stderr)
	end
end

function ui.job_output(id, output, opts)
	opts = opts or {}
	local stream = opts.stream or "stdout"
	local label = stream
	if opts.tail then
		label = label .. "  last " .. tostring(opts.tail) .. " lines"
	end
	io.write("  " .. color("cyan", "◉") .. " " .. color("cyan", pad_right(tostring(id or "job"), 10)) .. color("dim", label) .. "\n")
	if rail_block then
		rail_block("output", output ~= "" and output or "(no output)", { max_lines = opts.max_lines or 20, max_width = 140, max_bytes = opts.max_bytes or 4000 })
	else
		io.write(tostring(output ~= "" and output or "(no output)") .. "\n")
	end
end

function ui.muted(text)
	io.write(color("dim", text) .. "\n")
end

function ui.model_progress(text)
	io.write("  " .. color("cyan", "◌") .. " " .. color("cyan", pad_right("model", 10)) .. render_label(text) .. "\n")
	io.flush()
end

function ui.model_progress_live(text, glyph_color)
	local glyph = ACTIVE_GLYPHS and ACTIVE_GLYPHS[(spinner_frame % #ACTIVE_GLYPHS) + 1] or "◐"
	spinner_frame = spinner_frame + 1
	glyph_color = glyph_color or "cyan"
	io.write("\r\27[K  " .. color(glyph_color, glyph) .. " " .. color(glyph_color, pad_right("model", 10)) .. render_label(text))
	io.flush()
end

function ui.clear_model_progress()
	io.write("\r\27[K")
	io.flush()
end

function ui.error(text)
	io.stderr:write(color("red", "  \xe2\x9c\x97 error: ") .. text .. "\n")
end

-- ─── Tool Execution (rail/timeline display) ─────────────────────────────────

local function render_description(event)
	local name = event.name
	local args = event.args or {}
	local verb = tool_verb(name)

	if name == "read" and args.path then
		local basename = args.path:match("([^/]+)$") or args.path
		return verb .. " " .. basename
	elseif name == "ls" and args.path then
		return verb .. " " .. args.path
	elseif name == "find" and args.path then
		local pattern = args.glob or args.pattern or ""
		if pattern ~= "" then
			return verb .. " " .. args.path .. " for " .. pattern
		end
		return verb .. " " .. args.path
	elseif name == "grep" and args.pattern then
		local target = args.path or "."
		return verb .. " /" .. args.pattern .. "/ in " .. target
	elseif name == "edit" and args.path then
		local basename = args.path:match("([^/]+)$") or args.path
		return verb .. " " .. basename
	elseif name == "write" and args.path then
		local basename = args.path:match("([^/]+)$") or args.path
		return verb .. " " .. basename
	elseif name == "run" and args.command then
		return "shell command"
	elseif name == "job_start" and args.command then
		local cmd = args.command:gsub("%s+", " ")
		if #cmd > 110 then cmd = cmd:sub(1, 107) .. "..." end
		return "starting background `" .. cmd .. "`"
	elseif name == "job_status" and args.id then
		return "checking " .. tostring(args.id)
	elseif name == "job_output" and args.id then
		return "reading " .. tostring(args.id)
	elseif name == "job_stop" and args.id then
		return "stopping " .. tostring(args.id)
	elseif name == "job_wait" and args.id then
		return "waiting for " .. tostring(args.id)
	end

	if name:match("^mcp__") then
		local server, tool = name:match("^mcp__([^_]+)__(.+)$")
		if server and tool then
			return "calling " .. server .. ":" .. tool
		end
	end

	return verb .. " " .. name
end

local function render_result_hint(event)
	if not event.result then return nil end
	if event.result.is_error then return nil end
	if event.name == "job_start" and event.result.job then
		local jobs = require("agent.jobs")
		local d = jobs.display(event.result.job)
		local pieces = { d.id, d.status }
		if d.port ~= "" then pieces[#pieces + 1] = d.port end
		if d.timeout ~= "" then pieces[#pieces + 1] = "timeout " .. d.timeout end
		pieces[#pieces + 1] = d.label
		return table.concat(pieces, "  ")
	end
	if event.name == "job_status" or event.name == "job_stop" or event.name == "job_wait" then
		if event.result.summary then return event.result.summary end
	end
	if event.result.summary then return event.result.summary end
	if event.name == "read" and event.result.content then
		local lines = 0
		for _ in event.result.content:gmatch("\n") do lines = lines + 1 end
		if lines > 0 then return lines .. " lines" end
	end
	if event.name == "grep" and event.result.content then
		local matches = 0
		for _ in event.result.content:gmatch("\n") do matches = matches + 1 end
		if matches > 0 then return matches .. " match" .. (matches == 1 and "" or "es") end
	end
	return nil
end

local function render_result_target(event)
	local args = event.args or {}
	if event.name == "read" and args.path then
		return args.path:match("([^/]+)$") or args.path
	elseif event.name == "ls" and args.path then
		return args.path
	elseif event.name == "find" and args.path then
		return args.path
	elseif event.name == "grep" then
		return args.path or "."
	elseif (event.name == "edit" or event.name == "write") and args.path then
		return args.path:match("([^/]+)$") or args.path
	elseif event.name == "job_start" then
		return "background"
	elseif event.name == "job_status" or event.name == "job_output" or event.name == "job_stop" or event.name == "job_wait" then
		return args.id
	end
	return nil
end

local function limited_lines(value, opts)
	opts = opts or {}
	local max_lines = opts.max_lines or 6
	local max_width = opts.max_width or 120
	local max_bytes = opts.max_bytes or 1200
	local text = tostring(value or ""):gsub("\r", "")
	if #text > max_bytes then
		text = text:sub(1, max_bytes) .. "\n..."
	end
	local lines = {}
	local truncated = false
	for line in (text .. "\n"):gmatch("(.-)\n") do
		if #lines >= max_lines then
			truncated = true
			break
		end
		local l = line:gsub("\t", "    ")
		if #l > max_width then
			l = l:sub(1, max_width - 3) .. "..."
		end
		lines[#lines + 1] = l
	end
	if truncated then
		lines[#lines + 1] = "..."
	elseif #lines > 0 and lines[#lines] == "" and text:sub(-1) == "\n" then
		table.remove(lines)
	end
	return lines
end

rail_line = function(glyph, glyph_color, name, text)
	local label = name and pad_right(name, 12) or ""
	io.write("  " .. color(glyph_color, glyph) .. " " .. color(glyph_color, label))
	if text and text ~= "" then
		io.write(color("dim", text))
	end
	io.write("\n")
end

rail_block = function(label, text, opts)
	if not text or text == "" or text == "(no output)" then return end
	local lines = limited_lines(text, opts)
	if #lines == 0 then return end
	io.write("  " .. color("dim", "┆ " .. pad_right(label, 8)) .. color("dim", lines[1]) .. "\n")
	for i = 2, #lines do
		io.write("  " .. color("dim", "┆ " .. pad_right("", 8)) .. color("dim", lines[i]) .. "\n")
	end
end

local function plan_marker(status)
	if status == "completed" then
		return "✓", "green"
	elseif status == "in_progress" then
		return "◉", "cyan"
	end
	return "○", "dim"
end

local function plan_progress_marker(status)
	if status == "completed" then
		return "✓", "green"
	end
	return "○", "dim"
end

local CIRCLED_NUMBERS = {
	"①", "②", "③", "④", "⑤", "⑥", "⑦", "⑧", "⑨", "⑩",
	"⑪", "⑫", "⑬", "⑭", "⑮", "⑯", "⑰", "⑱", "⑲", "⑳",
}

local function plan_number(index)
	return CIRCLED_NUMBERS[index] or tostring(index)
end

local function plan_completed_count(plan)
	if type(plan) ~= "table" then
		return 0
	end
	local completed = 0
	for _, item in ipairs(plan) do
		if item.status == "completed" then
			completed = completed + 1
		end
	end
	return completed
end

function ui.plan_current(plan)
	if type(plan) ~= "table" then
		return nil
	end
	for i, item in ipairs(plan) do
		if item.status == "in_progress" and item.step and item.step ~= "" then
			return item.step, i
		end
	end
	return nil
end

local function plan_last_completed(plan)
	if type(plan) ~= "table" then
		return nil
	end
	for i = #plan, 1, -1 do
		local item = plan[i]
		if item.status == "completed" and item.step and item.step ~= "" then
			return item.step, i
		end
	end
	return nil
end

function ui.plan_progress_label(plan)
	local completed = plan_last_completed(plan)
	local current = ui.plan_current(plan)
	if completed and current then
		return completed .. " → next: " .. current
	end
	return completed or current
end

function ui.plan_ref(index)
	if not index then return "" end
	return plan_number(index)
end

function ui.plan(plan)
	if type(plan) ~= "table" or #plan == 0 then
		ui.muted("  no active plan")
		return
	end
	rail_line("▣", "magenta", "plan", tostring(#plan) .. " steps")
	for i, item in ipairs(plan) do
		local marker, marker_color = plan_marker(item.status)
		local step = tostring(item.step or "")
		local prefix = plan_number(i) .. " " .. marker .. " "
		local lines = limited_lines(step, { max_lines = 2, max_width = 96, max_bytes = 300 })
		io.write("  " .. color("dim", "┆ " .. pad_right("", 8)) .. color(marker_color, prefix) .. color("dim", lines[1] or "") .. "\n")
		for j = 2, #lines do
			io.write("  " .. color("dim", "┆ " .. pad_right("", 8) .. (" "):rep(#prefix)) .. color("dim", lines[j]) .. "\n")
		end
	end
end

function ui.plan_outline(plan)
	if type(plan) ~= "table" or #plan == 0 then
		ui.muted("  no active plan")
		return
	end
	rail_line("▣", "magenta", "plan", tostring(#plan) .. " steps")
	for i, item in ipairs(plan) do
		local step = tostring(item.step or "")
		local prefix = plan_number(i) .. " "
		local lines = limited_lines(step, { max_lines = 2, max_width = 96, max_bytes = 300 })
		io.write("  " .. color("dim", "┆ " .. pad_right("", 8)) .. color("cyan", prefix) .. styled({ "bold", "white" }, lines[1] or "") .. "\n")
		for j = 2, #lines do
			io.write("  " .. color("dim", "┆ " .. pad_right("", 8) .. (" "):rep(#prefix)) .. styled({ "bold", "white" }, lines[j]) .. "\n")
		end
	end
end

function ui.plan_progress(plan)
	if type(plan) ~= "table" or #plan == 0 then
		rail_line("▣", "magenta", "plan", "cleared")
		return
	end
	local highlight_step = ui.plan_progress_label(plan)
	io.write("  " .. color("magenta", "▣") .. " " .. color("magenta", pad_right("plan", 12)))
	for i, item in ipairs(plan) do
		local marker, marker_color = plan_progress_marker(item.status)
		io.write(color(marker_color, plan_number(i) .. marker))
		if i < #plan then
			io.write(color("dim", " "))
		end
	end
	local suffix = ""
	if highlight_step then
		local compact = tostring(highlight_step):gsub("%s+", " ")
		if #compact > 72 then
			compact = compact:sub(1, 69) .. "..."
		end
		suffix = "  " .. compact
	end
	io.write(color("dim", suffix) .. "\n")
end

function ui.plan_should_list(plan)
	return type(plan) == "table" and #plan > 0 and plan_completed_count(plan) == 0
end

local active_tool_timer = nil
local active_tool_frame = 0
local active_tool_seq = 0
local active_tool_order = {}
local active_tool_by_id = {}
local active_tool_queues = {}

local function now_seconds()
	return uv.hrtime() / 1e9
end

local function format_duration(seconds)
	seconds = math.max(0, tonumber(seconds) or 0)
	if seconds < 10 then
		return string.format("%.1fs", seconds)
	end
	return tostring(math.floor(seconds + 0.5)) .. "s"
end

local function format_elapsed(seconds)
	seconds = tonumber(seconds)
	if not seconds or seconds < 1 then
		return nil
	end
	return format_duration(seconds)
end

local function tool_event_key(event)
	local args = event.args or {}
	return table.concat({
		event.name or "",
		args.path or "",
		args.command or "",
		args.pattern or "",
		args.glob or "",
		args.id or "",
	}, "\0")
end

local function queue_remove_first(queue)
	if not queue or #queue == 0 then return nil end
	local id = queue[1]
	table.remove(queue, 1)
	return id
end

local function render_active_tools()
	if not active_tool_timer then return end
	local count = #active_tool_order
	if count == 0 then
		io.write("\r\27[K")
		io.flush()
		return
	end

	active_tool_frame = active_tool_frame + 1
	local glyph = ACTIVE_GLYPHS[(active_tool_frame % #ACTIVE_GLYPHS) + 1]
	local first = active_tool_by_id[active_tool_order[1]]
	local elapsed = first and format_duration(now_seconds() - first.started_at) or nil
	local text
	if count == 1 and first then
		text = first.name .. "  " .. first.desc
		if elapsed then
			text = text .. "  " .. elapsed
		end
	else
		local names = {}
		local seen = {}
		for _, id in ipairs(active_tool_order) do
			local item = active_tool_by_id[id]
			if item and not seen[item.name] then
				seen[item.name] = true
				names[#names + 1] = item.name
			end
		end
		text = tostring(count) .. " tools running  " .. table.concat(names, ", ")
		if elapsed then
			text = text .. "  " .. elapsed
		end
	end
	io.write("\r\27[K  " .. color("cyan", glyph) .. " " .. color("dim", text))
	io.flush()
end

local function ensure_active_tool_timer()
	if active_tool_timer then return end
	active_tool_timer = uv.new_timer()
	active_tool_timer:start(120, 120, render_active_tools)
end

local function stop_active_tool_timer_if_idle()
	if #active_tool_order > 0 or not active_tool_timer then return end
	if not active_tool_timer:is_closing() then
		active_tool_timer:stop()
		active_tool_timer:close()
	end
	active_tool_timer = nil
	io.write("\r\27[K")
	io.flush()
end

local function mark_tool_started(event, desc)
	active_tool_seq = active_tool_seq + 1
	local id = active_tool_seq
	local key = tool_event_key(event)
	local item = {
		id = id,
		key = key,
		name = event.name,
		desc = desc,
		started_at = now_seconds(),
	}
	active_tool_by_id[id] = item
	active_tool_order[#active_tool_order + 1] = id
	active_tool_queues[key] = active_tool_queues[key] or {}
	active_tool_queues[key][#active_tool_queues[key] + 1] = id
	ensure_active_tool_timer()
	return item
end

local function mark_tool_finished(event)
	local key = tool_event_key(event)
	local id = queue_remove_first(active_tool_queues[key])
	if not id and #active_tool_order > 0 then
		id = active_tool_order[1]
	end
	local item = id and active_tool_by_id[id] or nil
	if id then
		active_tool_by_id[id] = nil
		for index, active_id in ipairs(active_tool_order) do
			if active_id == id then
				table.remove(active_tool_order, index)
				break
			end
		end
	end
	stop_active_tool_timer_if_idle()
	return item and (now_seconds() - item.started_at) or nil
end

local tool_count = 0
local tool_names = {}
local tool_failures = 0
local tool_blocked = 0
local tool_batch_started_at = nil

local function tool_safety_state(event)
	local result = event and event.result
	local summary = result and result.summary
	if summary == "stale tag" then
		return "needs re-read", "stale file tags; re-read before retrying"
	elseif summary == "stale batch mutation" then
		return "blocked", "duplicate mutation blocked"
	elseif summary == "dependent batch mutation" or (result and result.ui_state == "deferred") then
		return "deferred", "deferred until read result"
	end
	return nil
end

local function note_tool_batch_event(event)
	if event.phase == "start" then
		tool_batch_started_at = tool_batch_started_at or now_seconds()
		return
	end
	tool_batch_started_at = tool_batch_started_at or now_seconds()
	tool_count = tool_count + 1
	table.insert(tool_names, event.name)
	if tool_safety_state(event) then
		tool_blocked = tool_blocked + 1
	elseif event.result and event.result.is_error then
		tool_failures = tool_failures + 1
	end
end

function ui.tool(event)
	if DEBUG then
		io.write(color("cyan", "\xe2\x97\x8f " .. event.name))
		local desc = render_description(event)
		io.write(color("dim", "  " .. desc))
		if event.phase == "start" then
			io.write(color("dim", "  \226\134\146 started") .. "\n")
		else
			io.write("\n")
		end
		local safety_state, safety_text = tool_safety_state(event)
		if safety_state then
			io.write(color("dim", "  " .. safety_text) .. "\n")
		elseif event.result and event.result.is_error then
			io.write(color("red", "  error: ") .. event.result.content .. "\n")
		elseif event.name == "run" and event.result and event.result.content and event.result.content ~= "(no output)" then
			io.write("\n")
			io.write(event.result.content)
			if event.result.content:sub(-1) ~= "\n" then
				io.write("\n")
			end
		end
		io.write("\n")
	else
		note_tool_batch_event(event)

		local tc = tool_color(event.name)
		local desc = render_description(event)
		local hint = render_result_hint(event)

		io.write("\r\27[K")

		local safety_state, safety_text = tool_safety_state(event)
		if safety_state then
			mark_tool_finished(event)
			rail_line("◇", "yellow", event.name, desc .. "  " .. safety_state)
			rail_block("note", safety_text, { max_lines = 3, max_width = 120, max_bytes = 400 })
		elseif event.result and event.result.is_error then
			local elapsed = mark_tool_finished(event)
			local msg = event.result.content or ""
			local summary = event.result.summary and ("  " .. event.result.summary) or ""
			local elapsed_text = format_elapsed(elapsed)
			if elapsed_text then
				summary = summary .. "  " .. elapsed_text
			end
			rail_line("✗", "red", event.name, desc .. summary)
			rail_block("error", msg, { max_lines = 6, max_width = 120, max_bytes = 1200 })
		else
			if event.phase == "start" then
				mark_tool_started(event, desc)
				rail_line("◉", tc, event.name, desc)
				if event.name == "run" and event.args and event.args.command then
					rail_block("command", event.args.command, { max_lines = 6, max_width = 120, max_bytes = 1200 })
				end
			else
				local elapsed = mark_tool_finished(event)
				local target = render_result_target(event)
				local status = hint or ""
				if target then
					status = status ~= "" and (target .. "  " .. status) or target
				end
				local elapsed_text = format_elapsed(elapsed)
				if elapsed_text then
					status = status ~= "" and (status .. "  " .. elapsed_text) or elapsed_text
				end
				rail_line("◆", tc, event.name, status)
				if event.name == "update_plan" and event.result and event.result.plan then
					if ui.plan_should_list(event.result.plan) then
						ui.plan_outline(event.result.plan)
					else
						ui.plan_progress(event.result.plan)
					end
				elseif event.name == "update_plan" and event.result and event.result.content then
					rail_block("plan", event.result.content, { max_lines = 12, max_width = 120, max_bytes = 1600 })
				elseif event.name == "run" and event.result and event.result.content then
					rail_block("output", event.result.content, { max_lines = 6, max_width = 120, max_bytes = 1200 })
				elseif event.name == "grep" and event.result and event.result.content then
					rail_block("matches", event.result.content, { max_lines = 4, max_width = 120, max_bytes = 800 })
				end
			end
		end
		io.flush()
	end
end

function ui.tool_summary()
	if not DEBUG and tool_count > 0 then
		io.write("\r\27[K")

		local seen = {}
		local unique = {}
		for _, name in ipairs(tool_names) do
			if not seen[name] then
				seen[name] = true
				table.insert(unique, name)
			end
		end
		local tools_used = table.concat(unique, ", ")
		local label = tool_count .. " tool" .. (tool_count == 1 and "" or "s")
		local ok_count = math.max(0, tool_count - tool_failures - tool_blocked)
		local outcome
		if tool_failures == 0 and tool_blocked == 0 then
			outcome = nil
		elseif tool_failures == 0 then
			outcome = tostring(tool_blocked) .. " blocked"
		elseif tool_blocked == 0 then
			outcome = tostring(tool_failures) .. " failed"
		else
			outcome = tostring(tool_blocked) .. " blocked, " .. tostring(tool_failures) .. " failed"
		end
		local elapsed = tool_batch_started_at and format_elapsed(now_seconds() - tool_batch_started_at) or nil
		if tool_count > 1 then
			local text = label
			if outcome then
				text = text .. "  " .. outcome
			end
			if elapsed then
				text = text .. "  " .. elapsed
			end
			text = text .. "  " .. tools_used
			rail_line(tool_failures > 0 and "✗" or "◇", tool_failures > 0 and "red" or "dim", "batch", text)
		end
		tool_count = 0
		tool_names = {}
		tool_failures = 0
		tool_blocked = 0
		tool_batch_started_at = nil
	end
end

function ui.tool_header()
end

-- ─── Status Display ─────────────────────────────────────────────────────────

local function context_bar(tokens, max_tokens)
	local bars = { "\xe2\x96\x81", "\xe2\x96\x82", "\xe2\x96\x83", "\xe2\x96\x84", "\xe2\x96\x85", "\xe2\x96\x86", "\xe2\x96\x87", "\xe2\x96\x88" }
	local ratio = math.min(tokens / max_tokens, 1.0)
	local idx = math.floor(ratio * (#bars - 1)) + 1
	local bar_color = ratio < 0.5 and "green" or (ratio < 0.8 and "yellow" or "red")
	return color(bar_color, bars[idx])
end

local function plan_status(plan)
	if type(plan) ~= "table" or #plan == 0 then
		return nil
	end
	local completed = 0
	local current = nil
	for _, item in ipairs(plan) do
		if item.status == "completed" then
			completed = completed + 1
		elseif item.status == "in_progress" and not current then
			current = item.step
		end
	end
	local text = tostring(completed) .. "/" .. tostring(#plan) .. " completed"
	if current and current ~= "" then
		text = text .. ", current: " .. current
	end
	return text
end

function ui.status(session)
	local compaction_mod = require("agent.compaction")
	local tokens = compaction_mod.estimate_total(session.messages)
	refresh_term_size()
	local w = math.min(term_width, 60)
	local plan_line = plan_status(session.plan)

	io.write(color("dim", box.tl .. hrule(w - 2, "status") .. box.tr) .. "\n")
	local lines = {
		"model: " .. session.model,
		"reasoning: " .. (session.reasoning_effort or "default"),
		"service tier: " .. (session.service_tier or "default"),
		"mode: " .. ((session.flow == "insanitywolf") and "insanitywolf" or "normal"),
		"cwd: " .. session.cwd,
		"credentials: " .. session.credentials_path,
		"turns: " .. session:turn_count(),
		"context: ~" .. math.floor(tokens / 1000) .. "k tokens (" .. #session.messages .. " messages) " .. context_bar(tokens, 200000),
		"compacted: " .. (session.compaction_summary and "yes" or "no"),
	}
	if plan_line then
		table.insert(lines, 5, "plan: " .. plan_line)
	end
	for _, l in ipairs(lines) do
		io.write(color("dim", box.v) .. " " .. l .. "\n")
	end
	io.write(color("dim", box.bl .. box.h:rep(w - 2) .. box.br) .. "\n")
end

return ui
