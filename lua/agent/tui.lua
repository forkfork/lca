local commands = require("agent.commands")
local compaction = require("agent.compaction")
local context_limits = require("agent.context_limits")
local core = require("agent.core")
local jobs = require("agent.jobs")
local protocol = require("agent.tool_protocol")
local session_module = require("agent.session")
local socket = require("socket")
local uv = require("luv")
local lcatui = require("lcatui")

local tui = {}

local function clamp(value, low, high)
	return math.max(low, math.min(high, value))
end

local function rgb(r, g, b, attrs)
	return { fg = { r, g, b }, attrs = attrs or {} }
end

local function compact_text(value, limit)
	value = tostring(value or ""):gsub("\r", " "):gsub("\n", " "):gsub("%s+", " ")
	value = value:gsub("^%s+", ""):gsub("%s+$", "")
	limit = limit or 72
	if #value > limit then value = value:sub(1, limit - 3) .. "..." end
	return value
end

local function basename(value)
	value = tostring(value or "")
	return value:match("([^/]+)$") or value
end

local function compact_args(name, args)
	args = args or {}
	if args.path then
		local text = basename(args.path)
		if name == "read" and (args.offset or args.limit) then
			text = text .. " " .. tostring(args.offset or 1) .. ":" .. tostring(args.limit or "end")
		end
		return compact_text(text, 42)
	elseif args.command then
		return compact_text(args.command, 48)
	elseif args.pattern then
		return compact_text("/" .. tostring(args.pattern) .. "/ " .. tostring(args.path or "."), 44)
	elseif args.id then
		return compact_text(args.id, 36)
	elseif name == "update_plan" and type(args.plan) == "table" then
		return tostring(#args.plan) .. " steps"
	end
	return ""
end

local function event_key(event)
	local args = event.args or {}
	return table.concat({
		tostring(event.name or ""), tostring(args.path or ""), tostring(args.command or ""),
		tostring(args.pattern or ""), tostring(args.id or ""),
	}, "\0")
end

local State = {}
State.__index = State

function State.new(opts)
	opts = opts or {}
	return setmetatable({
		mode = "listening",
		model_phase = "waiting for input",
		prompt = "",
		assistant = "",
		assistant_stream = "",
		assistant_started_at = nil,
		assistant_updated_at = nil,
		assistant_completed_at = nil,
		notices = {},
		plan = nil,
		tools = {},
		tools_by_id = {},
		tool_queues = {},
		tool_sequence = 0,
		failure = nil,
		verification = nil,
		disturbance = 0,
		proof = 0,
		cancelled = false,
		input = "",
		cursor = 0,
		clock = opts.clock or socket.gettime,
	}, State)
end

function State:notice(text, kind)
	self.notices[#self.notices + 1] = { text = compact_text(text, 180), kind = kind or "info" }
	while #self.notices > 4 do table.remove(self.notices, 1) end
end

function State:set_input(text, cursor)
	self.input = tostring(text or "")
	self.cursor = tonumber(cursor) or lcatui.width.string(self.input)
end

function State:submit(text)
	self.prompt = compact_text(text, 240)
	self.assistant_stream = ""
	self.failure = nil
	self.verification = nil
	self.disturbance = 0
	self.proof = 0
	self.cancelled = false
	self.mode = "waiting"
	self.model_phase = "model waiting"
end

function State:model_waiting(label)
	self.mode = "waiting"
	self.model_phase = label or "model waiting"
	self.assistant_stream = ""
end

function State:model_stream(text)
	if not text or text == "" then return end
	local now = self.clock()
	if self.assistant_stream == "" then self.assistant_started_at = now end
	self.assistant_updated_at = now
	self.assistant_completed_at = nil
	self.mode = "streaming"
	self.model_phase = "assistant streaming"
	self.assistant_stream = self.assistant_stream .. text
	if #self.assistant_stream > 1200 then
		self.assistant_stream = self.assistant_stream:sub(-1200)
	end
end

function State:reviewing(info)
	self.mode = "reviewing"
	self.model_phase = compact_text(info and info.status or "reviewing tool results", 80)
end

function State:_resolve_tool(event)
	local id = event.call_id and tostring(event.call_id) or nil
	if id and self.tools_by_id[id] then return self.tools_by_id[id] end
	local queue = self.tool_queues[event_key(event)]
	if queue and #queue > 0 then return queue[1] end
	return nil
end

function State:tool_event(event)
	if not event or not event.name then return nil end
	local tool
	if event.phase == "start" then
		self.tool_sequence = self.tool_sequence + 1
		local id = tostring(event.call_id or ("tool-" .. tostring(self.tool_sequence)))
		tool = {
			id = id,
			name = tostring(event.name),
			args = compact_args(event.name, event.args),
			status = "active",
			started_at = self.clock(),
		}
		self.tools[#self.tools + 1] = tool
		self.tools_by_id[id] = tool
		local key = event_key(event)
		self.tool_queues[key] = self.tool_queues[key] or {}
		self.tool_queues[key][#self.tool_queues[key] + 1] = tool
	else
		tool = self:_resolve_tool(event)
		if not tool then
			self.tool_sequence = self.tool_sequence + 1
			local id = tostring(event.call_id or ("tool-" .. tostring(self.tool_sequence)))
			tool = { id = id, name = tostring(event.name), args = compact_args(event.name, event.args), started_at = self.clock() }
			self.tools[#self.tools + 1] = tool
			self.tools_by_id[id] = tool
		end
		tool.result = compact_text(event.result and (event.result.summary or event.result.content) or "done", 76)
		tool.status = event.result and event.result.is_error and "error"
			or (event.result and event.result.ui_state == "deferred" and "deferred" or "ok")
		tool.finished_at = self.clock()
		local queue = self.tool_queues[event_key(event)]
		if queue then
			for index, queued in ipairs(queue) do
				if queued == tool then table.remove(queue, index); break end
			end
		end
		if event.name == "update_plan" and event.result and type(event.result.plan) == "table" then
			self.plan = event.result.plan
		end
		if event.name == "run" or event.name == "shell" then
			if event.result and event.result.is_error then
				self.failure = tool.result ~= "" and tool.result or "command failed"
				self.verification = nil
				self.disturbance = 1
				self.proof = 0
				self.mode = "failed"
			else
				self.verification = tool.result ~= "" and tool.result or "verification passed"
				self.failure = nil
				self.disturbance = 0
				self.proof = 1
				self.mode = "verified"
			end
		end
	end
	if event.phase == "start" then self.mode = "tools" end
	self.model_phase = event.phase == "start" and "tools active" or "reviewing results"
	while #self.tools > 18 do
		local removed = table.remove(self.tools, 1)
		if removed.status ~= "active" then self.tools_by_id[removed.id] = nil end
	end
	return tool
end

function State:assistant_complete(text)
	self.assistant = compact_text(text, 1600)
	self.assistant_stream = ""
	self.assistant_completed_at = self.clock()
	self.mode = "complete"
	self.model_phase = "assistant complete"
end

function State:cancel(reason)
	self.cancelled = true
	self.mode = "cancelled"
	self.model_phase = compact_text(reason or "cancelled", 80)
	for _, tool in ipairs(self.tools) do
		if tool.status == "active" then tool.status = "cancelled" end
	end
end

function State:listen()
	self.mode = "listening"
	self.model_phase = "listening"
	self.disturbance = 0
end

function State:active_tools()
	local result = {}
	for _, tool in ipairs(self.tools) do
		if tool.status == "active" then result[#result + 1] = tool end
	end
	return result
end

tui.State = State

local Editor = {}
Editor.__index = Editor

function Editor.new(history)
	return setmetatable({ chars = {}, cursor = 0, history = history or {}, history_index = nil, saved = "" }, Editor)
end

function Editor:text() return table.concat(self.chars) end
function Editor:display_cursor()
	local prefix = {}
	for i = 1, self.cursor do prefix[#prefix + 1] = self.chars[i] end
	return lcatui.width.string(table.concat(prefix))
end
function Editor:set(value)
	self.chars = lcatui.width.chars(value or "")
	self.cursor = #self.chars
end
function Editor:insert(char)
	table.insert(self.chars, self.cursor + 1, char)
	self.cursor = self.cursor + 1
end
function Editor:backspace()
	if self.cursor > 0 then table.remove(self.chars, self.cursor); self.cursor = self.cursor - 1 end
end
function Editor:delete()
	if self.cursor < #self.chars then table.remove(self.chars, self.cursor + 1) end
end
function Editor:history_move(delta)
	if #self.history == 0 then return end
	if not self.history_index then
		self.saved = self:text()
		self.history_index = #self.history + 1
	end
	self.history_index = clamp(self.history_index + delta, 1, #self.history + 1)
	self:set(self.history_index == #self.history + 1 and self.saved or self.history[self.history_index])
end
function Editor:submit()
	local value = self:text():gsub("^%s+", ""):gsub("%s+$", "")
	if value ~= "" and self.history[#self.history] ~= value then self.history[#self.history + 1] = value end
	self.chars, self.cursor, self.history_index, self.saved = {}, 0, nil, ""
	return value
end

tui.Editor = Editor

local Input = {}
Input.__index = Input

local ESCAPES = {
	["\27[A"] = "up", ["\27[B"] = "down", ["\27[C"] = "right", ["\27[D"] = "left",
	["\27[H"] = "home", ["\27[F"] = "end", ["\27[1~"] = "home", ["\27[4~"] = "end",
	["\27[3~"] = "delete", ["\27[200~"] = "paste_start",
}

local function escape_prefix(value)
	for sequence in pairs(ESCAPES) do
		if sequence:sub(1, #value) == value then return true end
	end
	return ("\27[201~"):sub(1, #value) == value
end

local function utf8_sequence_length(byte)
	if byte < 0x80 then return 1 end
	if byte >= 0xC2 and byte <= 0xDF then return 2 end
	if byte >= 0xE0 and byte <= 0xEF then return 3 end
	if byte >= 0xF0 and byte <= 0xF4 then return 4 end
	return 1
end

function Input.new(editor)
	return setmetatable({ editor = editor, buffer = "", paste = false, paste_buffer = "" }, Input)
end

function Input:_action(name, busy)
	local editor = self.editor
	if name == "up" then editor:history_move(-1)
	elseif name == "down" then editor:history_move(1)
	elseif name == "left" then editor.cursor = math.max(0, editor.cursor - 1)
	elseif name == "right" then editor.cursor = math.min(#editor.chars, editor.cursor + 1)
	elseif name == "home" then editor.cursor = 0
	elseif name == "end" then editor.cursor = #editor.chars
	elseif name == "delete" then editor:delete()
	elseif name == "paste_start" then self.paste = true; self.paste_buffer = "" end
	return nil
end

function Input:feed(byte, busy)
	if not byte or byte == "" then return nil end
	if self.paste then
		self.paste_buffer = self.paste_buffer .. byte
		local end_at = self.paste_buffer:find("\27[201~", 1, true)
		if end_at then
			local content = self.paste_buffer:sub(1, end_at - 1):gsub("[\r\n]+", " ")
			for _, char in ipairs(lcatui.width.chars(content)) do self.editor:insert(char) end
			self.paste, self.paste_buffer = false, ""
		end
		return nil
	end

	self.buffer = self.buffer .. byte
	if self.buffer:sub(1, 1) == "\27" then
		local action = ESCAPES[self.buffer]
		if action then self.buffer = ""; return self:_action(action, busy) end
		if escape_prefix(self.buffer) and #self.buffer < 8 then return nil end
		self.buffer = ""
		return nil
	end

	local first = self.buffer:byte(1)
	if first == 3 then self.buffer = ""; return { type = busy and "cancel" or "exit" } end
	if first == 4 then
		self.buffer = ""
		if #self.editor.chars == 0 then return { type = "exit" } end
		self.editor:delete(); return nil
	end
	if first == 1 then self.buffer = ""; self.editor.cursor = 0; return nil end
	if first == 5 then self.buffer = ""; self.editor.cursor = #self.editor.chars; return nil end
	if first == 8 or first == 127 then self.buffer = ""; self.editor:backspace(); return nil end
	if first == 10 or first == 13 then
		self.buffer = ""
		return { type = "submit", text = self.editor:submit() }
	end
	if first < 32 then self.buffer = ""; return nil end

	local needed = utf8_sequence_length(first)
	if #self.buffer < needed then return nil end
	local char = self.buffer:sub(1, needed)
	self.buffer = self.buffer:sub(needed + 1)
	local ok = pcall(utf8.len, char)
	if ok then self.editor:insert(char) end
	return nil
end

tui.Input = Input

local StreamFilter = {}
StreamFilter.__index = StreamFilter

function StreamFilter.new()
	return setmetatable({ buffer = "", hidden = nil, saw_tool = false }, StreamFilter)
end

function StreamFilter:feed(delta)
	if self.saw_tool then return "" end
	self.buffer = self.buffer .. tostring(delta or "")
	local visible = {}
	while #self.buffer > 0 do
		if self.hidden then
			local close_tag = self.hidden == "tool" and "</tool_call>" or "</thinking>"
			local at = self.buffer:find(close_tag, 1, true)
			if not at then
				self.buffer = self.buffer:sub(-math.min(#self.buffer, #close_tag - 1))
				break
			end
			self.buffer = self.buffer:sub(at + #close_tag)
			if self.hidden == "tool" then self.saw_tool = true; self.buffer = ""; break end
			self.hidden = nil
		else
			local tool_at = self.buffer:find("<tool_call", 1, true)
			local thinking_at = self.buffer:find("<thinking", 1, true)
			local at, kind
			if tool_at and (not thinking_at or tool_at < thinking_at) then at, kind = tool_at, "tool"
			elseif thinking_at then at, kind = thinking_at, "thinking" end
			if at then
				visible[#visible + 1] = self.buffer:sub(1, at - 1)
				self.buffer = self.buffer:sub(at)
				self.hidden = kind
			else
				local keep = math.min(#self.buffer, 16)
				visible[#visible + 1] = self.buffer:sub(1, #self.buffer - keep)
				self.buffer = self.buffer:sub(#self.buffer - keep + 1)
				break
			end
		end
	end
	return table.concat(visible)
end

function StreamFilter:finish()
	if self.hidden or self.saw_tool then return "" end
	local value = self.buffer
	self.buffer = ""
	return value
end

local function tool_position(id, width, world_top, world_bottom)
	local hash = 2166136261
	for index = 1, #id do hash = ((hash ~ id:byte(index)) * 16777619) & 0xffffffff end
	local usable_width = math.max(20, width - 24)
	local usable_height = math.max(3, world_bottom - world_top)
	return 3 + (hash % usable_width), world_top + ((hash >> 8) % usable_height)
end

local function center(buffer, row, text, style)
	local col = math.max(1, math.floor((buffer.width - lcatui.width.string(text)) / 2) + 1)
	buffer:write(row, col, text, style, buffer.width - col + 1)
end

local function response_lines(text, width, maximum_lines)
	local limit = math.max(24, math.min(96, width - 20))
	local words, lines, line = {}, {}, ""
	for word in compact_text(text, limit * maximum_lines):gmatch("%S+") do words[#words + 1] = word end
	for _, word in ipairs(words) do
		local candidate = line == "" and word or (line .. " " .. word)
		if lcatui.width.string(candidate) <= limit then
			line = candidate
		else
			if line ~= "" then lines[#lines + 1] = line end
			line = lcatui.width.truncate(word, limit)
			if #lines == maximum_lines then break end
		end
	end
	if line ~= "" and #lines < maximum_lines then lines[#lines + 1] = line end
	if #lines == maximum_lines and #table.concat(lines, " ") < #compact_text(text, limit * maximum_lines) then
		lines[#lines] = lcatui.width.truncate(lines[#lines], limit - 1) .. "…"
	end
	return lines
end

local App = {}
App.__index = App

function App.new(opts)
	opts = opts or {}
	local backend = opts.backend or lcatui.backends.posix.new()
	return setmetatable({
		backend = backend,
		terminal = opts.terminal or lcatui.Terminal.new(backend),
		renderer = opts.renderer or lcatui.Renderer.new(backend, {
			mode = "inline",
			synchronized = true,
			damage_spans = true,
			damage_gap = 4,
		}),
		state = opts.state or State.new(),
		editor = opts.editor or Editor.new(opts.history),
		input = nil,
		flow = nil,
		flow_width = nil,
		flow_height = nil,
		flow_time = 0,
		response_entities = nil,
		response_key = nil,
		size_provider = opts.size_provider,
		logged_size = nil,
		logged_layout = nil,
		last_frame = socket.gettime(),
		next_frame_at = nil,
		last_resize = 0,
		frame_timer = nil,
		stdin_poll = nil,
		exit_requested = false,
		cancel_requested = false,
		submitted = {},
		busy = false,
		fatal_error = nil,
	}, App)
end

function App:_size()
	local now = socket.gettime()
	if self.backend.refresh_size and now - self.last_resize >= 0.5 then
		self.backend:refresh_size()
		self.last_resize = now
	end
	local width, height = self.backend:size()
	local backend_width, backend_height = width, height
	if self.size_provider then
		local measured_width, measured_height = self.size_provider()
		if measured_width and measured_height then width, height = measured_width, measured_height end
	end
	width, height = math.max(40, tonumber(width) or 80), math.max(12, tonumber(height) or 24)
	local size_key = table.concat({ tostring(backend_width), tostring(backend_height), tostring(width), tostring(height) }, ":")
	if size_key ~= self.logged_size then
		core.debug_log("[tui] terminal backend=%sx%s effective=%sx%s", tostring(backend_width), tostring(backend_height), tostring(width), tostring(height))
		self.logged_size = size_key
	end
	return width, height
end

function App:_flow_for(width, rows)
	if not self.flow or self.flow_width ~= width or self.flow_height ~= rows then
		self.flow = lcatui.Current.new(width, rows, { seed = 19 })
		self.flow_width, self.flow_height = width, rows
		self.flow_time = 0
	end
	return self.flow
end

function App:_response_for(text, width, world_rows)
	local lines = response_lines(text, width, 3)
	local key = table.concat(lines, "\n") .. "\0" .. tostring(width) .. "x" .. tostring(world_rows)
	if key ~= self.response_key then
		local entities = {}
		local first_row = math.max(4, math.floor(world_rows * 0.50) - math.floor((#lines - 1) / 2))
		for index, line in ipairs(lines) do
			local col = math.max(3, math.floor((width - lcatui.width.string(line)) / 2) + 1)
			local scattered = lcatui.kinetic.scatter(line, first_row + index - 1, col, {
				width = width, height = world_rows,
			}, 47 + index * 19)
			for _, entity in ipairs(scattered) do entities[#entities + 1] = entity end
		end
		self.response_key, self.response_entities = key, entities
	end
	return self.response_entities, lines
end

function App:render(frame_dt)
	local width, height = self:_size()
	local dock_top = height - 3
	local world_rows = dock_top - 1
	local assistant = self.state.assistant_stream ~= "" and self.state.assistant_stream or self.state.assistant
	local response_visible = assistant ~= "" and (self.state.mode == "streaming"
		or self.state.mode == "complete" or self.state.mode == "listening")
	local notice = self.state.notices[#self.state.notices]
	local top_reserved = 1
	if self.state.prompt ~= "" then top_reserved = top_reserved + 1 end
	if assistant ~= "" then top_reserved = top_reserved + 1 end
	if notice then top_reserved = top_reserved + 1 end
	local world_top = math.min(math.max(2, world_rows - 1), top_reserved + 2)
	local flow = self:_flow_for(width, world_rows)
	local now = socket.gettime()
	local dt = frame_dt == nil and clamp(now - self.last_frame, 0, 0.1) or frame_dt
	self.last_frame = now
	self.flow_time = self.flow_time + dt
	local listening = self.state.mode == "listening"
	local listening_breath = listening and (0.5 + 0.5 * math.sin(self.flow_time * 1.7)) or 0
	local failed = self.state.disturbance > 0
	local active = not listening and self.state.mode ~= "complete" and self.state.mode ~= "cancelled"
	local vortices = {}
	for _, tool in ipairs(self.state.tools) do
		if tool.status == "active" or (tool.finished_at and now - tool.finished_at < 3.5) then
			local x, y = tool_position(tool.id, width, world_top, math.max(world_top, world_rows - 1))
			vortices[#vortices + 1] = {
				x = x, y = y, radius = tool.status == "active" and 9 or 5,
				strength = tool.status == "active" and 1.25 or 0.28,
				direction = (#tool.id % 2 == 0) and -1 or 1,
			}
		end
	end
	if failed then
		vortices[#vortices + 1] = { x = width * 0.5, y = world_rows * 0.5, radius = 15, strength = 1.7, direction = -1 }
	end
	flow:step(dt, {
		activity = active and 0.88 or listening and (0.19 + listening_breath * 0.08) or 0.18,
		active = active,
		listening = listening,
		failed = failed,
		breath = listening_breath,
		center_x = width * 0.5,
		center_y = listening and world_rows * 0.72 or world_rows * 0.47,
		vortices = vortices,
	})

	local field_style = self.state.proof > 0 and rgb(62, 205, 153)
		or failed and rgb(205, 66, 101)
		or listening and rgb(55, 151, 157)
		or active and rgb(132, 69, 171)
		or rgb(46, 105, 112)
	local buffer = lcatui.Buffer.new(width, height)
	buffer:fill(top_reserved + 1, 1, world_rows - 1, width, " ", field_style)
	flow:render(buffer, {
		active = active,
		listening = listening,
		failed = failed,
		proof = self.state.proof,
		core_x = width * 0.5,
		core_y = world_rows * 0.47,
		threshold = 0.13,
		style = field_style,
		mask = function(_, y)
			if not (y > top_reserved and y < world_rows) then return false end
			if response_visible and math.abs(y - world_rows * 0.50) < 3.2 then return false end
			return true
		end,
	})

	buffer:write(1, 2, "LCA · " .. self.state.model_phase, rgb(98, 222, 218, { "bold" }), width - 2)
	local header_row = 2
	if self.state.prompt ~= "" then
		buffer:write(header_row, 2, "last request · " .. compact_text(self.state.prompt, width - 17), rgb(110, 132, 151), width - 2)
		header_row = header_row + 1
	end
	if assistant ~= "" then
		buffer:write(header_row, 2, "assistant · " .. compact_text(assistant, width - 15), rgb(221, 217, 231), width - 2)
		header_row = header_row + 1
	end
	if notice then
		buffer:write(header_row, 2, compact_text(notice.text, width - 3), notice.kind == "error" and rgb(241, 79, 115) or rgb(95, 135, 143), width - 2)
	end

	local shown = 0
	for index = #self.state.tools, 1, -1 do
		local tool = self.state.tools[index]
		if shown >= 10 then break end
		if tool.status == "active" or (tool.finished_at and now - tool.finished_at < 5) then
			local x, y = tool_position(tool.id, width, world_top, math.max(world_top, world_rows - 1))
			local glyph = tool.status == "active" and ({ "◜", "◝", "◞", "◟" })[math.floor(now * 9 + shown) % 4 + 1]
				or tool.status == "ok" and "◆" or tool.status == "error" and "×" or "◇"
			local style = tool.status == "error" and rgb(241, 79, 115, { "bold" })
				or tool.status == "ok" and rgb(91, 224, 169, { "bold" }) or rgb(72, 221, 228, { "bold" })
			local label = glyph .. " " .. tool.name .. (tool.args ~= "" and ("  " .. tool.args) or "")
			buffer:write(y, x, label, style, math.max(1, width - x))
			if tool.status ~= "active" and tool.result ~= "" and y + 1 < dock_top then
				buffer:write(y + 1, x + 2, compact_text(tool.result, 42), rgb(105, 143, 145), math.max(1, width - x - 2))
			end
			shown = shown + 1
		end
	end

	if self.state.failure then
		center(buffer, math.max(world_top, math.floor(world_rows * 0.52)), "× " .. compact_text(self.state.failure, width - 12), rgb(241, 79, 115, { "bold" }))
	elseif self.state.verification then
		center(buffer, math.max(world_top, math.floor(world_rows * 0.52)), "◆ " .. compact_text(self.state.verification, width - 12), rgb(91, 224, 169, { "bold" }))
	elseif self.state.cancelled then
		center(buffer, math.max(world_top, math.floor(world_rows * 0.52)), "cancelled", rgb(218, 158, 93, { "bold" }))
	end

	if type(self.state.plan) == "table" and #self.state.plan > 0 then
		local row = math.max(world_top, world_rows - math.min(3, #self.state.plan) - 1)
		for index, item in ipairs(self.state.plan) do
			if index > 3 then break end
			local mark = item.status == "completed" and "✓" or item.status == "in_progress" and "◉" or "○"
			buffer:write(row + index - 1, 3, mark .. " " .. compact_text(item.step, math.floor(width * 0.42)), rgb(144, 119, 178), math.floor(width * 0.45))
		end
	end

	if response_visible then
		local entities = self:_response_for(assistant, width, world_rows)
		local response_now = self.state.clock()
		local started = self.state.mode == "streaming" and self.state.assistant_updated_at
			or self.state.assistant_completed_at or self.state.assistant_started_at or response_now
		local settle = clamp((response_now - started) / 1.25, 0, 1)
		lcatui.kinetic.draw(buffer, entities, settle, {
			style = function(_, amount)
				return rgb(122 + math.floor(amount * 104), 171 + math.floor(amount * 48),
					176 + math.floor(amount * 55), { amount > 0.88 and "bold" or "dim" })
			end,
		})
	end

	buffer:write(dock_top, 1, string.rep("─", width), rgb(49, 65, 76), width)
	buffer:write(dock_top + 1, 2, "input › ", rgb(105, 222, 222, { "bold" }), width - 2)
	buffer:write(dock_top + 1, 10, self.editor:text(), rgb(224, 219, 229), width - 10)
	local status = self.busy and "working · Ctrl-C cancels · input may be queued"
		or "listening · Enter submits · Ctrl-D exits"
	buffer:write(dock_top + 2, 2, status, rgb(74, 93, 105), width - 2)
	self.state:set_input(self.editor:text(), self.editor:display_cursor())
	local cursor_col = math.min(width, 10 + self.editor:display_cursor())
	local cursor_cell = buffer.rows[dock_top + 1][cursor_col]
	local cursor_style = cursor_cell.style or rgb(224, 219, 229)
	cursor_cell.style = { fg = cursor_style.fg, bg = cursor_style.bg, attrs = { "reverse" } }
	local layout_key = table.concat({ width, height, dock_top, world_rows }, ":")
	if layout_key ~= self.logged_layout then
		core.debug_log("[tui] frame=%sx%s world_rows=%s divider_row=%s input_row=%s status_row=%s",
			width, height, world_rows, dock_top, dock_top + 1, dock_top + 2)
		self.logged_layout = layout_key
	end
	self.renderer:set_cursor(nil):draw(buffer)
end

function App:_handle_action(action)
	if not action then return end
	if action.type == "exit" then self.exit_requested = true
	elseif action.type == "cancel" then self.cancel_requested = true; self.state:cancel("cancelling")
	elseif action.type == "submit" then
		if action.text ~= "" then self.submitted[#self.submitted + 1] = action.text end
	end
end

function App:start_io()
	self.input = Input.new(self.editor)
	self:render(1 / 30)
	self.next_frame_at = socket.gettime() + 1 / 30
	self.stdin_poll = uv.new_poll(0)
	self.stdin_poll:start("r", function()
		local byte = self.backend:read_byte()
		self:_handle_action(self.input:feed(byte, self.busy))
	end)
end

function App:stop_io()
	for _, handle in ipairs({ self.stdin_poll }) do
		if handle and not handle:is_closing() then handle:stop(); handle:close() end
	end
	self.stdin_poll, self.frame_timer = nil, nil
	uv.run("nowait")
end

function App:drive_frame()
	local now = socket.gettime()
	if not self.next_frame_at or now >= self.next_frame_at then
		local ok, err = pcall(function() self:render(1 / 30) end)
		if not ok then self.fatal_error = err; self.exit_requested = true end
		local finished = socket.gettime()
		self.next_frame_at = (self.next_frame_at or now) + 1 / 30
		while self.next_frame_at <= finished do self.next_frame_at = self.next_frame_at + 1 / 30 end
	end
end

function App:pump()
	uv.run("nowait")
	self:drive_frame()
	if self.fatal_error then error(self.fatal_error) end
end

function App:next_submission()
	while #self.submitted == 0 and not self.exit_requested do
		uv.run("nowait")
		self:drive_frame()
		if self.fatal_error then error(self.fatal_error) end
		uv.sleep(2)
	end
	if self.exit_requested then return nil end
	return table.remove(self.submitted, 1)
end

tui.App = App

function tui.with_terminal(terminal, renderer, callback)
	local started, start_err = terminal:start({ raw = true })
	if not started then return nil, start_err or "TUI requires an interactive POSIX terminal" end
	local mounted, mount_err = pcall(function()
		renderer:mount("inline")
		renderer:switch("fullscreen")
	end)
	if not mounted then
		pcall(function() terminal:stop() end)
		return nil, mount_err
	end
	local results = table.pack(xpcall(callback, debug.traceback))
	pcall(function() renderer.backend:write(lcatui.ansi.end_synchronized_update) end)
	pcall(function() renderer:unmount() end)
	pcall(function() terminal:stop() end)
	if not results[1] then return nil, results[2] end
	return table.unpack(results, 2, results.n)
end

local function load_history(path)
	local history = {}
	local file = io.open(path, "r")
	if not file then return history end
	for line in file:lines() do if line ~= "" then history[#history + 1] = line end end
	file:close()
	while #history > 1000 do table.remove(history, 1) end
	return history
end

local function save_history(path, history)
	local file = io.open(path, "w")
	if not file then return end
	for _, line in ipairs(history) do file:write(tostring(line):gsub("[\r\n]+", " ") .. "\n") end
	file:close()
end

local function command_ui(state)
	local facade = {}
	function facade.muted(text) state:notice(text) end
	function facade.error(text) state:notice("error: " .. tostring(text), "error") end
	function facade.block(text) state:notice(text) end
	function facade.compaction(removed, tokens) state:notice("compacted " .. tostring(removed) .. " messages; ~" .. tostring(math.floor((tokens or 0) / 1000)) .. "k tokens remain") end
	function facade.status(session) state:notice("model " .. tostring(session.model) .. " · " .. tostring(session:turn_count()) .. " turns · " .. tostring(session:token_status())) end
	function facade.plan(plan) state.plan = plan; state:notice(tostring(#(plan or {})) .. " plan steps") end
	function facade.jobs(list) state:notice(tostring(#(list or {})) .. " background jobs") end
	function facade.job_detail(job) state:notice((job and job.id or "job") .. " · " .. tostring(job and job.status or "unknown")) end
	function facade.job_output(id, output) state:notice(tostring(id) .. " · " .. compact_text(output, 150)) end
	return facade
end

function tui.run(options)
	options = options or {}
	local history_path = options.history_path or ".lca-history"
	local session = options.session or session_module.create(options)
	local app = App.new({
		backend = options.backend,
		terminal = options.terminal,
		renderer = options.renderer,
		history = load_history(history_path),
	})
	local facade = command_ui(app.state)
	local last_auto_compact_messages = 0
	local function auto_save()
		if #session.messages > 0 then
			local ok, err = session:save()
			if not ok then app.state:notice("auto-save failed: " .. tostring(err), "error") end
		end
	end
	local function maybe_auto_compact()
		local threshold = context_limits.auto_compact_threshold(session.model)
		if threshold <= 0 or #session.messages - last_auto_compact_messages < 10 then return end
		if session:estimated_model_input_tokens_usage_aware() < threshold then return end
		local ok, compacted = pcall(function() return compaction.compact(session, { bypass_threshold = true }) end)
		if ok and compacted then last_auto_compact_messages = #session.messages; app.state:notice("session compacted") end
	end

	local result, err = tui.with_terminal(app.terminal, app.renderer, function()
		local loaded, load_err = session:load()
		if loaded then app.state:notice(session:load_message())
		elseif load_err and not tostring(load_err):lower():find("no such file", 1, true) then app.state:notice(load_err, "error") end
		last_auto_compact_messages = #session.messages
		jobs.prune(session.cwd)
		if options.mcp_tool_count and options.mcp_tool_count > 0 then app.state:notice(tostring(options.mcp_tool_count) .. " MCP tools connected") end
		app:start_io()
		while not app.exit_requested do
			app.state:listen()
			local line = app:next_submission()
			if not line then break end
			if line:sub(1, 1) == "/" then
				local command_result = commands.dispatch(line, session, facade)
				if command_result == true then break end
				if command_result ~= "run" then goto continue end
				line = ""
			else
				session:add_user(line)
			end
			if line ~= "" or session.messages[#session.messages] then
				app.state:submit(line ~= "" and line or "command request")
				app.busy, app.cancel_requested = true, false
				local filter = StreamFilter.new()
				local ok, turn_result = pcall(function()
					return core.run_session(session,
						function(delta)
							local visible = filter:feed(delta)
							if visible ~= "" then app.state:model_stream(visible) end
							app:pump()
						end,
						function(event) app.state:tool_event(event); app:render() end,
						function(info) app.state:reviewing(info); filter = StreamFilter.new(); app:render() end,
						function() app:pump() end,
						{ cancelled = function() return app.cancel_requested end }
					)
				end)
				app.busy = false
				local tail = filter:finish()
				if tail ~= "" then app.state:model_stream(tail) end
				if app.cancel_requested then
					app.state:cancel("cancelled by user")
					if session.messages[#session.messages] and session.messages[#session.messages].role == "user" then table.remove(session.messages) end
					app.cancel_requested = false
				elseif ok then
					local final = protocol.strip_tool_results(protocol.strip_tool_calls(turn_result.text or ""))
					app.state:assistant_complete(final)
					session:add_assistant(turn_result.text, turn_result._output_items)
					maybe_auto_compact()
				else
					app.state:notice(tostring(turn_result), "error")
					app.state.mode = "failed"
				end
				app:render()
			end
			::continue::
		end
		app:stop_io()
		auto_save()
		save_history(history_path, app.editor.history)
		return true
	end)
	if not result then return nil, err end
	return true
end

return tui
