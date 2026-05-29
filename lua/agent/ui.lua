local ui = {}

local DEBUG = false

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

local TOOL_SHORT = {
	read = "read",
	ls = "ls",
	find = "find",
	grep = "grep",
	edit = "edit",
	write = "write",
	run = "run",
	shell = "shell",
	job_start = "job",
	job_status = "job",
	job_output = "job",
	job_stop = "job",
	job_wait = "job",
	update_plan = "plan",
}

local TOOL_GROUP_ORDER = {
	"plan",
	"ls",
	"find",
	"grep",
	"read",
	"edit",
	"write",
	"run",
	"shell",
	"job",
	"mcp",
	"tool",
}

local TOOL_GROUP_RANK = {}
for index, name in ipairs(TOOL_GROUP_ORDER) do
	TOOL_GROUP_RANK[name] = index
end

local STACK_FRAME_ORDER = {
	"verify",
	"serve",
	"write",
	"inspect",
	"plan",
	"external",
	"tools",
}

local STACK_FRAME_RANK = {}
for index, name in ipairs(STACK_FRAME_ORDER) do
	STACK_FRAME_RANK[name] = index
end

local function tool_group(name)
	name = tostring(name or "")
	if name:match("^mcp__") then
		return "mcp"
	end
	return TOOL_SHORT[name] or "tool"
end

local function stack_frame_for_group(group)
	if group == "run" or group == "shell" then
		return "verify"
	elseif group == "job" then
		return "serve"
	elseif group == "write" or group == "edit" then
		return "write"
	elseif group == "ls" or group == "find" or group == "grep" or group == "read" then
		return "inspect"
	elseif group == "plan" then
		return "plan"
	elseif group == "mcp" then
		return "external"
	end
	return "tools"
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
		return "lca ! > "
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
	local label = "insanitywolf transition"
	if opts.cycle then
		label = label .. "  " .. tostring(opts.cycle) .. "/5"
	end
	local tokens = tonumber(opts.tokens)
	if tokens then
		label = label .. "  ~" .. tostring(math.floor((tokens + 500) / 1000)) .. "k tokens kept"
	end
	rail_line("◌", "magenta", "checkpoint", label)
	rail_block("pause", table.concat({
		"Requested cycle is complete.",
		"Next autonomous cycle may start only after the assistant explains the proposed direction.",
		"Press Ctrl-C now to stop before the next cycle.",
	}, "\n"), { max_lines = 4, max_width = 120, max_bytes = 800 })
	local next_steps = extract_summary_section(summary, "Next Steps")
	local critical = extract_summary_section(summary, "Critical Context")
	if next_steps then
		rail_block("next", next_steps, { max_lines = 16, max_width = 120, max_bytes = 3200, wrap = true })
	end
	if critical then
		rail_block("context", critical, { max_lines = 8, max_width = 120, max_bytes = 1800, wrap = true })
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

local live_ast_lines = 0
local live_tree_buffer = nil
local live_tree_last_activity = 0
local live_tree_started_at = uv.hrtime() / 1e9
local LIVE_TREE_STALL_SECONDS = 15
local LIVE_STREAM_PREVIEW_TTL_SECONDS = 0.9
local LIVE_STREAM_PREVIEW_TAIL = 180
local live_stream_preview = nil
local live_stream_preview_at = 0
local live_stream_preview_bytes = 0

function ui.clear_live_ast()
	if live_ast_lines <= 0 then
		return
	end
	io.write("\r")
	for _ = 1, live_ast_lines do
		io.write("\27[1A\27[2K")
	end
	live_ast_lines = 0
	io.flush()
end

local function normalize_stream_preview(text)
	text = tostring(text or ""):gsub("\r", " "):gsub("\n", " "):gsub("%s+", " ")
	text = text:gsub("^%s+", ""):gsub("%s+$", "")
	if text:find("<tool_call", 1, true) or text:find("</tool_call>", 1, true) then
		return ""
	end
	return text
end

