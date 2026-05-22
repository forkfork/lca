local ui = {}

local DEBUG = os.getenv("LCA_DEBUG") == "1"

local colors = {
	reset = "\27[0m",
	bold = "\27[1m",
	dim = "\27[2m",
	italic = "\27[3m",
	green = "\27[32m",
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
	run    = "magenta",
	shell  = "magenta",
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
}

local function tool_color(name)
	return TOOL_COLORS[name] or "blue"
end

local function tool_verb(name)
	return TOOL_VERBS[name] or "calling"
end

-- ─── ASCII Banner ───────────────────────────────────────────────────────────

local BANNER_SUB = "  lua coding absurdity"

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
	return color("cyan", "\xe2\x9f\xab ")
end

function ui.plain_prompt()
	return "\xe2\x9f\xab "
end

-- ─── Turn Separator ─────────────────────────────────────────────────────────

local turn_number = 0

function ui.turn_separator()
	turn_number = turn_number + 1
	refresh_term_size()
	local w = math.min(term_width, 72)
	local ts = os.date("%H:%M")
	local label = string.format("turn %d \xc2\xb7 %s", turn_number, ts)
	io.write(color("dim", hrule(w, label)) .. "\n\n")
end

-- ─── Thinking / Spinner ─────────────────────────────────────────────────────

local uv = require("luv")

local spinner_timer = nil
local spinner_frame = 0
local streaming_text = false

local WAVE_CHARS = { "\xe2\x96\x91", "\xe2\x96\x92", "\xe2\x96\x93", "\xe2\x96\x88", "\xe2\x96\x93", "\xe2\x96\x92", "\xe2\x96\x91" }
local WAVE_MIN_WIDTH = 28
local WAVE_MAX_WIDTH = 140
local MSG_CAPACITY = 100

-- Gradient stages: blue/green → yellow/orange → red/dark as context fills
local GRADIENT_COOL = { 17, 18, 19, 20, 21, 27, 26, 32, 33, 39, 38, 44, 43, 49, 48, 84, 83, 119, 118, 82, 76, 46, 47, 41, 35, 34, 40, 46 }
local GRADIENT_WARM = { 22, 28, 34, 40, 46, 82, 118, 154, 190, 226, 220, 214, 208, 202, 208, 214, 220, 226, 190, 154, 118, 82, 46, 40, 34, 28, 22, 28 }
local GRADIENT_HOT  = { 52, 88, 124, 160, 196, 202, 208, 214, 220, 226, 220, 214, 208, 202, 196, 160, 124, 88, 52, 88, 124, 160, 196, 202, 196, 160, 124, 88 }

local current_wave_width = WAVE_MIN_WIDTH
local current_context_ratio = 0

local function get_gradient(ratio)
	if ratio < 0.5 then
		return GRADIENT_COOL
	elseif ratio < 0.8 then
		return GRADIENT_WARM
	else
		return GRADIENT_HOT
	end
end