function ui.live_stream_preview(text, bytes)
	text = normalize_stream_preview(text)
	if text == "" then
		return
	end
	if live_stream_preview and live_stream_preview ~= "" then
		live_stream_preview = live_stream_preview .. " " .. text
	else
		live_stream_preview = text
	end
	if #live_stream_preview > LIVE_STREAM_PREVIEW_TAIL then
		live_stream_preview = live_stream_preview:sub(#live_stream_preview - LIVE_STREAM_PREVIEW_TAIL + 1)
	end
	live_stream_preview_at = uv.hrtime() / 1e9
	live_stream_preview_bytes = tonumber(bytes) or live_stream_preview_bytes
	ui.note_live_tree_activity()
end

function ui.clear_live_stream_preview()
	live_stream_preview = nil
	live_stream_preview_at = 0
	live_stream_preview_bytes = 0
end

local function terminal_size()
	local width = tonumber(os.getenv("COLUMNS"))
	local height = tonumber(os.getenv("LINES"))
	local ok, tty = pcall(uv.new_tty, 1, false)
	if ok and tty then
		local w, h = tty:get_winsize()
		if not tty:is_closing() then
			tty:close()
		end
		width = tonumber(w) or width
		height = tonumber(h) or height
	end
	width = width or term_width or 80
	height = height or 24
	return width, height
end

local function truncate_text(value, width)
	value = tostring(value or ""):gsub("\t", "    "):gsub("\r", " "):gsub("\n", " ")
	value = value:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
	if width <= 0 then return "" end
	if visible_len(value) <= width then
		return value
	end
	if width <= 3 then
		return value:sub(1, width)
	end
	return value:sub(1, width - 3) .. "..."
end

local function node_summary(node)
	if not node then return "" end
	return tostring(node.summary or node.detail or "")
end

local function node_title(node)
	if not node then return "" end
	local label = tostring(node.label or node.kind or "")
	if node.kind == "intent" then
		return node_summary(node)
	elseif node.kind == "plan_step" then
		label = label:gsub("^%d+%.%s*", "")
	elseif node.kind == "return_value" then
		label = "final answer"
	elseif node.kind == "verify" and node.meta and tostring(node.status or "") == "error" and node.meta.failed_headline then
		return label .. "  " .. tostring(node.meta.failed_headline)
	elseif node.kind == "verify" and node.meta and node.meta.last_headline then
		return label .. "  " .. tostring(node.meta.last_headline)
	end
	local summary = node_summary(node)
	if summary ~= "" and summary ~= label then
		return label .. "  " .. summary
	end
	return label
end

local function effective_status(node)
	local status = tostring(node and node.status or "")
	for _, child in ipairs((node and node.children) or {}) do
		local child_status = effective_status(child)
		if child_status == "error" then
			return "error"
		elseif child_status == "cancelled" and status ~= "error" then
			status = "cancelled"
		elseif (child_status == "running" or child_status == "streaming") and status ~= "cancelled" then
			status = child_status
		elseif child_status == "warning" and status ~= "cancelled" and status ~= "running" and status ~= "streaming" then
			status = "warning"
		end
	end
	return status
end

local function status_glyph(status)
	status = tostring(status or "")
	if status == "ok" then return "✓" end
	if status == "error" then return "✗" end
	if status == "cancelled" then return "⊘" end
	if status == "running" or status == "streaming" then return "◐" end
	if status == "warning" then return "◇" end
	return "○"
end


local function first_child(node, kind)
	for _, child in ipairs((node and node.children) or {}) do
		if child.kind == kind then
			return child
		end
	end
	return nil
end

local function is_activeish(node)
	local status = effective_status(node)
	return status == "running" or status == "streaming" or status == "error" or status == "cancelled"
end

function ui.note_live_tree_activity()
	live_tree_last_activity = uv.hrtime() / 1e9
end

local function active_tree_color()
	if live_tree_last_activity > 0 then
		local stalled = (uv.hrtime() / 1e9) - live_tree_last_activity
		if stalled >= LIVE_TREE_STALL_SECONDS then
			return "orange"
		end
	end
	return "green"
end

local function active_status_glyph()
	local elapsed = (uv.hrtime() / 1e9) - live_tree_started_at
	local frame = math.floor(elapsed / 0.12)
	return ACTIVE_GLYPHS[(frame % #ACTIVE_GLYPHS) + 1] or "◐"
end

local function compact_bytes(bytes)
	bytes = tonumber(bytes) or 0
	if bytes < 1024 then
		return tostring(bytes) .. "B"
	end
	return string.format("%.1fkB", bytes / 1024)
end

local function live_stream_preview_line(width)
	if not live_stream_preview or live_stream_preview == "" then
		return nil
	end
	local age = (uv.hrtime() / 1e9) - live_stream_preview_at
	if age > LIVE_STREAM_PREVIEW_TTL_SECONDS then
		return nil
	end
	local prefix = "≋ " .. compact_bytes(live_stream_preview_bytes) .. "  "
	local text_width = math.max(0, width - visible_len(prefix) - 2)
	local preview = truncate_text("..." .. live_stream_preview, text_width)
	return color(active_tree_color(), prefix) .. color("dim", preview)
end

local function render_tree_row(prefix, connector, status, title, width)
	local plain_prefix = tostring(prefix or "") .. tostring(connector or "")
	local available = math.max(0, width - visible_len(plain_prefix) - 2)
	status = tostring(status or "")
	local text = truncate_text(title, available)
	if status == "running" or status == "streaming" then
		return color("dim", plain_prefix) .. color(active_tree_color(), active_status_glyph() .. " " .. text)
	end
	return color("dim", plain_prefix .. status_glyph(status) .. " " .. text)
end

local function render_work_tree(node, lines, opts, prefix, is_last)
	opts = opts or {}
	lines = lines or {}
	prefix = prefix or ""
	local max_lines = opts.max_lines or 24
	if not node or #lines >= max_lines then
		return lines
	end
	local connector = prefix == "" and (opts.force_connector and (is_last and "└─ " or "├─ ") or "") or (is_last and "└─ " or "├─ ")
	if not opts.omit_root then
		local line = render_tree_row(prefix, connector, effective_status(node), node_title(node), opts.width or 80)
		lines[#lines + 1] = line
	end
	if #lines >= max_lines then
		return lines
	end
	local children = node.children or {}
	local child_prefix = prefix
	if prefix ~= "" or opts.force_connector then
		child_prefix = prefix .. (is_last and "   " or "│  ")
	end
	local shown = {}
	for _, child in ipairs(children) do
		if is_activeish(node) or is_activeish(child) or child.kind == "plan" or child.kind == "plan_step" or child.status ~= "ok" then
			shown[#shown + 1] = child
		end
	end
	if #shown == 0 and #children > 0 then
		for i = 1, math.min(#children, 3) do
			shown[#shown + 1] = children[i]
		end
	end
	for index, child in ipairs(shown) do
		local child_opts = opts
		if opts.omit_root then
			child_opts = {}
			for key, value in pairs(opts) do
				child_opts[key] = value
			end
			child_opts.omit_root = false
			child_opts.force_connector = true
		elseif opts.force_connector then
			child_opts = {}
			for key, value in pairs(opts) do
				child_opts[key] = value
			end
			child_opts.force_connector = false
		end
		render_work_tree(child, lines, child_opts, child_prefix, index == #shown)
		if #lines >= max_lines then
			break
		end
	end
	local hidden = #children - #shown
	if hidden > 0 and #lines < max_lines then
		lines[#lines + 1] = color("dim", child_prefix .. "└─ +" .. tostring(hidden) .. " more")
	end
	return lines
end

local function root_tool_batch(root)
	for _, child in ipairs((root and root.children) or {}) do
		if child.kind == "tool_batch" and is_activeish(child) then
			return child
		end
	end
	return nil
end

local function streamed_batch_leaf(batch, opts)
	opts = opts or {}
	if not batch then
		return nil
	end
	local meta = batch.meta or {}
	local discovered = tonumber(meta.discovered) or 0
	local closed = tonumber(meta.closed) or 0
	local deferred = tonumber(meta.deferred) or 0
	local summary = node_summary(batch)
	if discovered > 0 then
		closed = math.min(closed, discovered)
		summary = tostring(closed) .. "/" .. tostring(discovered)
	end
	if deferred > 0 then
		summary = summary .. " +" .. tostring(deferred) .. " deferred"
	end
	if meta.current and tostring(meta.current) ~= "" then
		local current = tostring(meta.current)
		if current ~= "write" and current ~= "edit" and current ~= "run" and current ~= "shell" and current ~= "read" and current ~= "ls" and current ~= "find" and current ~= "grep" then
			summary = summary .. "  " .. current
		end
	end
	local counts = meta.stream_counts or {}
	local label = opts.label
	if not label then
		local writes = (tonumber(counts.write) or 0) + (tonumber(counts.edit) or 0)
		local checks = (tonumber(counts.run) or 0) + (tonumber(counts.shell) or 0)
		local reads = (tonumber(counts.read) or 0) + (tonumber(counts.ls) or 0) + (tonumber(counts.find) or 0) + (tonumber(counts.grep) or 0)
		if writes > 0 then
			label = "writing project files"
		elseif checks > 0 then
			label = "checking project"
		elseif reads > 0 then
			label = "reading workspace"
		else
			label = "preparing work"
		end
	end
	return {
		kind = "stream",
		label = label,
		status = effective_status(batch),
		detail = summary,
		summary = summary,
		meta = {},
		evidence = {},
		children = {},
	}
end

local function plan_child_with_stream(child, batch)
	if not batch or not child or child.kind ~= "plan_step" or not is_activeish(child) then
		return child
	end
	local clone = {}
	for key, value in pairs(child) do
		clone[key] = value
	end
	clone.children = {}
	for _, grandchild in ipairs(child.children or {}) do
		clone.children[#clone.children + 1] = grandchild
	end
	clone.children[#clone.children + 1] = streamed_batch_leaf(batch)
	return clone
end

local function render_root_work_forest(root, plan, max_lines)
	local lines = {}
	local width = terminal_size()
	local synthetic = {
		kind = "turn",
		label = "work",
		status = effective_status(root) or "running",
		detail = nil,
		summary = nil,
		meta = {},
		evidence = {},
		children = {},
	}
	local batch = root_tool_batch(root)
	if plan and plan.kind == "plan" then
		local inserted_batch = false
		for _, child in ipairs(plan.children or {}) do
			synthetic.children[#synthetic.children + 1] = plan_child_with_stream(child, batch)
			if batch and child.kind == "plan_step" and is_activeish(child) then
				inserted_batch = true
			end
		end
		if not inserted_batch and batch then
			synthetic.children[#synthetic.children + 1] = streamed_batch_leaf(batch)
		end
	else
		for _, child in ipairs((root and root.children) or {}) do
			if child.kind ~= "intent" and child.kind ~= "plan" then
				synthetic.children[#synthetic.children + 1] = child
			end
		end
	end
	render_work_tree(synthetic, lines, { max_lines = max_lines, omit_root = true, width = width - 16 }, "", true)
	return lines
end


local function write_live_tree_line(text)
	if live_tree_buffer then
		live_tree_buffer[#live_tree_buffer + 1] = text .. "\n"
		return 1
	end
	io.write(text .. "\n")
	return 1
end

local function live_ast_clear_sequence()
	if live_ast_lines <= 0 then
		return ""
	end
	local parts = { "\r" }
	for _ = 1, live_ast_lines do
		parts[#parts + 1] = "\27[1A\27[2K"
	end
	return table.concat(parts)
end

function ui.live_ast_error_detail(event)
	if not event or not event.result or not event.result.is_error then
		return
	end
	local content = tostring(event.result.content or ""):gsub("\r", "")
	if content == "" then
		return
	end
	local width = terminal_size()
	local max_width = math.max(40, width - 16)
	local command = event.args and event.args.command
	local lines = {}
	lines[#lines + 1] = "  " .. color("red", "┆ error") .. color("dim", " detail")
	if command and command ~= "" then
		lines[#lines + 1] = "  " .. color("dim", "┆ command ") .. color("dim", truncate_text(command, max_width - 10))
	end
	local function clean_error_line(line)
		return tostring(line or "")
			:gsub("^lua:%s*", "")
			:gsub("^%(command line%):%d+:%s*", "")
			:gsub("^%S+%.lua:%d+:%s*", "")
	end
	local shown = 0
	for line in (content .. "\n"):gmatch("(.-)\n") do
		local cleaned = clean_error_line(line:gsub("^%s+", ""):gsub("%s+$", ""))
		local lower = cleaned:lower()
		if cleaned ~= ""
			and not (lower:match("^lua%s+%d") and lower:find("copyright", 1, true)) then
			lines[#lines + 1] = "  " .. color("dim", "┆ ") .. color("dim", truncate_text(cleaned, max_width))
			shown = shown + 1
			if shown >= 3 then
				break
			end
		end
	end
	for _, line in ipairs(lines) do
		io.write(line .. "\n")
	end
	live_ast_lines = live_ast_lines + #lines
	io.flush()
end

local function render_split_live_tree(root, label)
	local width, height = terminal_size()
	local max_height = math.min(40, math.max(8, height - 8))
	local intent = first_child(root, "intent")
	local plan = first_child(root, "plan")
	local tree_root = plan or root
	local tree_lines = render_root_work_forest(root, tree_root, max_height - 1)
	local title = intent and node_summary(intent) or node_title(root)
	local written = write_live_tree_line("  " .. color("magenta", "▧") .. " " .. color("magenta", pad_right(label, 10)) .. color("dim", truncate_text(title, width - 18)))
	local preview = live_stream_preview_line(width - 16)
	if preview then
		written = written + write_live_tree_line("  " .. color("dim", "┆ " .. pad_right("", 10)) .. preview)
	end
	for _, line in ipairs(tree_lines) do
		written = written + write_live_tree_line("  " .. color("dim", "┆ " .. pad_right("", 10)) .. line)
	end
	return written
end


function ui.live_ast(state, opts)
	opts = opts or {}
	local label = opts.label or "ast"
	if state and type(state.snapshot) == "function" then
		local snapshot = state:snapshot()
		if snapshot then
			live_tree_buffer = {}
			local count
			if opts.final then
				count = render_split_live_tree(snapshot, label)
			else
				count = render_split_live_tree(snapshot, label)
			end
			local output = table.concat(live_tree_buffer)
			live_tree_buffer = nil
			io.write(live_ast_clear_sequence() .. output)
			if opts.live ~= false then
				live_ast_lines = count or 0
			else
				live_ast_lines = 0
			end
			io.flush()
			return
		end
	end
	if not state or not state.render then return end
	local rendered = state:render(opts.render_opts or {})
	if rendered == "" then return end
	local line = "  " .. color("magenta", "▧") .. " " .. color("magenta", pad_right(label, 10)) .. color("dim", truncate_text(rendered:gsub("\n.*$", ""), 100)) .. "\n"
	io.write(live_ast_clear_sequence() .. line)
	local count = 1
	if opts.live ~= false then
		live_ast_lines = count
	else
		live_ast_lines = 0
	end
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
		if opts.wrap and #l > max_width then
			while #l > max_width and #lines < max_lines do
				local cut = max_width
				local space = l:sub(1, max_width):match("^.*()%s")
				if space and space > 24 then
					cut = space - 1
				end
				lines[#lines + 1] = l:sub(1, cut)
				l = l:sub(cut + 1):gsub("^%s+", "")
			end
			if #lines >= max_lines then
				truncated = true
				break
			end
		elseif #l > max_width then
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
		local used = 2 + 1 + 12 + (#plan * 3) + math.max(0, #plan - 1) + 2
		local limit = math.max(96, term_width - used)
		if #compact > limit then
			compact = compact:sub(1, limit - 3) .. "..."
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
local active_tool_statuses = {}

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

local tool_safety_state

local function render_active_tools()
	if not active_tool_timer then return end
	if #active_tool_order == 0 then
		io.write("\r\27[K")
		io.flush()
		return
	end

	active_tool_frame = active_tool_frame + 1
	local first = active_tool_by_id[active_tool_order[1]]
	local elapsed = first and format_duration(now_seconds() - first.started_at) or nil
	local summary = ui.tool_status_summary("running", { live = true })
	local text = "executing batch"
	if elapsed then
		text = text .. "  " .. elapsed
	end
	if summary ~= "" then
		text = text .. "  " .. summary
	end
	local glyph = ACTIVE_GLYPHS[(active_tool_frame % #ACTIVE_GLYPHS) + 1]
	io.write("\r\27[K  " .. color("cyan", glyph) .. " " .. color("cyan", pad_right("tools", 10)) .. color("dim", text))
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
	local group = tool_group(event.name)
	local item = {
		id = id,
		key = key,
		name = event.name,
		group = group,
		desc = desc,
		started_at = now_seconds(),
	}
	active_tool_by_id[id] = item
	active_tool_order[#active_tool_order + 1] = id
	active_tool_queues[key] = active_tool_queues[key] or {}
	active_tool_queues[key][#active_tool_queues[key] + 1] = id
	active_tool_statuses[#active_tool_statuses + 1] = {
		id = id,
		name = event.name,
		group = group,
		status = "running",
	}
	ensure_active_tool_timer()
	return item
end

local function mark_tool_finished(event)
	local key = tool_event_key(event)
	local id = queue_remove_first(active_tool_queues[key])
	local item = id and active_tool_by_id[id] or nil
	local status = "done"
	if tool_safety_state(event) then
		status = "deferred"
	elseif event.result and event.result.is_error then
		status = "failed"
	end
	if not id then
		active_tool_seq = active_tool_seq + 1
		active_tool_statuses[#active_tool_statuses + 1] = {
			id = active_tool_seq,
			name = event.name,
			group = tool_group(event.name),
			status = status,
		}
		return nil
	end
	if id then
		for _, entry in ipairs(active_tool_statuses) do
			if entry.id == id then
				entry.status = status
				break
			end
		end
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
local tool_saved_paths = {}

tool_safety_state = function(event)
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
	if not (event.result and event.result.is_error) and (event.name == "write" or event.name == "edit") and event.args and event.args.path then
		tool_saved_paths[#tool_saved_paths + 1] = tostring(event.args.path)
	end
	if tool_safety_state(event) then
		tool_blocked = tool_blocked + 1
	elseif event.result and event.result.is_error then
		tool_failures = tool_failures + 1
	end
end

local function tool_status_glyph(status)
	if status == "done" then
		return "●", "green"
	elseif status == "failed" then
		return "✕", "red"
	elseif status == "deferred" then
		return "◇", "yellow"
	elseif status == "cancelled" then
		return "·", "dim"
	end
	local glyph = ACTIVE_GLYPHS[(active_tool_frame % #ACTIVE_GLYPHS) + 1] or "◐"
	return glyph, "cyan"
end

local function grouped_tool_statuses()
	local grouped = {}
	local order = {}
	for _, entry in ipairs(active_tool_statuses) do
		local group = entry.group or tool_group(entry.name)
		if not grouped[group] then
			grouped[group] = {}
			order[#order + 1] = group
		end
		grouped[group][#grouped[group] + 1] = entry.status or "running"
	end
	table.sort(order, function(a, b)
		local ar = TOOL_GROUP_RANK[a] or 999
		local br = TOOL_GROUP_RANK[b] or 999
		if ar == br then
			return a < b
		end
		return ar < br
	end)
	return grouped, order
end

function ui.tool_status_summary(_phase, opts)
	opts = opts or {}
	if #active_tool_statuses == 0 then
		return ""
	end
	local grouped, order = grouped_tool_statuses()
	local parts = {}
	local max_groups = opts.max_groups or 8
	for i, group in ipairs(order) do
		if i > max_groups then
			parts[#parts + 1] = "+" .. tostring(#order - max_groups)
			break
		end
		local glyphs = {}
		local max_glyphs = opts.max_glyphs or 12
		local statuses = grouped[group]
		for j, status in ipairs(statuses) do
			if j > max_glyphs then
				glyphs[#glyphs + 1] = color("dim", "+" .. tostring(#statuses - max_glyphs))
				break
			end
			local glyph, glyph_color = tool_status_glyph(status)
			glyphs[#glyphs + 1] = color(glyph_color, glyph)
		end
		parts[#parts + 1] = color("dim", group .. ": ") .. table.concat(glyphs)
	end
	return table.concat(parts, color("dim", "  "))
end

local function compact_saved_paths(paths)
	if #paths == 0 then
		return nil
	end
	local names = {}
	local limit = math.min(#paths, 3)
	for i = 1, limit do
		names[#names + 1] = paths[i]:match("([^/]+)$") or paths[i]
	end
	local suffix = #paths > limit and (" +" .. tostring(#paths - limit)) or ""
	return table.concat(names, ", ") .. suffix
end

local function frame_status(statuses)
	local has_running = false
	local has_deferred = false
	for _, status in ipairs(statuses or {}) do
		if status == "failed" then
			return "failed"
		elseif status == "running" then
			has_running = true
		elseif status == "deferred" then
			has_deferred = true
		end
	end
	if has_running then
		return "running"
	elseif has_deferred then
		return "deferred"
	end
	return "done"
end

local function frame_status_marks(statuses)
	local marks = {}
	local limit = math.min(#statuses, 10)
	for i = 1, limit do
		local glyph, glyph_color = tool_status_glyph(statuses[i])
		marks[#marks + 1] = color(glyph_color, glyph)
	end
	if #statuses > limit then
		marks[#marks + 1] = color("dim", "+" .. tostring(#statuses - limit))
	end
	return table.concat(marks)
end

local function stack_frame_details(frame, entries, saved_paths)
	local count = #entries
	if frame == "write" then
		local saved = compact_saved_paths(saved_paths or {})
		if saved then
			return tostring(#saved_paths) .. " file" .. (#saved_paths == 1 and "" or "s") .. " saved  " .. saved
		end
		return tostring(count) .. " mutation" .. (count == 1 and "" or "s")
	elseif frame == "inspect" then
		local groups = {}
		local seen = {}
		for _, entry in ipairs(entries) do
			if entry.group and not seen[entry.group] then
				seen[entry.group] = true
				groups[#groups + 1] = entry.group
			end
		end
		table.sort(groups, function(a, b)
			return (TOOL_GROUP_RANK[a] or 999) < (TOOL_GROUP_RANK[b] or 999)
		end)
		return tostring(count) .. " lookup" .. (count == 1 and "" or "s") .. (#groups > 0 and ("  " .. table.concat(groups, ", ")) or "")
	elseif frame == "verify" then
		return tostring(count) .. " check" .. (count == 1 and "" or "s")
	elseif frame == "serve" then
		return tostring(count) .. " job action" .. (count == 1 and "" or "s")
	elseif frame == "plan" then
		return tostring(count) .. " update" .. (count == 1 and "" or "s")
	elseif frame == "external" then
		return tostring(count) .. " external call" .. (count == 1 and "" or "s")
	end
	return tostring(count) .. " tool" .. (count == 1 and "" or "s")
end

local function stack_frames()
	local frames = {}
	local order = {}
	for _, entry in ipairs(active_tool_statuses) do
		local frame = stack_frame_for_group(entry.group or tool_group(entry.name))
		if not frames[frame] then
			frames[frame] = { entries = {}, statuses = {} }
			order[#order + 1] = frame
		end
		frames[frame].entries[#frames[frame].entries + 1] = entry
		frames[frame].statuses[#frames[frame].statuses + 1] = entry.status or "running"
	end
	table.sort(order, function(a, b)
		local ar = STACK_FRAME_RANK[a] or 999
		local br = STACK_FRAME_RANK[b] or 999
		if ar == br then
			return a < b
		end
		return ar < br
	end)
	return frames, order
end

local function render_tool_stack(label, saved_paths)
	local frames, order = stack_frames()
	if #order == 0 then return false end
	io.write("  " .. color("dim", "╭─ stack") .. (label and label ~= "" and color("dim", "  " .. label) or "") .. "\n")
	for _, frame in ipairs(order) do
		local data = frames[frame]
		local status = frame_status(data.statuses)
		local glyph, glyph_color = status_glyph(status)
		local marks = frame_status_marks(data.statuses)
		local details = stack_frame_details(frame, data.entries, frame == "write" and saved_paths or nil)
		io.write("  " .. color("dim", "│ ") .. color(glyph_color, glyph) .. " " .. color(glyph_color, pad_right(frame, 10)) .. color("dim", details))
		if marks ~= "" and #data.statuses > 1 then
			io.write(color("dim", "  ") .. marks)
		end
		io.write("\n")
	end
	io.write("  " .. color("dim", "╰─") .. "\n")
	return true
end

local function important_success_output(event)
	local content = tostring(event and event.result and event.result.content or "")
	if content == "" or content == "(no output)" then
		return false
	end
	if #content > 1200 then
		return true
	end
	local lower = content:lower()
	if lower:find("error", 1, true)
		or lower:find("failed", 1, true)
		or lower:find("traceback", 1, true)
		or lower:find("warning", 1, true)
		or lower:find("http://", 1, true)
		or lower:find("https://", 1, true)
		or lower:find("listening", 1, true)
		or lower:find("server", 1, true) then
		return true
	end
	return false
end

local function live_ast_suppresses_tool_event(event)
	if DEBUG or not event then
		return false
	end
	if event.result and event.result.is_error then
		if event.name == "run" or event.name == "shell" then
			return true
		end
		return false
	end
	if tool_safety_state(event) then
		return false
	end
	if event.phase == "start" then
		return event.name ~= "job_start"
	end
	if event.name == "read"
		or event.name == "ls"
		or event.name == "find"
		or event.name == "write"
		or event.name == "edit"
		or event.name == "update_plan" then
		return true
	end
	if event.name == "grep" then
		local content = event.result and event.result.content or ""
		return #tostring(content) <= 800
	end
	if event.name == "run" or event.name == "shell" then
		return not important_success_output(event)
	end
	return false
end

function ui.tool_writes_persistent(event)
	if DEBUG then
		return true
	end
	if not event then
		return false
	end
	if tool_safety_state(event) then
		return true
	end
	if event.result and event.result.is_error then
		return event.name ~= "run" and event.name ~= "shell"
	end
	if live_ast_suppresses_tool_event(event) then
		return false
	end
	if event.phase == "start" then
		return false
	end
	if event.name == "update_plan" and event.result and (event.result.plan or event.result.content) then
		return true
	end
	if event.name == "run" and event.result and event.result.content then
		local content = tostring(event.result.content)
		return content ~= "" and content ~= "(no output)"
	end
	if event.name == "grep" and event.result and event.result.content then
		local content = tostring(event.result.content)
		return content ~= "" and content ~= "(no matches)"
	end
	return false
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
			if live_ast_suppresses_tool_event(event) then
				if event.phase == "start" then
					mark_tool_started(event, render_description(event))
				else
					mark_tool_finished(event)
				end
				return
			end

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
				if event.name == "run" and event.args and event.args.command then
					rail_line("◉", tc, event.name, desc)
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
				if event.name == "update_plan" and event.result and event.result.plan then
					rail_line("◆", tc, event.name, status)
					if event.result.plan_fresh or ui.plan_should_list(event.result.plan) then
						ui.plan_outline(event.result.plan)
					else
						ui.plan_progress(event.result.plan)
					end
				elseif event.name == "update_plan" and event.result and event.result.content then
					rail_line("◆", tc, event.name, status)
					rail_block("plan", event.result.content, { max_lines = 12, max_width = 120, max_bytes = 1600 })
				elseif event.name == "run" and event.result and event.result.content then
					rail_line("◆", tc, event.name, status)
					rail_block("output", event.result.content, { max_lines = 6, max_width = 120, max_bytes = 1200 })
				elseif event.name == "grep" and event.result and event.result.content then
					rail_line("◆", tc, event.name, status)
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
		if tool_failures == 0 and tool_blocked == 0 then
			tool_count = 0
			tool_names = {}
			tool_failures = 0
			tool_blocked = 0
			tool_batch_started_at = nil
			tool_saved_paths = {}
			active_tool_statuses = {}
			return
		end

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
		if DEBUG and #active_tool_statuses > 0 then
			local text = label
			if outcome then
				text = text .. "  " .. outcome
			end
			if elapsed then
				text = text .. "  " .. elapsed
			end
			render_tool_stack(text, tool_saved_paths)
		elseif DEBUG and tool_count > 1 then
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
		tool_saved_paths = {}
		active_tool_statuses = {}
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
		"service tier: " .. (session.service_tier or "priority"),
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