local function render_wave(offset)
	local width = current_wave_width
	local gradient = get_gradient(current_context_ratio)
	local result = {}
	for pos = 1, width do
		local wave_idx = pos - offset
		if wave_idx >= 1 and wave_idx <= #WAVE_CHARS then
			local grad_idx = math.floor((pos - 1) / (width - 1) * (#gradient - 1)) + 1
			local col = gradient[grad_idx]
			table.insert(result, string.format("\27[38;5;%dm%s", col, WAVE_CHARS[wave_idx]))
		else
			table.insert(result, " ")
		end
	end
	table.insert(result, "\27[0m")
	return table.concat(result)
end

local function build_wave_positions(width)
	local positions = {}
	for i = 0, width - #WAVE_CHARS do
		positions[#positions + 1] = i
	end
	for i = width - #WAVE_CHARS - 1, 1, -1 do
		positions[#positions + 1] = i
	end
	return positions
end

local current_wave_positions = build_wave_positions(WAVE_MIN_WIDTH)

local SPINNER_WORDS = {
	"conjuring", "weaving", "dreaming", "summoning",
	"channeling", "invoking", "manifesting", "transmuting",
	"actualizing", "deconstructing", "dialoguing",
}

local spinner_active_flag = false
local last_token_time = 0
local STALL_THRESHOLD = 3.0
local STALL_CHARS = { "·", "•", "●", "•" }

function ui.thinking(message_count)
	spinner_frame = 0
	streaming_text = false
	spinner_active_flag = true
	last_token_time = 0

	if message_count then
		local ratio = math.min(1, message_count / MSG_CAPACITY)
		current_context_ratio = ratio
		current_wave_width = math.floor(WAVE_MIN_WIDTH + (WAVE_MAX_WIDTH - WAVE_MIN_WIDTH) * ratio)
		current_wave_positions = build_wave_positions(current_wave_width)
	end

	if spinner_timer then
		if not spinner_timer:is_closing() then
			spinner_timer:stop()
			spinner_timer:close()
		end
		spinner_timer = nil
	end

	spinner_timer = uv.new_timer()
	spinner_timer:start(0, 40, function()
		if not spinner_active_flag then return end
		spinner_frame = spinner_frame + 1

		-- Stall detection: tokens were flowing but stopped
		if streaming_text and last_token_time > 0 then
			local now = uv.hrtime() / 1e9
			local stalled = now - last_token_time
			if stalled >= STALL_THRESHOLD then
				local pulse = STALL_CHARS[(math.floor(spinner_frame / 8) % #STALL_CHARS) + 1]
				local secs = math.floor(stalled)
				io.write(string.format("\r  \27[2m%s waiting (%ds)\27[0m\27[K", pulse, secs))
				io.flush()
			end
			return
		end

		if streaming_text then return end

		local offset = current_wave_positions[(spinner_frame % #current_wave_positions) + 1]
		local wave = render_wave(offset)
		local w = SPINNER_WORDS[(math.floor(spinner_frame / 30) % #SPINNER_WORDS) + 1]
		io.write(string.format("\r  %s \27[2m%s\27[0m\27[K", wave, w))
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

function ui.stream_stats(tokens, elapsed, ttft)
	local tps = elapsed > 0 and (tokens / elapsed) or 0
	io.write(color("dim", string.format("  (%d tokens, %.1fs, TTFT %.2fs, %.0f tok/s)", tokens, elapsed, ttft, tps)) .. "\n")
end

-- ─── Compaction ─────────────────────────────────────────────────────────────

function ui.compaction(msgs_removed, new_tokens)
	io.write(color("dim", string.format("  [compacted: %d messages summarized, ~%dk tokens retained]", msgs_removed, math.floor(new_tokens / 1000))) .. "\n")
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

function ui.muted(text)
	io.write(color("dim", text) .. "\n")
end

function ui.error(text)
	io.stderr:write(color("red", "  \xe2\x9c\x97 error: ") .. text .. "\n")
end

-- ─── Tool Execution (box-framed, color-coded) ───────────────────────────────

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
		local cmd = args.command
		if #cmd > 140 then cmd = cmd:sub(1, 137) .. "..." end
		return verb .. " `" .. cmd .. "`"
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

-- "Pew pew" tracer: animate a snippet shooting across the screen
local PEW_CHARS = { "⁍", "›", "»", "▸" }
local PEW_COLORS = { 196, 208, 220, 226, 118, 82, 46, 48, 51, 45, 39, 33 }  -- red→orange→yellow→green→cyan→blue

local function render_tracer(event)
	if not event.result then return nil end
	if event.result.is_error then return nil end

	local content

	-- For write/edit, show a snippet of what was written, not the status message
	if (event.name == "write" or event.name == "edit") and event.args then
		local raw = event.args._raw_content or event.args.content
		if raw and raw ~= "" then
			content = raw
		end
	end

	-- For everything else, use the result content
	if not content then
		content = event.result.content
	end

	if not content or content == "" or content == "(no output)" then return nil end

	-- Collapse newlines and multi-spaces into a single line
	local snippet = content:gsub("\n", " "):gsub("%s+", " "):match("^%s*(.-)%s*$")
	if not snippet or #snippet == 0 then return nil end

	-- Truncate to fit
	local max_len = 140
	if #snippet > max_len then
		snippet = snippet:sub(1, max_len - 1) .. "…"
	end
	return snippet
end

local function animate_tracer(prefix, snippet)
	-- Shoot characters across: projectile flies ahead of revealed text
	local chars = {}
	for p, c in utf8.codes(snippet) do
		chars[#chars + 1] = utf8.char(c)
	end

	local total = #chars
	if total == 0 then return end

	-- For short snippets or no-color terminals, just blast it
	if not supports_color() or total < 3 then
		io.write(prefix .. color("dim", "▸ " .. snippet) .. "\n")
		io.flush()
		return
	end

	-- Animate: projectile sweeps across, leaving dim text behind
	local revealed = {}
	local projectile_trail = 3  -- how many bright chars trail the head

	for i = 1, total + projectile_trail do
		io.write("\r\27[K" .. prefix)

		-- Draw revealed chars (dim)
		for j = 1, math.min(i - projectile_trail, total) do
			io.write(color("dim", chars[j]))
		end

		-- Draw projectile trail (bright gradient)
		for t = projectile_trail, 0, -1 do
			local pos = i - t
			if pos >= 1 and pos <= total then
				local col_idx = math.floor((pos - 1) / (total - 1) * (#PEW_COLORS - 1)) + 1
				if total == 1 then col_idx = 1 end
				local col = PEW_COLORS[col_idx]
				if t == 0 then
					-- Head of projectile: bright bullet char
					io.write(string.format("\27[1;38;5;%dm%s\27[0m", col, PEW_CHARS[1]))
				else
					-- Trail: the actual char but bright
					io.write(string.format("\27[38;5;%dm%s\27[0m", col, chars[pos]))
				end
			end
		end

		io.flush()

		local t0 = uv.hrtime()
		while (uv.hrtime() - t0) < 2500000 do end  -- busy-wait 2.5ms per frame
	end

	-- Final state: full snippet in dim
	io.write("\r\27[K" .. prefix .. color("dim", "▸ " .. snippet) .. "\n")
	io.flush()
end

local tool_count = 0
local tool_names = {}

function ui.tool(event)
	if DEBUG then
		io.write(color("cyan", "\xe2\x97\x8f " .. event.name))
		local desc = render_description(event)
		io.write(color("dim", "  " .. desc) .. "\n")
		if event.result and event.result.is_error then
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
		tool_count = tool_count + 1
		table.insert(tool_names, event.name)

		local tc = tool_color(event.name)
		local desc = render_description(event)
		local hint = render_result_hint(event)

		io.write("\r\27[K")

		if event.result and event.result.is_error then
			local msg = event.result.content or ""
			if #msg > 140 then msg = msg:sub(1, 137) .. "..." end
			io.write("  " .. color("dim", box.v) .. " " .. color("red", "\xe2\x9c\x97 " .. event.name) .. color("dim", "  " .. desc) .. "\n")
			io.write("  " .. color("dim", box.v) .. "   " .. color("red", msg) .. "\n")
		else
			local line = "  " .. color("dim", box.v) .. " " .. color(tc, "\xe2\x97\x8f " .. event.name) .. color("dim", "  " .. desc)
			if hint then
				line = line .. color("dim", "  \xe2\x86\x92 " .. hint)
			end
			io.write(line .. "\n")

			-- "Pew pew" tracer: shoot characters across the screen
			local tracer = render_tracer(event)
			if tracer then
				local prefix = "  " .. color("dim", box.v) .. "   "
				animate_tracer(prefix, tracer)
			end
		end
		io.flush()
	end
end

function ui.tool_summary()
	if not DEBUG and tool_count > 0 then
		io.write("\r\27[K")

		refresh_term_size()
		local w = math.min(term_width, 60)

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

		local footer_inner = " " .. label .. " (" .. tools_used .. ") "
		local footer_len = #footer_inner
		local remaining = w - 3 - footer_len - 1
		if remaining < 2 then remaining = 2 end

		io.write(color("dim", "  " .. box.bl .. box.h:rep(1) .. footer_inner .. box.h:rep(remaining) .. box.br) .. "\n")
		tool_count = 0
		tool_names = {}
	end
end

function ui.tool_header()
	if not DEBUG then
		refresh_term_size()
		local w = math.min(term_width, 60)
		io.write(color("dim", "  " .. box.tl .. box.h:rep(w - 3) .. box.tr) .. "\n")
	end
end

-- ─── Status Display ─────────────────────────────────────────────────────────

local function context_bar(tokens, max_tokens)
	local bars = { "\xe2\x96\x81", "\xe2\x96\x82", "\xe2\x96\x83", "\xe2\x96\x84", "\xe2\x96\x85", "\xe2\x96\x86", "\xe2\x96\x87", "\xe2\x96\x88" }
	local ratio = math.min(tokens / max_tokens, 1.0)
	local idx = math.floor(ratio * (#bars - 1)) + 1
	local bar_color = ratio < 0.5 and "green" or (ratio < 0.8 and "yellow" or "red")
	return color(bar_color, bars[idx])
end

function ui.status(session)
	local compaction_mod = require("agent.compaction")
	local tokens = compaction_mod.estimate_total(session.messages)
	refresh_term_size()
	local w = math.min(term_width, 60)

	io.write(color("dim", box.tl .. hrule(w - 2, "status") .. box.tr) .. "\n")
	local lines = {
		"model: " .. session.model,
		"reasoning: " .. (session.reasoning_effort or "default"),
		"cwd: " .. session.cwd,
		"credentials: " .. session.credentials_path,
		"turns: " .. session:turn_count(),
		"context: ~" .. math.floor(tokens / 1000) .. "k tokens (" .. #session.messages .. " messages) " .. context_bar(tokens, 200000),
		"compacted: " .. (session.compaction_summary and "yes" or "no"),
	}
	for _, l in ipairs(lines) do
		io.write(color("dim", box.v) .. " " .. l .. "\n")
	end
	io.write(color("dim", box.bl .. box.h:rep(w - 2) .. box.br) .. "\n")
end

return ui
