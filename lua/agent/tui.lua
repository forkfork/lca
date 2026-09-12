local commands = require("agent.commands")
local compaction = require("agent.compaction")
local context_limits = require("agent.context_limits")
local core = require("agent.core")
local jobs = require("agent.jobs")
local protocol = require("agent.tool_protocol")
local session_module = require("agent.session")
local tui_effects = require("agent.tui_effects")
local river_divider = require("agent.river_divider")
local RiverTrace = require("agent.river_trace")
local json = require("agent.util.json")
local socket = require("socket")
local uv = require("luv")
local lcatui = require("agent.ui")

local tui = {}

local FRAME_SECONDS = 1 / 25
local FRAME_MILLISECONDS = 40
local FILE_COLUMNS_PER_SECOND = 21.6
local TASK_COLUMNS_PER_SECOND = 14
local EFFECT_NAMES = tui_effects.names()

local function clamp(value, low, high)
	return math.max(low, math.min(high, value))
end

local function rgb(r, g, b, attrs)
	return { fg = { r, g, b }, attrs = attrs or {} }
end

local function buffer_view(buffer, row_offset, height)
	local view = { width = buffer.width, height = height }
	function view:set(row, col, char, style)
		buffer:set(row + row_offset, col, char, style)
		return self
	end
	function view:fill(first_row, first_col, last_row, last_col, char, style)
		buffer:fill(first_row + row_offset, first_col, last_row + row_offset, last_col, char, style)
		return self
	end
	function view:write(row, col, text, style, max_width)
		buffer:write(row + row_offset, col, text, style, max_width)
		return self
	end
	return view
end

local function compact_text(value, limit)
	value = tostring(value or ""):gsub("\r", " "):gsub("\n", " "):gsub("%s+", " ")
	value = value:gsub("^%s+", ""):gsub("%s+$", "")
	limit = limit or 72
	if #value > limit then value = value:sub(1, limit - 3) .. "..." end
	return value
end

local function response_text(value, limit)
	value = tostring(value or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
	value = value:gsub("[%z\1-\8\11\12\14-\31]", "")
	if not utf8.len(value) then
		local repaired, position = {}, 1
		while position <= #value do
			local ok, codepoint = pcall(utf8.codepoint, value, position, position)
			if ok then
				local char = utf8.char(codepoint)
				repaired[#repaired + 1], position = char, position + #char
			else
				repaired[#repaired + 1], position = "�", position + 1
			end
		end
		value = table.concat(repaired)
	end
	limit = limit or 6000
	if #value <= limit then return value end
	local result, bytes = {}, 0
	for _, char in ipairs(lcatui.width.chars(value)) do
		if bytes + #char > limit then break end
		result[#result + 1], bytes = char, bytes + #char
	end
	return table.concat(result) .. "\n…"
end

local function basename(value)
	value = tostring(value or "")
	return value:match("([^/]+)$") or value
end

local function compact_args(name, args)
	args = args or {}
	if name == "grep" and args.pattern then
		return compact_text("/" .. tostring(args.pattern) .. "/ " .. tostring(args.path or "."), 44)
	elseif args.path then
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

local function snippet_line(value, limit)
	value = response_text(value, 1200)
	for line in (value .. "\n"):gmatch("(.-)\n") do
		local cleaned = line:gsub("^%s*%d+:[%w]+:%s*", ""):gsub("^%s+", ""):gsub("%s+$", "")
		if cleaned ~= "" then
			cleaned = cleaned:gsub("%s+", " ")
			local clipped = lcatui.width.truncate(cleaned, limit or 48)
			return clipped
		end
	end
	return ""
end

local format_duration

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
		assistant_completed_at = nil,
		turn_started_at = nil,
		completion_summary = nil,
		web_search_started_at = nil,
		web_search_seen = {},
		web_search_completed = {},
		notices = {},
		plan = nil,
		tools = {},
		tools_by_id = {},
		tool_queues = {},
		tool_sequence = 0,
		streams = {},
		stream_sequence = 0,
		handoffs = {},
		handoff_sequence = 0,
		transfers = {},
		transfer_sequence = 0,
		file_memory = {},
		file_order = {},
		turn_touched_paths = {},
		turn_changed_paths = {},
		verification_label = nil,
		recoveries = {},
		resolved_recovery = nil,
		turn_sequence = 0,
		failure = nil,
		verification = nil,
		disturbance = 0,
		proof = 0,
		cancelled = false,
		flywheel = nil,
		input = "",
		cursor = 0,
		clock = opts.clock or socket.gettime,
	}, State)
end

local FLYWHEEL_RELEASE_SECONDS = {
	harvest = 3.0,
	release_cancelled = 2.2,
}

function State:_set_flywheel(phase, detail)
	local previous = self.flywheel
	self.flywheel = {
		phase = phase,
		detail = detail,
		started_at = self.clock(),
		seed = previous and previous.seed or (self.turn_sequence * 97 + 19),
	}
end

function State:flywheel_visual(now)
	local wheel = self.flywheel
	if not wheel then return nil end
	now = tonumber(now) or self.clock()
	local age = math.max(0, now - (wheel.started_at or now))
	local release = 0
	if FLYWHEEL_RELEASE_SECONDS[wheel.phase] then
		local duration = FLYWHEEL_RELEASE_SECONDS[wheel.phase]
		release = clamp(age / duration, 0, 1)
		if age >= duration then return nil end
	end
	return {
		phase = wheel.phase,
		detail = wheel.detail,
		seed = wheel.seed,
		age = age,
		birth = clamp(age / 0.85, 0, 1),
		release = release,
	}
end

function State:_stream(text, kind, tool, duration, meta)
	text = snippet_line(text, 58)
	if text == "" then return nil end
	meta = meta or {}
	self.stream_sequence = self.stream_sequence + 1
	local stream = {
		id = self.stream_sequence,
		text = text,
		kind = kind or "info",
		tool = tool,
		lane = tool and tool.lane or ((self.stream_sequence - 1) % 6 + 1),
		direction = self.stream_sequence % 2 == 0 and -1 or 1,
		age = 0,
		motion_age = 0,
		duration = duration,
		file = meta.file == true,
		task = meta.task == true,
		verb = meta.verb,
		task_status = meta.status,
		personality = meta.personality,
		recovery_path = meta.recovery_path,
		recovery_phase = meta.recovery_phase,
		turn = self.turn_sequence,
	}
	self.streams[#self.streams + 1] = stream
	while #self.streams > 24 do
		local remove_at = 1
		for index, candidate in ipairs(self.streams) do
			if not (candidate.kind == "file_error" and candidate.recovery_path) then remove_at = index; break end
		end
		table.remove(self.streams, remove_at)
	end
	return stream
end

local FILE_TOOLS = { read = true, edit = true, multi_edit = true, write = true }
local FILE_MUTATION_TOOLS = { edit = true, multi_edit = true, write = true }

local function tool_personality(name)
	if name == "read" then return "skim" end
	if FILE_MUTATION_TOOLS[name] then return "inward" end
	if name == "grep" or name == "find" or name == "ls" then return "scatter" end
	if name == "run" or name == "shell" then return "pulse" end
	if name == "update_plan" then return "waypoint" end
	return "drift"
end

local function focused_plan_step(plan)
	if type(plan) ~= "table" then return nil end
	for _, item in ipairs(plan) do
		if item.status == "in_progress" and item.step and item.step ~= "" then return item end
	end
	for _, item in ipairs(plan) do
		if item.status == "pending" and item.step and item.step ~= "" then return item end
	end
	for index = #plan, 1, -1 do
		local item = plan[index]
		if item.step and item.step ~= "" then return item end
	end
	return nil
end


function State:_remember_file(path, update)
	path = tostring(path or "")
	if path == "" then return nil end
	update = update or {}
	local memory = self.file_memory[path] or {
		path = path, filename = basename(path), touches = 0, state = "dormant",
	}
	memory.touches = memory.touches + 1
	memory.touched_at = self.clock()
	memory.turn = self.turn_sequence
	for key, value in pairs(update) do memory[key] = value end
	self.file_memory[path] = memory
	for index, ordered_path in ipairs(self.file_order) do
		if ordered_path == path then table.remove(self.file_order, index); break end
	end
	self.file_order[#self.file_order + 1] = path
	self.turn_touched_paths[path] = true
	while #self.file_order > 8 do
		local remove_at
		for index, candidate_path in ipairs(self.file_order) do
			local candidate = self.file_memory[candidate_path]
			if candidate and candidate.state ~= "failed" and candidate.state ~= "changed" then remove_at = index; break end
		end
		if not remove_at then break end
		local removed = table.remove(self.file_order, remove_at)
		self.file_memory[removed] = nil
	end
	return memory
end

function State:_transfer(from, to, kind, duration)
	self.transfer_sequence = self.transfer_sequence + 1
	self.transfers[#self.transfers + 1] = {
		id = self.transfer_sequence, from = from, to = to, kind = kind,
		age = 0, duration = duration or 1.35,
	}
	while #self.transfers > 16 do table.remove(self.transfers, 1) end
end

function State:working_files(limit)
	local result = {}
	for index = #self.file_order, 1, -1 do
		local memory = self.file_memory[self.file_order[index]]
		if memory then result[#result + 1] = memory end
		if #result >= (limit or 6) then break end
	end
	return result
end

local function result_filename(name, args, result)
	if FILE_TOOLS[name] and args.path then return basename(args.path) end
	if (name == "grep" or name == "find") and result.content then
		local first = tostring(result.content):match("^([^\r\n]+)") or ""
		local path = first:match("^([^:]+):%d+:") or first:match("^([^%s]+)")
		if path and path ~= "" and not path:match("^%[") then return basename(path) end
	end
	return ""
end

local function recovery_reason(result)
	local summary = tostring(result.summary or "")
	local detail = tostring(result.content or "")
	local combined = (summary .. " " .. detail):lower()
	if combined:find("stale tag", 1, true) or combined:find("tag mismatch", 1, true) then return "target changed" end
	if combined:find("syntax", 1, true) then return "syntax rejected" end
	if combined:find("permission denied", 1, true) then return "permission denied" end
	if combined:find("not found", 1, true) or combined:find("no such file", 1, true) then return "file missing" end
	return compact_text(summary ~= "" and summary or detail ~= "" and detail or "operation failed", 30)
end

local function recovery_key(args)
	local path = args and args.path
	return path and tostring(path) ~= "" and tostring(path) or nil
end

local function recovery_attempt_matches(recovery, name, args)
	if not recovery or not FILE_MUTATION_TOOLS[name] then return false end
	if recovery.verb == "write" or name == "write" then return true end
	local old_start, old_finish = tonumber(recovery.start_line), tonumber(recovery.end_line)
	local new_start = tonumber(args and args.start_line)
	local new_finish = tonumber(args and (args.end_line or args.start_line))
	if old_start and new_start then
		old_finish, new_finish = old_finish or old_start, new_finish or new_start
		return new_start <= old_finish + 8 and new_finish >= old_start - 8
	end
	return recovery.phase == "refreshed"
end

function State:_set_recovery_phase(recovery, phase)
	recovery.phase = phase
	recovery.updated_at = self.clock()
end

function State:divider_status(now)
	local latest
	for _, recovery in pairs(self.recoveries) do
		if not latest or (recovery.updated_at or 0) > (latest.updated_at or 0) then latest = recovery end
	end
	if latest then
		if latest.phase == "refreshing" then return "↻ " .. latest.filename .. " · refreshing source", "recovery" end
		if latest.phase == "refreshed" then return "↻ " .. latest.filename .. " · source refreshed", "recovery" end
		if latest.phase == "retrying" then return "✦ " .. latest.filename .. " · retrying " .. (latest.action or "edit"), "retry" end
		return "× " .. latest.filename .. " · " .. latest.reason, "failure"
	end
	if self.resolved_recovery and (tonumber(now) or 0) <= self.resolved_recovery.expires_at then
		return "◆ " .. self.resolved_recovery.filename .. " · recovered", "resolved"
	end
	return nil, "quiet"
end

function State:_finish_streams(tool, event)
	for _, stream in ipairs(self.streams) do
		if stream.tool == tool and not stream.duration then stream.duration = stream.age + 0.35 end
	end
	local args, result = event.args or {}, event.result or {}
	local name, path = tostring(event.name), basename(args.path)
	local failed = result.is_error == true
	local filename = result_filename(name, args, result)
	if filename ~= "" then
		local key = recovery_key(args)
		local recovery = key and self.recoveries[key]
		if failed and FILE_MUTATION_TOOLS[name] then
			if recovery and recovery.stream then recovery.stream.duration = recovery.stream.age + 0.5 end
			local reason = recovery_reason(result)
			local stream = self:_stream(filename .. " · " .. reason, "file_error", tool, nil, {
				file = true, verb = name, personality = "inward", recovery_path = key, recovery_phase = "failed",
			})
			if key then
				recovery = {
					path = key, filename = filename, reason = reason, phase = "failed", stream = stream, verb = name,
					start_line = args.start_line, end_line = args.end_line,
				}
				self.recoveries[key] = recovery
				self:_set_recovery_phase(recovery, "failed")
			end
		elseif failed then
			self:_stream(filename .. " · " .. recovery_reason(result), "file_error", tool, 5.2, {
				file = true, verb = name, personality = tool_personality(name),
			})
		elseif recovery and name == "read" then
			self:_set_recovery_phase(recovery, "refreshed")
			self:_stream(filename .. " · source refreshed", "file_refresh", tool, 3.2, {
				file = true, verb = name, personality = "skim", recovery_path = key, recovery_phase = "refreshed",
			})
		elseif recovery and FILE_MUTATION_TOOLS[name]
			and (tool.recovery_attempt or recovery_attempt_matches(recovery, name, args)) then
			if recovery.stream then
				recovery.stream.text = filename .. " · updated"
				recovery.stream.kind = "file_resolving"
				recovery.stream.recovery_phase = "resolved"
				recovery.stream.resolution_age = recovery.stream.age
				recovery.stream.resolution_motion_age = recovery.stream.motion_age or recovery.stream.age
				recovery.stream.duration = recovery.stream.age + 2.2
			end
			self.resolved_recovery = { filename = filename, expires_at = self.clock() + 2.2 }
			self.recoveries[key] = nil
		else
			local kind = FILE_MUTATION_TOOLS[name] and "file_changed" or "file_read"
			self:_stream(filename, kind, tool, 5.2, { file = true, verb = name, personality = tool_personality(name) })
		end
	elseif name == "update_plan" and not failed then
		local item = focused_plan_step(result.plan or args.plan)
		if item then
			self:_stream(item.step, "task", tool, 6.2, { task = true, status = item.status, personality = "waypoint" })
		end
	elseif name == "run" or name == "shell" then
		local marker = failed and "× " or "◆ "
		self:_stream(marker .. compact_args(name, args) .. " · " .. tostring(result.summary or "done"), failed and "error" or "success", tool, 4.8, { personality = "pulse" })
	else
		local marker = failed and "× " or "◆ "
		self:_stream(marker .. name .. (path ~= "" and (" · " .. path) or "") .. " · " .. tostring(result.summary or "done"), failed and "error" or "success", tool, 3.8, { personality = tool_personality(name) })
	end
end

function State:notice(text, kind)
	self.notices[#self.notices + 1] = {
		text = compact_text(text, 180),
		kind = kind or "info",
		created_at = self.clock(),
	}
	while #self.notices > 4 do table.remove(self.notices, 1) end
end

function State:set_input(text, cursor)
	self.input = tostring(text or "")
	self.cursor = tonumber(cursor) or lcatui.width.string(self.input)
end

function State:submit(text)
	self.turn_sequence = self.turn_sequence + 1
	self.river_trace = RiverTrace.new()
	local river_designs = river_divider.names()
	self.river_design = river_designs[math.random(#river_designs)]
	self.prompt = compact_text(text, 240)
	self.assistant_stream = ""
	self.failure = nil
	self.verification = nil
	self.disturbance = 0
	self.proof = 0
	self.cancelled = false
	self.turn_started_at = self.clock()
	self:_set_flywheel("task", { prompt = self.prompt })
	self.completion_summary = nil
	self.plan = nil
	self.web_search_started_at = nil
	self.web_search_seen = {}
	self.web_search_completed = {}
	self.handoffs = {}
	self.transfers = {}
	self.turn_touched_paths = {}
	self.turn_changed_paths = {}
	self.verification_label = nil
	for _, memory in pairs(self.file_memory) do
		if memory.state == "reading" or memory.state == "editing" or memory.state == "writing" or memory.state == "read_error" then
			memory.state = "dormant"
		end
	end
	for _, recovery in pairs(self.recoveries) do
		if recovery.stream then
			if not recovery.stream.duration then recovery.stream.duration = recovery.stream.age + 0.5 end
			recovery.stream.recovery_path = nil
		end
	end
	self.recoveries = {}
	self.resolved_recovery = nil
	self.mode = "waiting"
	self.model_phase = "model waiting"
	self:_stream("› " .. self.prompt, "request", nil, 2.6, { personality = "ripple" })
end

function State:model_waiting(label)
	self.mode = "waiting"
	self.model_phase = label or "model waiting"
	self.assistant_stream = ""
end

function State:model_stream(text)
	if not text or text == "" then return end
	self.assistant_completed_at = nil
	self.mode = "streaming"
	self.model_phase = "assistant streaming"
	self.assistant_stream = response_text(self.assistant_stream .. text, 6000)
end

function State:reviewing(info)
	self.mode = "reviewing"
	self.model_phase = compact_text(info and info.status or "model continuing after tools", 80)
end

local WEB_SEARCH_EYES = {
	"( o  o )",
	"(o  o  )",
	"( o  o )",
	"(  o  o)",
	"(  oo  )",
	"( -  - )",
}

local function web_search_counts(state)
	local opened, returned = 0, 0
	for _ in pairs(state.web_search_seen) do opened = opened + 1 end
	for _ in pairs(state.web_search_completed) do returned = returned + 1 end
	return opened, returned
end

function State:_web_search_label(now)
	now = tonumber(now) or self.clock()
	local opened, returned = web_search_counts(self)
	local age = math.max(0, now - (self.web_search_started_at or now))
	local eye_index = math.floor(age * 2.5) % #WEB_SEARCH_EYES + 1
	local count = string.format("%d opened so far", opened)
	if returned > 0 then count = count .. string.format(" · %d back", returned) end
	return string.format("web search %s · %s · %s", WEB_SEARCH_EYES[eye_index], count, format_duration(age))
end

function State:model_activity(activity)
	if not activity then return end
	if activity.type == "web_search" then
		local key = tostring(activity.id or activity.output_index or "search")
		if not self.web_search_started_at then self.web_search_started_at = self.clock() end
		self.web_search_seen[key] = true
		if activity.phase == "completed" then self.web_search_completed[key] = true end
		self.model_phase = self:_web_search_label()
		self.mode = "composing"
		return
	end
	if not activity.status then return end
	self.mode = "composing"
	self.model_phase = compact_text(activity.status, 80)
end

function State:display_model_phase(now)
	if self.mode ~= "composing" or not self.web_search_started_at then return self.model_phase end
	return self:_web_search_label(now)
end

-- tools_by_id owns tool identity; tools keeps ordered active tools plus a
-- bounded completed history. Active entries never count against that limit.
function State:_prune_tools()
	local completed = 0
	for index = #self.tools, 1, -1 do
		local tool = self.tools[index]
		if tool.status ~= "active" then
			completed = completed + 1
			if completed > 18 then
				table.remove(self.tools, index)
				self.tools_by_id[tool.id] = nil
			end
		end
	end
end

function State:_resolve_tool(event)
	local id = event.call_id and tostring(event.call_id) or nil
	if id then return self.tools_by_id[id] end
	local queue = self.tool_queues[event_key(event)]
	if queue and #queue > 0 then return queue[1] end
	return nil
end

function State:tool_event(event)
	if self.river_trace then self.river_trace:event(event, self.clock()) end
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
			batch_id = event.batch_id,
			model_index = tonumber(event.model_index),
			sequence = self.tool_sequence,
			lane = ((self.tool_sequence - 1) % 6) + 1,
		}
		self.tools[#self.tools + 1] = tool
		self.tools_by_id[id] = tool
		local queue_key = event_key(event)
		tool.queue_key = queue_key
		self.tool_queues[queue_key] = self.tool_queues[queue_key] or {}
		self.tool_queues[queue_key][#self.tool_queues[queue_key] + 1] = tool
		local event_args = event.args or {}
		if FILE_TOOLS[event.name] and event_args.path then
			local mutation = FILE_MUTATION_TOOLS[event.name]
			self:_remember_file(event_args.path, {
				verb = event.name, state = mutation and event.name == "write" and "writing" or mutation and "editing" or "reading",
				tool_id = tool.id, summary = nil,
			})
			local file_endpoint = { kind = "file", path = tostring(event_args.path) }
			if mutation then self:_transfer({ kind = "core" }, file_endpoint, "write")
			else self:_transfer(file_endpoint, { kind = "core" }, "read") end
		end
		local key = recovery_key(event_args)
		local recovery = key and self.recoveries[key]
		local plan_item = event.name == "update_plan" and focused_plan_step(event_args.plan)
		if plan_item then
			self.plan = event_args.plan
			self:_stream(plan_item.step, "task_active", tool, nil, { task = true, status = plan_item.status, personality = "waypoint" })
		elseif recovery and event.name == "read" then
			self:_set_recovery_phase(recovery, "refreshing")
			self:_stream(basename(event_args.path) .. " · refreshing source", "file_refresh", tool, nil, {
				file = true, verb = event.name, personality = "skim", recovery_path = key, recovery_phase = "refreshing",
			})
		elseif recovery and recovery_attempt_matches(recovery, event.name, event_args) then
			tool.recovery_attempt = true
			recovery.action = event.name
			self:_set_recovery_phase(recovery, "retrying")
			self:_stream(basename(event_args.path) .. " · retrying " .. event.name, "file_retry", tool, nil, {
				file = true, verb = event.name, personality = "inward", recovery_path = key, recovery_phase = "retrying",
			})
		elseif FILE_TOOLS[event.name] and event_args.path then
			self:_stream(basename(event_args.path), "file_active", tool, nil, { file = true, verb = event.name, personality = tool_personality(event.name) })
		else
			self:_stream(tostring(event.name) .. (tool.args ~= "" and (" · " .. tool.args) or ""), "active", tool, nil, { personality = tool_personality(event.name) })
		end
		if event.name == "run" or event.name == "shell" then
			local linked = 0
			for index = #self.streams, 1, -1 do
				local source = self.streams[index]
				if source.turn == self.turn_sequence and source.kind == "file_changed" then
					self.handoff_sequence = self.handoff_sequence + 1
					self.handoffs[#self.handoffs + 1] = {
						id = self.handoff_sequence, source = source, target = tool,
						age = 0, duration = 1.5,
					}
					linked = linked + 1
					if linked >= 3 then break end
				end
			end
		end
	elseif event.phase == "progress" then
		tool = self:_resolve_tool(event)
		if not tool then return nil end
		local progress = type(event.progress) == "table" and event.progress or {}
		tool.elapsed_ms = tonumber(progress.elapsed_ms)
		tool.output_bytes = tonumber(progress.output_bytes) or 0
		tool.output_chunks = tonumber(progress.output_chunks) or 0
		tool.result = format_duration((tool.elapsed_ms or 0) / 1000)
	else
		tool = self:_resolve_tool(event)
		if not tool then
			self.tool_sequence = self.tool_sequence + 1
			local id = tostring(event.call_id or ("tool-" .. tostring(self.tool_sequence)))
			tool = {
				id = id, name = tostring(event.name), args = compact_args(event.name, event.args),
				started_at = self.clock(), batch_id = event.batch_id,
				model_index = tonumber(event.model_index), sequence = self.tool_sequence,
				lane = ((self.tool_sequence - 1) % 6) + 1,
			}
			self.tools[#self.tools + 1] = tool
			self.tools_by_id[id] = tool
		end
		tool.result = compact_text(event.result and (event.result.summary or event.result.content) or "done", 76)
		tool.status = event.result and event.result.is_error and "error"
			or (event.result and event.result.ui_state == "deferred" and "deferred" or "ok")
		tool.finished_at = self.clock()
		tool.duration_ms = tonumber(event.duration_ms)
		self:_finish_streams(tool, event)
		local args, result = event.args or {}, event.result or {}
		if FILE_TOOLS[event.name] and args.path then
			local failed = result.is_error == true
			local mutation = FILE_MUTATION_TOOLS[event.name]
			local state = failed and (mutation and "failed" or "read_error") or mutation and "changed" or "read"
			local memory_update = {
				verb = event.name, state = state, tool_id = tool.id,
				summary = compact_text(result.summary or result.content or (failed and "failed" or "done"), 52),
			}
			if mutation then memory_update.scar = failed end
			self:_remember_file(args.path, memory_update)
			if not failed and FILE_MUTATION_TOOLS[event.name] then
				self.turn_changed_paths[tostring(args.path)] = true
				-- A later mutation invalidates earlier proof from the same turn.
				self.verification_label, self.verification, self.proof = nil, nil, 0
			end
		end
		local queue_key = tool.queue_key
		local queue = queue_key and self.tool_queues[queue_key]
		if queue then
			for index, queued in ipairs(queue) do
				if queued == tool then table.remove(queue, index); break end
			end
			if #queue == 0 then self.tool_queues[queue_key] = nil end
		end
		if event.name == "update_plan" and event.result and type(event.result.plan) == "table" then
			self.plan = event.result.plan
		end
		if event.name == "run" or event.name == "shell" then
			-- Exit status reports this command's outcome, not verification of files.
			-- Do not infer test/build coverage from command text.
			self.verification, self.verification_label, self.proof = nil, nil, 0
			if tool.status == "error" then
				self.failure = tool.result ~= "" and tool.result or "command failed"
				self.disturbance = 1
				self.mode = "failed"
			elseif tool.status == "ok" then
				self.failure = nil
				self.disturbance = 0
				self.mode = "reviewing"
			end
		end
	end
	if event.phase == "start" then self.mode = "tools" end
	self.model_phase = event.phase == "start" and "tools active"
		or event.phase == "progress" and "tools active · " .. (tool and tool.result or "working")
		or "reviewing results"
	-- Keep bounded inspection text, not entire result objects or unbounded output.
	if not tool.args_detail then
		local ok, encoded = pcall(json.encode, event.args or {})
		tool.args_detail = response_text(ok and encoded or tool.args, 8000)
	end
	if event.result then
		local result = event.result
		local text = result.summary or ""
		if result.content then
			local content = result.content
			if type(content) ~= "string" then
				local ok, encoded = pcall(json.encode, content)
				content = ok and encoded or tostring(content)
			end
			text = text .. "\n" .. content
		end
		tool.result_detail = response_text(text, 16000)
	end
	self:_prune_tools()
	return tool
end

format_duration = function(seconds)
	seconds = math.max(0, tonumber(seconds) or 0)
	if seconds < 60 then return tostring(math.floor(seconds + 0.5)) .. "s" end
	local minutes = math.floor(seconds / 60)
	local remainder = math.floor(seconds - minutes * 60 + 0.5)
	if remainder == 60 then minutes, remainder = minutes + 1, 0 end
	return tostring(minutes) .. "m " .. tostring(remainder) .. "s"
end

local function format_tokens(tokens)
	tokens = math.max(0, tonumber(tokens) or 0)
	if tokens >= 1000 then return tostring(math.floor(tokens / 1000 + 0.5)) .. "k tokens" end
	return tostring(math.floor(tokens + 0.5)) .. " tokens"
end

function State:assistant_complete(text, metrics)
	self.assistant = response_text(text, 6000)
	self.assistant_stream = ""
	self.assistant_completed_at = self.clock()
	self:_set_flywheel("harvest", { verification = self.verification_label })
	metrics = metrics or {}
	local started_at = tonumber(metrics.started_at) or self.turn_started_at
	local elapsed = tonumber(metrics.elapsed) or (started_at and self.assistant_completed_at - started_at)
	if elapsed and metrics.tokens and next(self.recoveries) == nil then
		local segments = {}
		local changed = 0
		for _ in pairs(self.turn_changed_paths) do changed = changed + 1 end
		if changed > 0 then segments[#segments + 1] = tostring(changed) .. (changed == 1 and " file" or " files") end
		if self.verification_label then segments[#segments + 1] = self.verification_label end
		segments[#segments + 1] = format_duration(elapsed)
		segments[#segments + 1] = format_tokens(metrics.tokens)
		if metrics.cache_percent ~= nil then
			local cached = clamp(tonumber(metrics.cache_percent) or 0, 0, 100)
			segments[#segments + 1] = tostring(math.floor(cached + 0.5)) .. "% cached"
		end
		self.completion_summary = "✓ " .. table.concat(segments, " · ")
	end
	self.mode = "complete"
	self.model_phase = "assistant complete"
end

function State:cancel(reason)
	self.cancelled = true
	self.mode = "cancelled"
	self.model_phase = compact_text(reason or "cancelled", 80)
	self:_set_flywheel("release_cancelled", { reason = reason })
	for _, tool in pairs(self.tools_by_id) do
		if tool.status == "active" then tool.status = "cancelled" end
	end
	self.tool_queues = {}
	self:_prune_tools()
end

function State:listen()
	self.mode = "listening"
	self.model_phase = "listening"
	self.disturbance = 0
end

function State:active_tools()
	local result = {}
	for _, tool in pairs(self.tools_by_id) do
		if tool.status == "active" then result[#result + 1] = tool end
	end
	table.sort(result, function(a, b) return a.sequence < b.sequence end)
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
function Editor:layout(columns, max_rows)
	local lines, row, col = { {} }, 1, 0
	local cursor_row, cursor_col
	for index = 1, #self.chars + 1 do
		local char = self.chars[index]
		local char_width = char and lcatui.width.string(char) or 1
		if col + char_width > columns then
			row, col = row + 1, 0
			lines[row] = {}
		end
		if index == self.cursor + 1 then cursor_row, cursor_col = row, col end
		if char == "\n" then
			row, col = row + 1, 0
			lines[row] = {}
		elseif char then
			lines[row][#lines[row] + 1] = char
			col = col + char_width
		end
	end
	local count = math.min(#lines, max_rows)
	local first = math.max(1, math.min(cursor_row - count + 1, #lines - count + 1))
	local visible = {}
	for index = first, first + count - 1 do visible[#visible + 1] = table.concat(lines[index]) end
	return visible, cursor_row - first + 1, cursor_col
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
function Editor:backspace_word()
	while self.cursor > 0 and self.chars[self.cursor]:match("%s") do self:backspace() end
	while self.cursor > 0 and not self.chars[self.cursor]:match("%s") do self:backspace() end
end
function Editor:word_left()
	while self.cursor > 0 and self.chars[self.cursor]:match("%s") do self.cursor = self.cursor - 1 end
	while self.cursor > 0 and not self.chars[self.cursor]:match("%s") do self.cursor = self.cursor - 1 end
end
function Editor:word_right()
	while self.cursor < #self.chars and self.chars[self.cursor + 1]:match("%s") do self.cursor = self.cursor + 1 end
	while self.cursor < #self.chars and not self.chars[self.cursor + 1]:match("%s") do self.cursor = self.cursor + 1 end
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
	["\27\127"] = "backspace_word", ["\27\8"] = "backspace_word",
	["\27[1;5D"] = "word_left", ["\27[1;5C"] = "word_right",
	["\27[1;3D"] = "word_left", ["\27[1;3C"] = "word_right",
	["\27b"] = "word_left", ["\27f"] = "word_right",
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

function Input:_action(name)
	local editor = self.editor
	if self.inspect and (name == "up" or name == "down") then
		return { type = "inspect_scroll", delta = name == "up" and -1 or 1 }
	end
	if name == "up" then editor:history_move(-1)
	elseif name == "down" then editor:history_move(1)
	elseif name == "left" then editor.cursor = math.max(0, editor.cursor - 1)
	elseif name == "right" then editor.cursor = math.min(#editor.chars, editor.cursor + 1)
	elseif name == "word_left" then editor:word_left()
	elseif name == "word_right" then editor:word_right()
	elseif name == "home" then editor.cursor = 0
	elseif name == "end" then editor.cursor = #editor.chars
	elseif name == "delete" then editor:delete()
	elseif name == "backspace_word" then editor:backspace_word()
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
		if action then self.buffer = ""; return self:_action(action) end
		if escape_prefix(self.buffer) and #self.buffer < 8 then return nil end
		self.buffer = ""
		return nil
	end

	local first = self.buffer:byte(1)
	if first == 20 then
		self.buffer = ""
		self.inspect = not self.inspect
		return { type = "inspect" }
	end
	if self.inspect and first == 9 then self.buffer = ""; return { type = "inspect_next" } end
	if self.inspect and (first == 10 or first == 13) then self.buffer = ""; return nil end
	if first == 9 then
		self.buffer = ""
		if not busy and #self.editor.chars == 0 then return { type = "focus_next" } end
		return nil
	end
	if first == 3 then self.buffer = ""; return { type = busy and "cancel" or "exit" } end
	if first == 4 then
		self.buffer = ""
		if #self.editor.chars == 0 then return { type = "exit" } end
		self.editor:delete(); return nil
	end
	if first == 12 then self.buffer = ""; return { type = "redraw" } end
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

function Input:feed_chunk(chunk, busy)
	local actions = {}
	chunk = tostring(chunk or "")
	for index = 1, #chunk do
		local action = self:feed(chunk:sub(index, index), busy)
		if action then actions[#actions + 1] = action end
	end
	return actions
end

tui.Input = Input

local StreamFilter = {}
StreamFilter.__index = StreamFilter

function StreamFilter.new()
	return setmetatable({
		buffer = "", hidden = nil, hidden_name = nil, hidden_bytes = 0,
		hidden_preview = "", saw_tool = false,
	}, StreamFilter)
end

local function progress_count(bytes)
	if bytes >= 1000 then return string.format("%.1fk chars", bytes / 1000) end
	return tostring(bytes) .. " chars"
end

function StreamFilter:_observe_hidden(value)
	value = tostring(value or "")
	self.hidden_bytes = self.hidden_bytes + #value
	if #self.hidden_preview < 1200 then
		self.hidden_preview = (self.hidden_preview .. value):sub(1, 1200)
	end
end

function StreamFilter:_activity()
	if not self.hidden then return nil end
	if self.hidden == "thinking" then
		return { kind = "thinking", status = "model thinking · " .. progress_count(self.hidden_bytes) }
	end
	local name = self.hidden_name or "tool call"
	local target = self.hidden_preview:match('"path"%s*:%s*"([^"\\]+)"')
		or self.hidden_preview:match('"command"%s*:%s*"([^"\\]+)"')
	local action = FILE_MUTATION_TOOLS[name] and ("drafting " .. name) or ("preparing " .. name)
	if target and target ~= "" then action = action .. " · " .. compact_text(target, 38) end
	return {
		kind = "tool", name = name, target = target, bytes = self.hidden_bytes,
		status = "model " .. action .. " · " .. progress_count(self.hidden_bytes),
	}
end

function StreamFilter:feed(delta)
	if self.saw_tool then return "", nil end
	self.buffer = self.buffer .. tostring(delta or "")
	local visible = {}
	local activity
	while #self.buffer > 0 do
		if self.hidden then
			local close_tag = self.hidden == "tool" and "</tool_call>" or "</thinking>"
			local at = self.buffer:find(close_tag, 1, true)
			if not at then
				local keep = math.min(#self.buffer, #close_tag - 1)
				self:_observe_hidden(self.buffer:sub(1, #self.buffer - keep))
				self.buffer = self.buffer:sub(#self.buffer - keep + 1)
				activity = self:_activity()
				break
			end
			self:_observe_hidden(self.buffer:sub(1, at - 1))
			activity = self:_activity()
			self.buffer = self.buffer:sub(at + #close_tag)
			if self.hidden == "tool" then self.saw_tool = true; self.buffer = ""; break end
			self.hidden, self.hidden_name, self.hidden_bytes, self.hidden_preview = nil, nil, 0, ""
		else
			local tool_at = self.buffer:find("<tool_call", 1, true)
			local thinking_at = self.buffer:find("<thinking", 1, true)
			local at, kind
			if tool_at and (not thinking_at or tool_at < thinking_at) then at, kind = tool_at, "tool"
			elseif thinking_at then at, kind = thinking_at, "thinking" end
			if at then
				visible[#visible + 1] = self.buffer:sub(1, at - 1)
				local tag_end = self.buffer:find(">", at, true)
				if not tag_end then
					self.buffer = self.buffer:sub(at)
					break
				end
				local opening = self.buffer:sub(at, tag_end)
				self.buffer = self.buffer:sub(tag_end + 1)
				self.hidden = kind
				self.hidden_name = kind == "tool" and opening:match('name%s*=%s*"([^"]+)"') or nil
				self.hidden_bytes, self.hidden_preview = 0, ""
				activity = self:_activity()
			else
				local keep = math.min(#self.buffer, 16)
				visible[#visible + 1] = self.buffer:sub(1, #self.buffer - keep)
				self.buffer = self.buffer:sub(#self.buffer - keep + 1)
				break
			end
		end
	end
	return table.concat(visible), activity
end

function StreamFilter:finish()
	if self.hidden or self.saw_tool then return "" end
	local value = self.buffer
	self.buffer = ""
	return value
end

tui.StreamFilter = StreamFilter

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

local function crystallize(buffer, row, text, age, style)
	local chars = lcatui.width.chars(text)
	local text_width = lcatui.width.string(text)
	local target_start = math.max(1, math.floor((buffer.width - text_width) / 2) + 1)
	local progress = clamp((tonumber(age) or 0) / 0.85, 0, 1)
	if progress >= 1 then center(buffer, row, text, style); return end
	local eased = 1 - (1 - progress) ^ 3
	local target_x = target_start
	for index, char in ipairs(chars) do
		local width = math.max(0, lcatui.width.string(char))
		if char ~= " " and width > 0 then
			local start_x = 1 + ((index * 37 + #chars * 11) % math.max(1, buffer.width))
			local start_y = 1 + ((index * 5 + #chars) % math.max(1, row * 2 - 1))
			local x = clamp(math.floor(start_x + (target_x - start_x) * eased + 0.5), 1, buffer.width)
			local y = clamp(math.floor(start_y + (row - start_y) * eased + 0.5), 1, buffer.height)
			buffer:write(y, x, char, style, width)
		end
		target_x = target_x + width
	end
end

local function completion_pop(buffer, row, text, age)
	local start_age, duration = 0.68, 1.05
	local progress = ((tonumber(age) or 0) - start_age) / duration
	if progress < 0 or progress > 1 then return false end
	local centre_x = (buffer.width + 1) / 2
	local text_radius = lcatui.width.string(text) / 2
	local burst = math.sin(progress * math.pi)
	local sparks = 14
	local styles = {
		rgb(104, 231, 185, { "bold" }),
		rgb(238, 190, 91, { "bold" }),
		rgb(190, 142, 231, { "bold" }),
	}
	for index = 1, sparks do
		local angle = (index - 1) / sparks * math.pi * 2 + 0.17
		local horizontal = text_radius + 1 + progress * (7 + index % 4)
		local vertical = 0.55 + progress * 1.1
		local x = clamp(math.floor(centre_x + math.cos(angle) * horizontal + 0.5), 1, buffer.width)
		local y = clamp(math.floor(row + math.sin(angle) * vertical - progress * progress * 0.35 + 0.5), 1, buffer.height)
		local glyph = progress < 0.3 and (index % 3 == 0 and "✦" or "◆")
			or progress < 0.72 and (index % 2 == 0 and "⋆" or "·")
			or (index % 3 == 0 and "˙" or "·")
		local style = styles[index % #styles + 1]
		if burst > 0.08 then buffer:set(y, x, glyph, style) end
	end
	return true
end

local function living_divider(buffer, row, width, label, kind, time, previous_label, molt_progress, plan)
	local quiet = rgb(40, 65, 70, { "dim" })
	buffer:write(row, 1, string.rep("─", width), quiet, width)
	if not label or label == "" then return end
	local styles = {
		failure = rgb(222, 72, 105, { "bold" }),
		recovery = rgb(79, 188, 194, { "bold" }),
		retry = rgb(190, 142, 231, { "bold" }),
		resolved = rgb(91, 224, 169, { "bold" }),
		task = rgb(194, 158, 224),
		active = rgb(105, 180, 184),
	}
	local text = " " .. lcatui.width.truncate(label, math.max(12, width - 16)) .. " "
	local text_width = lcatui.width.string(text)
	local start = math.max(2, math.floor((width - text_width) / 2) + 1)
	local cell_style = styles[kind] or styles.active
	if previous_label and kind == "task" and (molt_progress or 1) < 1 then
		local progress = clamp(tonumber(molt_progress) or 0, 0, 1)
		local chars = lcatui.width.chars(text)
		local centre = (#chars + 1) / 2
		local reveal = progress * (#chars / 2 + 1)
		local col = start
		for index, char in ipairs(chars) do
			local char_width = math.max(1, lcatui.width.string(char))
			local distance = math.abs(index - centre)
			if char == " " or distance <= reveal then
				buffer:write(row, col, char, cell_style, char_width)
			elseif distance <= reveal + 1.6 then
				buffer:set(row, col, "·", rgb(130, 103, 158, { "dim" }))
			end
			col = col + char_width
		end
		local old_radius = lcatui.width.string(previous_label) / 2 + 2
		for spark = 1, 6 do
			local direction = spark % 2 == 0 and 1 or -1
			local distance = old_radius + progress * (3 + spark)
			local x = clamp(math.floor((width + 1) / 2 + direction * distance + 0.5), 1, width)
			buffer:set(row, x, progress < 0.55 and "·" or "˙", rgb(112, 83, 139, { "dim" }))
		end
	else
		buffer:write(row, start, text, cell_style, text_width)
	end
	local span = math.max(1, start - 3)
	local pulse = 1 + (math.floor((tonumber(time) or 0) * 9) % span)
	buffer:set(row, pulse, "━", cell_style)
	buffer:set(row, width - pulse + 1, "━", cell_style)
	if kind == "task" and type(plan) == "table" then
		local available = math.max(0, math.floor((start - 3) / 2))
		local count = math.min(#plan, available, 8)
		for index = 1, count do
			local item = plan[index]
			local glyph = item.status == "completed" and "●" or item.status == "in_progress" and "◉" or "○"
			local style = item.status == "completed" and rgb(76, 178, 143, { "dim" })
				or item.status == "in_progress" and rgb(194, 158, 224, { "bold" })
				or rgb(62, 83, 91, { "dim" })
			buffer:set(row, 2 + (index - 1) * 2, glyph, style)
		end
	end
end

local FILE_MORPHS = {
	{ "‹", "›" }, { "{", "}" }, { "⟨", "⟩" }, { "[", "]" },
}

local TASK_MORPHS = { "○", "◔", "◑", "◕" }

local function visual_age(stream)
	return tonumber(stream.motion_age) or tonumber(stream.age) or 0
end

local function stream_display(stream)
	local motion_age = visual_age(stream)
	if stream.task then
		local marker = stream.task_status == "completed" and "✓"
			or stream.kind == "task_active" and TASK_MORPHS[(math.floor(motion_age * 6 + stream.id) % #TASK_MORPHS) + 1]
			or stream.task_status == "in_progress" and "◉" or "○"
		return marker .. " " .. stream.text
	end
	if not stream.file then
		if stream.personality == "pulse" and not stream.text:match("^[◆◇×]") then
			local marker = math.floor(motion_age * 5) % 2 == 0 and "◆" or "◇"
			return marker .. " " .. stream.text
		elseif stream.personality == "scatter" then
			return "⌁ " .. stream.text
		end
		return stream.text
	end
	local frame = FILE_MORPHS[(math.floor(motion_age * 8 + stream.id) % #FILE_MORPHS) + 1]
	local marker = stream.kind == "file_error" and "×"
		or stream.kind == "file_refresh" and "↻"
		or stream.kind == "file_retry" and "✦"
		or stream.kind == "file_resolving" and ((motion_age - (stream.resolution_motion_age or motion_age)) < 0.45 and "×"
			or (motion_age - (stream.resolution_motion_age or motion_age)) < 0.9 and "◇" or "◆")
		or stream.kind == "file_changed" and "◆"
		or stream.kind == "file_read" and "◇"
		or stream.verb == "edit" and "✦"
		or stream.verb == "write" and "✧"
		or "·"
	return marker .. " " .. frame[1] .. stream.text .. frame[2]
end

local function stream_position(stream, width, display)
	local motion_age = visual_age(stream)
	local text_width = lcatui.width.string(display or stream_display(stream))
	local span = math.max(1, width - text_width - 2)
	local progress
	local travel_direction = 1
	if stream.personality == "inward" then
		local edge = stream.direction < 0 and 1 or 0
		progress = 0.5 + (edge - 0.5) * math.exp(-motion_age * 0.72)
		travel_direction = edge == 0 and 1 or -1
	elseif stream.personality == "scatter" then
		local reach = clamp(motion_age / 2.1, 0, 1)
		progress = 0.5 + stream.direction * 0.46 * reach
		travel_direction = stream.direction
	elseif stream.personality == "pulse" then
		progress = 0.5 + math.sin(motion_age * 5.2 + stream.id) * math.min(0.09, 7 / span)
		travel_direction = math.cos(motion_age * 5.2 + stream.id) >= 0 and 1 or -1
	elseif stream.file or stream.task or not stream.duration then
		local cycles = stream.file and (motion_age * FILE_COLUMNS_PER_SECOND / span)
			or stream.task and (motion_age * TASK_COLUMNS_PER_SECOND / span)
			or (motion_age / 7)
		local phase = (cycles + stream.id * 0.137) % 2
		progress = phase <= 1 and phase or 2 - phase
		travel_direction = phase <= 1 and 1 or -1
	elseif stream.duration then
		progress = clamp(stream.age / math.max(0.1, stream.duration), 0, 1)
	end
	if stream.direction < 0 and stream.personality ~= "inward" and stream.personality ~= "scatter" and stream.personality ~= "pulse" then
		progress = 1 - progress
		travel_direction = -travel_direction
	end
	return 2 + math.floor(span * progress), travel_direction
end

local function stream_row(stream, world_rows)
	local motion_age = visual_age(stream)
	local lane = clamp(stream.lane or 1, 1, world_rows)
	if stream.personality == "scatter" then
		return clamp(lane + math.floor(math.sin(motion_age * 3.2 + stream.id) * 1.5), 1, world_rows)
	elseif stream.personality == "inward" then
		local centre = (world_rows + 1) / 2
		local pull = 1 - math.exp(-motion_age * 0.72)
		return clamp(math.floor(lane + (centre - lane) * pull + 0.5), 1, world_rows)
	elseif stream.personality == "pulse" then
		return clamp(math.floor((world_rows + 1) / 2 + math.sin(motion_age * 5.2) * 0.7 + 0.5), 1, world_rows)
	end
	return lane
end

local function stream_priority(stream)
	local priority = (stream.kind == "error" or stream.kind == "file_error") and 120
		or stream.kind == "file_retry" and 118
		or stream.kind == "file_refresh" and 116
		or stream.kind == "file_resolving" and 114
		or (stream.kind == "active" or stream.kind == "file_active" or stream.kind == "task_active") and 105
		or stream.kind == "success" and 100
		or stream.kind == "file_changed" and 90
		or stream.kind == "request" and (stream.age < 1.2 and 88 or 35)
		or stream.kind == "task" and 75
		or stream.kind == "file_read" and 65
		or 50
	return priority - stream.age * 0.8 + stream.id * 0.001
end

local function conduct_streams(streams, world_rows)
	local ordered = {}
	for _, stream in ipairs(streams) do ordered[#ordered + 1] = stream end
	table.sort(ordered, function(a, b) return stream_priority(a) > stream_priority(b) end)
	local foreground, selected, occupied, rows = {}, {}, {}, {}
	for _, stream in ipairs(ordered) do
		local preferred = stream_row(stream, world_rows)
		local assigned
		for distance = 0, world_rows - 1 do
			for _, candidate in ipairs({ preferred - distance, preferred + distance }) do
				if candidate >= 1 and candidate <= world_rows and not occupied[candidate] then
					assigned = candidate
					break
				end
			end
			if assigned then break end
		end
		if assigned and #foreground < world_rows then
			foreground[#foreground + 1], selected[stream] = stream, true
			occupied[assigned], rows[stream] = true, assigned
		end
	end
	return foreground, selected, ordered, rows
end

local TOOL_STAGE_SPINNERS = { "◐", "◓", "◑", "◒" }

local function tool_stage_batch(tools, now)
	local latest_batch
	for index = #tools, 1, -1 do
		if tools[index].batch_id ~= nil then latest_batch = tools[index].batch_id; break end
	end
	local staged = {}
	for _, tool in ipairs(tools) do
		local same_batch = latest_batch == nil or tool.batch_id == latest_batch
		local recent = tool.status == "active" or (tool.finished_at and now - tool.finished_at < 6)
		if same_batch and recent then staged[#staged + 1] = tool end
	end
	table.sort(staged, function(a, b)
		local ai, bi = a.model_index or a.sequence or 0, b.model_index or b.sequence or 0
		if ai == bi then return (a.sequence or 0) < (b.sequence or 0) end
		return ai < bi
	end)
	return staged, latest_batch
end

local function tool_stage_label(tool, index, width, now, time)
	local active = tool.status == "active"
	local glyph = active and TOOL_STAGE_SPINNERS[(math.floor(time * 8 + index) % #TOOL_STAGE_SPINNERS) + 1]
		or tool.status == "error" and "×"
		or tool.status == "cancelled" and "■"
		or tool.status == "deferred" and "↷" or "✓"
	local elapsed_ms = tool.duration_ms
	if active then elapsed_ms = math.max(0, (now - (tool.started_at or now)) * 1000) end
	local timing = elapsed_ms and (elapsed_ms < 1000 and (tostring(math.floor(elapsed_ms + 0.5)) .. "ms")
		or string.format("%.1fs", elapsed_ms / 1000)) or nil
	local identity = string.format("%02d %s %s", tool.model_index or index, glyph, tool.name)
	local room = math.max(0, width - lcatui.width.string(identity) - (timing and lcatui.width.string(timing) + 3 or 2))
	local detail = room > 3 and lcatui.width.truncate(tool.args or "", room) or ""
	local body = identity .. (detail ~= "" and (" · " .. detail) or "")
	if timing then body = body .. " · " .. timing end
	return lcatui.width.truncate(body, math.max(1, width))
end

local function draw_tool_stage(buffer, tools, time, now)
	if #tools == 0 then return false end
	local rows = math.min(buffer.height, #tools)
	local columns = math.ceil(#tools / rows)
	local cell_width = math.max(8, math.floor(buffer.width / columns))
	for index, tool in ipairs(tools) do
		local column = math.floor((index - 1) / rows)
		local row = (index - 1) % rows + 1
		local left = column * cell_width + 1
		local right = column == columns - 1 and buffer.width or math.min(buffer.width, left + cell_width - 2)
		local inner_width = math.max(1, right - left - 2)
		local age = math.max(0, now - (tool.started_at or now))
		local arrival = clamp(age / 0.38, 0, 1)
		local eased = 1 - (1 - arrival) ^ 3
		local offset = math.floor((1 - eased) * math.min(6, inner_width / 3))
		local label = tool_stage_label(tool, index, inner_width, now, time)
		local active = tool.status == "active"
		local style = tool.status == "error" and rgb(241, 79, 115, { "bold" })
			or tool.status == "deferred" and rgb(218, 158, 93, { "bold" })
			or active and rgb(91, 224, 231, { "bold" })
			or rgb(91, 224, 169, { "bold" })
		local quiet = tool.status == "error" and rgb(151, 48, 79, { "dim" })
			or active and rgb(55, 136, 148, { "dim" }) or rgb(47, 129, 99, { "dim" })
		local x = clamp(left + 1 + offset, left + 1, math.max(left + 1, right - lcatui.width.string(label)))
		buffer:set(row, left, active and "⟪" or "[", quiet)
		buffer:write(row, x, label, style, math.max(1, right - x))
		buffer:set(row, right, active and "⟫" or "]", quiet)
		if active and right - left > 8 then
			local spark = math.floor(time * 6 + index) % 2 == 0 and left or right
			buffer:set(row, spark, "✦", rgb(238, 190, 91, { "bold" }))
		elseif tool.finished_at and now - tool.finished_at < 0.9 then
			local burst = math.floor((now - tool.finished_at) * 10)
			for direction = -1, 1, 2 do
				local spark = clamp((direction < 0 and left or right) + direction * burst, 1, buffer.width)
				buffer:set(row, spark, burst < 5 and "✦" or "·", style)
			end
		end
	end
	return true
end

tui._draw_tool_stage = draw_tool_stage

local App = {}
App.__index = App

local STRIP_FLOW_ROWS = 4
local STRIP_ROWS = STRIP_FLOW_ROWS + 4

local function flywheel_anchor(width, rows, wheel, time)
	local compact = width < 72
	local margin = compact and 5 or 11
	local seed_phase = (tonumber(wheel and wheel.seed) or 0) * 0.013
	local release = tonumber(wheel and wheel.release) or 0
	local x = width - margin + math.sin(time * 0.73 + seed_phase) * (compact and 0.45 or 0.85) + release * (compact and 2 or 5)
	local y = (rows + 1) / 2 + math.sin(time * 0.91 + seed_phase * 1.7) * 0.32
	return x, y, compact
end

local function flywheel_style(phase, quiet)
	local attrs = quiet and { "dim" } or { "bold" }
	if phase == "release_cancelled" then return rgb(76, 119, 129, attrs) end
	if phase == "harvest" then return rgb(91, 205, 201, attrs) end
	return rgb(181, 137, 218, attrs)
end

local function draw_flywheel(buffer, width, rows, wheel, time)
	if not wheel or rows < 3 then return false end
	local centre_x, centre_y, compact = flywheel_anchor(width, rows, wheel, time)
	local seed = tonumber(wheel.seed) or 0
	local release = clamp(tonumber(wheel.release) or 0, 0, 1)
	local birth = clamp(tonumber(wheel.birth) or 0, 0, 1)
	local eased_birth = 1 - (1 - birth) ^ 3
	local radius_x = (compact and 3.6 or 8.2) * eased_birth * (1 + release * 0.7)
	local radius_y = 1.3 * eased_birth * (1 + release * 0.35)
	local speed = 1.25
	local rotation = time * speed + seed * 0.021
	local glyphs = { "·", "⠁", "⠂", "⠄", "⡀", "⠐" }
	local points = compact and 8 or 13
	local pulse = math.floor((time * 4 + seed) % points) + 1
	for index = 1, points do
		local missing = (index * 11 + seed) % 7 == 0
		local shed_threshold = ((index * 29 + seed * 7) % 101) / 100
		if not missing and shed_threshold >= release * 0.88 then
			local angle = rotation + (index - 1) / points * math.pi * 2
			local individual = math.sin(time * (0.43 + index * 0.017) + seed + index) * 0.34
			local x = clamp(math.floor(centre_x + math.cos(angle) * (radius_x + individual) + 0.5), 1, width)
			local y = clamp(math.floor(centre_y + math.sin(angle) * radius_y + 0.5), 1, rows)
			local bright = index == pulse and release < 0.72
			local glyph = bright and "◇"
				or glyphs[(index + seed) % #glyphs + 1]
			buffer:set(y, x, glyph, flywheel_style(wheel.phase, not bright))
		end
	end

	local centre_row = clamp(math.floor(centre_y + 0.5), 1, rows)
	local centre_col = clamp(math.floor(centre_x + 0.5), 1, width)
	if release < 0.8 then
		local core_glyph = wheel.phase == "release_cancelled" and "·" or "◇"
		buffer:set(centre_row, centre_col, core_glyph, flywheel_style(wheel.phase, false))
	end
	if not compact and release < 0.48 then
		local labels = { task = "task", harvest = "evidence" }
		local label = labels[wheel.phase]
		if label then
			local label_width = lcatui.width.string(label)
			local label_col = clamp(math.floor(centre_x - label_width / 2 + 0.5), 1, width - label_width + 1)
			buffer:write(centre_row, label_col, label, flywheel_style(wheel.phase, false), label_width)
		end
	end
	return true
end

tui._draw_flywheel = draw_flywheel

function App.new(opts)
	opts = opts or {}
	local backend = opts.backend or lcatui.backends.posix.new()
	local effect_random = opts.effect_random or math.random
	local requested_effect = opts.effect or "auto"
	local effect_auto = requested_effect == "auto"
	local effect = effect_auto and EFFECT_NAMES[effect_random(#EFFECT_NAMES)] or requested_effect
	if not tui_effects.known(effect) then
		error("unknown TUI effect '" .. tostring(effect) .. "' (choose " .. table.concat(EFFECT_NAMES, ", ") .. ")")
	end
	local state = opts.state or State.new()
	return setmetatable({
		backend = backend,
		terminal = opts.terminal or lcatui.Terminal.new(backend),
		renderer = opts.renderer or lcatui.Renderer.new(backend, {
			mode = "inline",
			synchronized = true,
		}),
		state = state,
		editor = opts.editor or Editor.new(opts.history),
		input = nil,
		flow = nil,
		effect = effect,
		effect_auto = effect_auto,
		effect_auto_turns = 0,
		effect_random = effect_random,
		effect_transition_from = nil,
		effect_transition_age = 0,
		flow_width = nil,
		flow_height = nil,
		flow_time = 0,
		palette = { r = 55, g = 151, b = 157 },
		size_provider = opts.size_provider,
		logged_size = nil,
		logged_layout = nil,
		last_frame = socket.gettime(),
		fps_clock = opts.fps_clock or uv.hrtime,
		fps_intervals = 0,
		last_resize = 0,
		frame_timer = nil,
		stdin_poll = nil,
		input_reader = opts.input_reader,
		exit_requested = false,
		cancel_requested = false,
		submitted = {},
		busy = false,
		fatal_error = nil,
		foreground_streams = {},
		celebration_active = false,
		motion_scale = 1,
		divider_label = nil,
		divider_kind = "quiet",
		divider_previous_label = nil,
		divider_molt_started = 0,
		focus_path = nil,
		tool_stage = opts.tool_stage == true,
		staged_tools = {},
		staged_batch_id = nil,
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
		local mode = tui_effects.native(self.effect) and self.effect or "drift"
		self.flow = lcatui.Current.new(width, rows, { seed = 19, mode = mode })
		self.flow_width, self.flow_height = width, rows
		self.flow_time = self.flow_time or 0
	end
	return self.flow
end

function App:set_effect(effect)
	if not tui_effects.known(effect) then
		return nil, "unknown effect '" .. tostring(effect) .. "' (choose " .. table.concat(EFFECT_NAMES, ", ") .. ")"
	end
	if effect == self.effect then return true end
	self.effect_transition_from = self.effect
	self.effect_transition_age = 0
	self.effect = effect
	if self.flow and self.flow.set_mode and tui_effects.native(effect) then
		local ok, err = self.flow:set_mode(effect)
		if not ok then return nil, err end
	end
	self.state:notice("animation · " .. effect)
	return true
end

function App:next_effect()
	local current = 1
	for index, name in ipairs(EFFECT_NAMES) do if name == self.effect then current = index; break end end
	return self:set_effect(EFFECT_NAMES[current % #EFFECT_NAMES + 1])
end

function App:set_effect_auto(enabled)
	self.effect_auto = enabled ~= false
	self.effect_auto_turns = 0
	self.state:notice("animation auto · " .. (self.effect_auto and "on" or "off") .. " · " .. self.effect)
	return true
end

function App:set_tool_stage(enabled)
	self.tool_stage = enabled == true
	self.state:notice("tool stage · " .. (self.tool_stage and "on" or "off"))
	return true
end

function App:auto_advance_effect()
	if not self.effect_auto then return false end
	if #self.state:active_tools() > 0 or self.state.failure or next(self.state.recoveries) ~= nil then return false end
	self.effect_auto_turns = self.effect_auto_turns + 1
	if self.effect_auto_turns == 1 or self.effect_random() >= 0.2 then return false end
	local alternatives = {}
	for _, name in ipairs(EFFECT_NAMES) do
		if name ~= self.effect then alternatives[#alternatives + 1] = name end
	end
	return self:set_effect(alternatives[self.effect_random(#alternatives)])
end

function App:focus_next()
	local files = self.state:working_files(6)
	if #files == 0 then self.focus_path = nil; self.state:notice("working set is empty"); return false end
	local current = 0
	for index, memory in ipairs(files) do if memory.path == self.focus_path then current = index; break end end
	if current >= #files then self.focus_path = nil
	else self.focus_path = files[current + 1].path end
	return self.focus_path ~= nil
end

function App:_focus_status(now)
	if not self.focus_path then return nil end
	local memory = self.state.file_memory[self.focus_path]
	if not memory then return nil end
	local files, index = self.state:working_files(6), 1
	for candidate, item in ipairs(files) do if item.path == memory.path then index = candidate; break end end
	local detail = { "focus " .. tostring(index) .. "/" .. tostring(#files), memory.verb or "file", memory.filename, memory.state }
	if memory.summary and memory.summary ~= "" then detail[#detail + 1] = memory.summary end
	if memory.touched_at then detail[#detail + 1] = format_duration(math.max(0, now - memory.touched_at)) .. " ago" end
	return table.concat(detail, " · ")
end

function App:_divider_transition(label, kind)
	kind = kind or "quiet"
	if label ~= self.divider_label or kind ~= self.divider_kind then
		self.divider_previous_label = (self.divider_kind == "task" and kind == "task")
			and self.divider_label and label and self.divider_label ~= label and self.divider_label or nil
		self.divider_label, self.divider_kind = label, kind
		self.divider_molt_started = self.flow_time
	end
	local progress = 1
	if self.divider_previous_label then
		progress = clamp((self.flow_time - self.divider_molt_started) / 0.85, 0, 1)
		if progress >= 1 then self.divider_previous_label = nil end
	end
	return self.divider_label, self.divider_kind, self.divider_previous_label, progress
end

-- Advance once per scheduled frame. Painting must never age or expire activity.
function App:advance(frame_dt)
	local width, terminal_height = self:_size()
	local height = math.min(STRIP_ROWS, terminal_height)
	local world_rows = math.max(3, height - 4)
	local input_lines, editor_row, editor_col = self.editor:layout(width - 10,
		math.max(1, math.min(5, terminal_height - height + 1)))
	height = height + #input_lines - 1
	local top_divider_row, flow_top = 1, 2
	local divider_row, input_row, status_row = world_rows + 2, world_rows + 3, height
	local notice = self.state.notices[#self.state.notices]
	local state_now = self.state.clock()
	local flywheel = self.state:flywheel_visual(state_now)
	if self.state.flywheel and not flywheel then self.state.flywheel = nil end
	if notice and notice.created_at and state_now - notice.created_at > 8 then notice = nil end
	local flow = self:_flow_for(width, world_rows)
	local now = socket.gettime()
	local dt = frame_dt == nil and clamp(now - self.last_frame, 0, 0.1) or frame_dt
	self.last_frame = now
	local user_typing = self.editor:text() ~= ""
	if user_typing or (self.focus_path and not self.state.file_memory[self.focus_path]) then self.focus_path = nil end
	self.state:set_input(self.editor:text(), self.editor:display_cursor())
	local target_motion_scale = user_typing and 0.28 or 1
	local motion_ease = 1 - math.exp(-(user_typing and 8 or 5) * math.max(0, dt))
	self.motion_scale = self.motion_scale + (target_motion_scale - self.motion_scale) * motion_ease
	local visual_dt = dt * self.motion_scale
	self.flow_time = self.flow_time + visual_dt
	local live_streams = {}
	for _, stream in ipairs(self.state.streams) do
		stream.age = stream.age + dt
		stream.motion_age = (stream.motion_age or stream.age - dt) + visual_dt
		if not stream.duration or stream.age <= stream.duration then live_streams[#live_streams + 1] = stream end
	end
	self.state.streams = live_streams
	local live_handoffs = {}
	for _, handoff in ipairs(self.state.handoffs) do
		handoff.age = handoff.age + dt
		if handoff.age <= handoff.duration then live_handoffs[#live_handoffs + 1] = handoff end
	end
	self.state.handoffs = live_handoffs
	local live_transfers = {}
	for _, transfer in ipairs(self.state.transfers) do
		transfer.age = transfer.age + dt
		if transfer.age <= transfer.duration then live_transfers[#live_transfers + 1] = transfer end
	end
	self.state.transfers = live_transfers
	local foreground_streams, foreground_set, ordered_streams, foreground_rows = conduct_streams(live_streams, world_rows)
	self.foreground_streams = foreground_streams
	local listening = self.state.mode == "listening"
	local listening_breath = listening and (0.5 + 0.5 * math.sin(self.flow_time * 1.7)) or 0
	local failed = self.state.disturbance > 0
	local active = not listening and self.state.mode ~= "complete" and self.state.mode ~= "cancelled"
	-- Let the completion summary take over without lingering tool labels.
	-- Keep active tools and failure details visible; retain history for the inspector.
	local completing = self.state.completion_summary ~= nil and not self.state.failure
	local stage_candidates = completing and self.state:active_tools() or self.state.tools
	local visible_tools = {}
	for index = #stage_candidates, 1, -1 do
		local tool = stage_candidates[index]
		if tool.status == "active" or (tool.finished_at and state_now - tool.finished_at < 4) then
			visible_tools[#visible_tools + 1] = tool
			if #visible_tools >= world_rows then break end
		end
	end
	local staged_tools, staged_batch_id = {}, nil
	if self.tool_stage then staged_tools, staged_batch_id = tool_stage_batch(stage_candidates, state_now) end
	self.staged_tools, self.staged_batch_id = staged_tools, staged_batch_id
	local vortices = {}
	local tool_positions = {}
	for _, tool in ipairs(visible_tools) do
		local row = clamp(tool.lane or 1, 1, world_rows)
		local x = tool_position(tool.id, width, 1, world_rows)
		for index = #live_streams, 1, -1 do
			if live_streams[index].tool == tool then
				x = stream_position(live_streams[index], width)
				row = foreground_rows[live_streams[index]] or stream_row(live_streams[index], world_rows)
				break
			end
		end
		vortices[#vortices + 1] = {
			id = tool.id,
			x = x, y = row, radius = tool.status == "active" and 7 or 4,
			strength = tool.status == "active" and 1.2 or 0.25,
			failed = tool.status == "error",
			resolved = tool.status == "ok",
			direction = (#tool.id % 2 == 0) and -1 or 1,
		}
		tool_positions[tool.id] = { x = x, y = row }
	end
	local memory_positions = {}
	for _, memory in ipairs(self.state:working_files(6)) do
		local x, y = tool_position("file:" .. memory.path, width, 1, world_rows)
		memory_positions[memory.path] = { x = x, y = y, memory = memory }
		vortices[#vortices + 1] = {
			id = "file:" .. memory.path, x = x, y = y,
			radius = memory.state == "failed" and 8 or memory.state == "changed" and 6 or 4,
			strength = memory.state == "dormant" and 0.12 or memory.state == "read" and 0.22 or 0.46,
			failed = memory.state == "failed" or memory.state == "read_error" or memory.scar == true,
			resolved = memory.state == "verified", memory = true,
		}
	end
	if flywheel then
		local wheel_x, wheel_y = flywheel_anchor(width, world_rows, flywheel, self.flow_time)
		vortices[#vortices + 1] = {
			id = "flywheel:" .. tostring(flywheel.seed),
			x = wheel_x, y = wheel_y,
			radius = 5 + flywheel.birth * 4,
			strength = 0.55 * (1 - flywheel.release),
			direction = 1,
		}
	end
	if failed then
		vortices[#vortices + 1] = { id = "failure", x = width * 0.5, y = world_rows * 0.5, radius = 15, strength = 1.7, direction = -1, failed = true }
	end
	local scene = {
		activity = active and (user_typing and 0.3 or 0.88) or listening and (0.19 + listening_breath * 0.08) or 0.18,
		active = active,
		listening = listening,
		failed = failed,
		proof = self.state.proof,
		breath = listening_breath,
		center_x = width * 0.5,
		center_y = listening and world_rows * 0.64 or world_rows * 0.5,
		vortices = vortices,
	}
	flow:step(visual_dt, scene)
	if self.effect == "duet" or self.effect_transition_from == "duet" then
		scene.tools, scene.turn = self.state.tools, self.state.turn_sequence
		self.duet = tui_effects.step_duet(self.duet, visual_dt, scene)
	else
		self.duet = nil
	end

	local target_palette = listening and { r = 55, g = 151, b = 157 }
		or self.state.proof > 0 and { r = 62, g = 205, b = 153 }
		or failed and { r = 205, g = 66, b = 101 }
		or active and { r = 132, g = 69, b = 171 }
		or { r = 46, g = 105, b = 112 }
	local palette_mix = 1 - math.exp(-(failed and 5.5 or 2.8) * math.max(0, dt))
	for channel, target in pairs(target_palette) do
		self.palette[channel] = self.palette[channel] + (target - self.palette[channel]) * palette_mix
	end
	if self.effect_transition_from then
		self.effect_transition_age = self.effect_transition_age + visual_dt
		if self.effect_transition_age >= 0.72 then self.effect_transition_from = nil end
	end
	local label, kind = self.state:divider_status(state_now)
	local current_label, current_kind, previous_label, molt_progress = self:_divider_transition(label, kind)
	local completion_age = state_now - (self.state.assistant_completed_at or state_now)
	self.celebration_active = not self.state.failure and self.state.completion_summary ~= nil
		and completion_age >= 0.68 and completion_age <= 0.68 + 1.05
	scene.core_x, scene.core_y, scene.threshold = width * 0.5, world_rows * 0.47, 0.13
	scene.style = rgb(math.floor(self.palette.r + 0.5), math.floor(self.palette.g + 0.5), math.floor(self.palette.b + 0.5))
	self.frame = {
		width = width, terminal_height = terminal_height, height = height, world_rows = world_rows,
		input_lines = input_lines, editor_row = editor_row, editor_col = editor_col,
		top_divider_row = top_divider_row, flow_top = flow_top, divider_row = divider_row,
		input_row = input_row, status_row = status_row, notice = notice, now = state_now,
		flywheel = flywheel, flow = flow, scene = scene, active = active,
		live_handoffs = live_handoffs, live_transfers = live_transfers,
		foreground_streams = foreground_streams, foreground_set = foreground_set,
		ordered_streams = ordered_streams, foreground_rows = foreground_rows,
		visible_tools = visible_tools, staged_tools = staged_tools,
		tool_positions = tool_positions, memory_positions = memory_positions,
		current_label = current_label, current_kind = current_kind,
		previous_label = previous_label, molt_progress = molt_progress,
		displayed_phase = self.state:display_model_phase(state_now),
		focus_status = self:_focus_status(state_now),
	}
end

-- Repaint the prepared frame without advancing animation or semantic state.
-- Renderer bookkeeping (cursor anchoring, diff buffers) remains an IO concern.
function App:draw()
	local frame = assert(self.frame, "advance must prepare a frame before drawing")
	local width, terminal_height, height, world_rows = frame.width, frame.terminal_height, frame.height, frame.world_rows
	local input_lines, editor_row, editor_col = frame.input_lines, frame.editor_row, frame.editor_col
	local top_divider_row, flow_top = frame.top_divider_row, frame.flow_top
	local divider_row, input_row, status_row = frame.divider_row, frame.input_row, frame.status_row
	local notice, state_now, flywheel, flow = frame.notice, frame.now, frame.flywheel, frame.flow
	local live_handoffs, live_transfers = frame.live_handoffs, frame.live_transfers
	local foreground_streams, foreground_set = frame.foreground_streams, frame.foreground_set
	local ordered_streams, foreground_rows = frame.ordered_streams, frame.foreground_rows
	local active, visible_tools, staged_tools = frame.active, frame.visible_tools, frame.staged_tools
	local tool_positions, memory_positions, scene = frame.tool_positions, frame.memory_positions, frame.scene
	local field_style = scene.style
	local screen = lcatui.Buffer.new(width, height)
	local buffer = buffer_view(screen, flow_top - 1, world_rows)
	buffer:fill(1, 1, world_rows, width, " ", field_style)
	local effect_context = {
		flow = flow, scene = scene, time = self.flow_time, duet = self.duet,
	}
	if self.effect_transition_from then
		local progress = clamp(self.effect_transition_age / 0.72, 0, 1)
		local previous = lcatui.Buffer.new(width, world_rows)
		local current = lcatui.Buffer.new(width, world_rows)
		tui_effects.render(self.effect_transition_from, previous, effect_context)
		tui_effects.render(self.effect, current, effect_context)
		for row = 1, world_rows do
			for col = 1, width do
				-- Stable ordered dissolve: cells change once instead of flickering.
				local threshold = ((col * 3 + row * 5) % 13) / 12
				local cell = progress >= threshold and current.rows[row][col] or previous.rows[row][col]
				buffer:set(row, col, cell.char, cell.style)
			end
		end
	else
		tui_effects.render(self.effect, buffer, effect_context)
	end

	local function transfer_point(endpoint)
		if endpoint.kind == "core" then return width * 0.5, (world_rows + 1) * 0.5 end
		if endpoint.kind == "file" then
			local position = memory_positions[endpoint.path]
			if position then return position.x, position.y end
			return tool_position("file:" .. tostring(endpoint.path), width, 1, world_rows)
		end
		if endpoint.kind == "tool" then
			local position = tool_positions[endpoint.id]
			if position then return position.x, position.y end
			return tool_position(tostring(endpoint.id), width, 1, world_rows)
		end
		return width * 0.5, (world_rows + 1) * 0.5
	end

	for _, transfer in ipairs(live_transfers) do
		local x1, y1 = transfer_point(transfer.from)
		local x2, y2 = transfer_point(transfer.to)
		local style = transfer.kind == "proof" and rgb(91, 224, 169, { "bold" })
			or transfer.kind == "write" and rgb(180, 125, 222, { "bold" })
			or rgb(79, 188, 194, { "bold" })
		for mark = 1, 5 do
			local fraction = mark / 6
			local x = clamp(math.floor(x1 + (x2 - x1) * fraction + 0.5), 1, width)
			local y = clamp(math.floor(y1 + (y2 - y1) * fraction + 0.5), 1, world_rows)
			buffer:set(y, x, "·", rgb(style.fg[1], style.fg[2], style.fg[3], { "dim" }))
		end
		local progress = clamp(transfer.age / transfer.duration, 0, 1)
		local eased = 1 - (1 - progress) ^ 2
		local x = clamp(math.floor(x1 + (x2 - x1) * eased + 0.5), 1, width)
		local y = clamp(math.floor(y1 + (y2 - y1) * eased + 0.5), 1, world_rows)
		buffer:set(y, x, transfer.kind == "proof" and "◆" or transfer.kind == "write" and "✦" or "◇", style)
	end

	for _, position in pairs(memory_positions) do
		local memory = position.memory
		local focused = self.focus_path == memory.path
		local marker = focused and "◎" or (memory.state == "failed" or memory.state == "read_error" or memory.scar) and "×"
			or memory.state == "verified" and "✦"
			or memory.state == "changed" and "◆"
			or (memory.state == "editing" or memory.state == "writing") and "◉"
			or memory.state == "read" and "◇" or "·"
		local style = focused and rgb(238, 190, 91, { "bold" })
			or (memory.state == "failed" or memory.state == "read_error" or memory.scar) and rgb(226, 69, 106, { "bold" })
			or memory.state == "verified" and rgb(91, 224, 169, { "bold" })
			or memory.state == "changed" and rgb(180, 125, 222, { "bold" })
			or memory.state == "dormant" and rgb(55, 91, 99, { "dim" })
			or rgb(79, 188, 194)
		buffer:set(position.y, position.x, marker, style)
	end

	for _, handoff in ipairs(live_handoffs) do
		local source_display = stream_display(handoff.source)
		local source_x = stream_position(handoff.source, width, source_display)
		local source_y = foreground_rows[handoff.source] or stream_row(handoff.source, world_rows)
		local target_x, target_y = tool_position(handoff.target.id, width, 1, world_rows)
		target_y = clamp(handoff.target.lane or target_y, 1, world_rows)
		for mark = 1, 4 do
			local fraction = mark / 5
			local x = clamp(math.floor(source_x + (target_x - source_x) * fraction + 0.5), 1, width)
			local y = clamp(math.floor(source_y + (target_y - source_y) * fraction + 0.5), 1, world_rows)
			buffer:set(y, x, "·", rgb(93, 119, 147, { "dim" }))
		end
		local progress = clamp(handoff.age / handoff.duration, 0, 1)
		local eased = 1 - (1 - progress) ^ 2
		local pulse_x = clamp(math.floor(source_x + (target_x - source_x) * eased + 0.5), 1, width)
		local pulse_y = clamp(math.floor(source_y + (target_y - source_y) * eased + 0.5), 1, world_rows)
		buffer:set(pulse_y, pulse_x, "◆", rgb(104, 218, 207, { "bold" }))
	end

	local background_drawn = 0
	for _, stream in ipairs(ordered_streams) do
		if not foreground_set[stream] and background_drawn < 10 then
			local display = stream_display(stream)
			local x = stream_position(stream, width, display)
			local row = stream_row(stream, world_rows)
			buffer:set(row, x, ({ "⠁", "⠂", "⠄", "·" })[stream.id % 4 + 1], rgb(57, 92, 106, { "dim" }))
			background_drawn = background_drawn + 1
		end
	end

	for _, stream in ipairs(foreground_streams) do
		local row = foreground_rows[stream] or stream_row(stream, world_rows)
		local display = stream_display(stream)
		local x, travel_direction = stream_position(stream, width, display)
		local motion_age = visual_age(stream)
		local resolution = stream.kind == "file_resolving"
			and clamp((motion_age - (stream.resolution_motion_age or motion_age)) / 0.9, 0, 1) or nil
		local stream_style = resolution and rgb(
			math.floor(241 + (91 - 241) * resolution),
			math.floor(79 + (224 - 79) * resolution),
			math.floor(115 + (169 - 115) * resolution), { "bold" })
			or (stream.kind == "error" or stream.kind == "file_error") and rgb(241, 79, 115, { "bold" })
			or stream.kind == "file_retry" and rgb(190, 142, 231, { "bold" })
			or stream.kind == "file_refresh" and rgb(79, 188, 194, { "bold" })
			or (stream.kind == "success" or stream.kind == "file_changed") and rgb(91, 224, 169, { "bold" })
			or stream.kind == "task_active" and rgb(192, 154, 232, { "bold" })
			or stream.kind == "task" and rgb(165, 137, 202)
			or stream.kind == "file_read" and rgb(104, 190, 196)
			or (stream.kind == "active" or stream.kind == "file_active") and rgb(72, 221, 228, { "bold" })
			or stream.kind == "request" and rgb(218, 158, 93, { "bold" })
			or rgb(132, 177, 181)
		if stream.file then
			local wake_style = resolution and rgb(57, 151, 117, { "dim" })
				or stream.kind == "file_error" and rgb(176, 61, 91, { "dim" })
				or stream.kind == "file_retry" and rgb(125, 86, 157, { "dim" })
				or stream.kind == "file_refresh" and rgb(54, 126, 137, { "dim" })
				or stream.kind == "file_changed" and rgb(57, 151, 117, { "dim" })
				or rgb(54, 126, 137, { "dim" })
			for wake = 1, 4 do
				local wake_x = x - travel_direction * (wake * 3 + 1)
				local wake_y = clamp(row + ((wake + stream.id) % 3) - 1, 1, world_rows)
				if wake_x >= 1 and wake_x <= width then
					buffer:set(wake_y, wake_x, ({ "⠁", "⠂", "⠄", "·" })[wake], wake_style)
				end
			end
		end
		buffer:write(row, x, display, stream_style, math.max(1, width - x))
	end
	if self.tool_stage and #staged_tools > 0 then
		draw_tool_stage(buffer, staged_tools, self.flow_time, state_now)
	end

	if self.state.failure then
		-- Raw process status belongs in tool details, not the river's center.
		if not tostring(self.state.failure):match("^exit %-?%d+") then
			center(buffer, math.max(1, math.floor(world_rows * 0.5)), "× " .. compact_text(self.state.failure, width - 12), rgb(241, 79, 115, { "bold" }))
		end
	elseif self.state.completion_summary then
		local completion_age = state_now - (self.state.assistant_completed_at or state_now)
		completion_pop(buffer, math.max(1, math.floor(world_rows * 0.5)), self.state.completion_summary, completion_age)
		crystallize(buffer, math.max(1, math.floor(world_rows * 0.5)), self.state.completion_summary,
			completion_age, rgb(91, 224, 169, { "bold" }))
	elseif self.state.cancelled then
		center(buffer, math.max(1, math.floor(world_rows * 0.5)), "cancelled", rgb(218, 158, 93, { "bold" }))
	elseif #visible_tools == 0 and active then
		center(buffer, math.max(1, math.floor(world_rows * 0.5)), frame.displayed_phase, rgb(178, 157, 199, { "bold" }))
	end
	if flywheel and not self.state.failure then
		draw_flywheel(buffer, width, world_rows, flywheel, self.flow_time)
	end

	living_divider(screen, top_divider_row, width, frame.current_label, frame.current_kind, self.flow_time,
		frame.previous_label, frame.molt_progress, self.state.plan)
	if self.inspector_open then
		local tools = self.state.tools
		local selected = self.state.tools_by_id[self.inspector_id or ""] or tools[#tools]
		local index = 0
		for i, tool in ipairs(tools) do if tool == selected then index = i; break end end
		buffer:fill(1, 1, world_rows, width, " ", rgb(211, 208, 216))
		screen:fill(1, 1, 1, width, " ", rgb(105, 222, 222))
		screen:write(1, 2, "TOOLS · Tab next · ↑↓ scroll · Ctrl-T close", rgb(105, 222, 222), width - 2)
		local lines = {}
		if selected then
			lines[1] = tostring(index) .. "/" .. tostring(#tools) .. " · " .. selected.name .. " · " .. selected.status .. " · " .. selected.id
			local text = "args: " .. (selected.args_detail or selected.args or "") .. "\nresult: "
				.. (selected.result_detail or selected.result or "running; no result yet")
			for line in (text .. "\n"):gmatch("(.-)\n") do
				local remaining = line:gsub("\t", "    ")
				repeat
					local piece = lcatui.width.truncate(remaining, width - 4)
					lines[#lines + 1] = piece
					remaining = remaining:sub(#piece + 1)
				until remaining == "" or piece == ""
			end
		else lines[1] = "No tools yet" end
		-- Navigation bookkeeping is UI-only; tool state continues updating underneath.
		self.inspector_id = selected and selected.id or nil
		self.inspector_max_scroll = math.max(0, #lines - world_rows)
		self.inspector_scroll = math.min(self.inspector_scroll or 0, self.inspector_max_scroll)
		for row = 1, world_rows do
			buffer:write(row, 2, lines[row + self.inspector_scroll] or "", rgb(211, 208, 216), width - 2)
		end
	end
	screen:write(divider_row, 1, string.rep("─", width), rgb(49, 65, 76), width)
	if self.session_badge then
		screen:write(divider_row, 3, " " .. self.session_badge .. " ", rgb(255, 153, 0, { "bold" }), math.max(0, width - 4))
	end
	screen:write(input_row, 2, "input › ", rgb(105, 222, 222, { "bold" }), width - 2)
	for index, line in ipairs(input_lines) do
		screen:write(input_row + index - 1, 10, line, rgb(224, 219, 229), width - 10)
	end
	local displayed_phase = frame.displayed_phase
	local status = self.busy and "working · Ctrl-C cancels · input may be queued"
		or "listening · Enter submits · Ctrl-D exits"
	status = self.input_hint or status
	local active_count = #self.state:active_tools()
	if active_count > 0 then status = status .. " · " .. tostring(active_count) .. " tools active" end
	if self.tool_stage and #staged_tools > 0 then
		local resolved = 0
		for _, tool in ipairs(staged_tools) do if tool.status ~= "active" then resolved = resolved + 1 end end
		status = status .. " · stage " .. tostring(resolved) .. "/" .. tostring(#staged_tools)
	end
	local focus_status = frame.focus_status
	if focus_status then status = compact_text(focus_status, width - 18) .. " · Tab next"
	elseif notice then status = compact_text(notice.text, math.max(20, width - #status - 8)) .. " · " .. status end
	local fps_label = self.fps and (tostring(math.floor(self.fps + 0.5)) .. " fps") or "-- fps"
	screen:write(status_row, 2, "LCA · " .. self.effect .. " · " .. displayed_phase .. " · " .. fps_label .. " · " .. status, rgb(74, 93, 105), width - 2)
	local cursor_col = 10 + editor_col
	local cursor_cell = screen.rows[input_row + editor_row - 1][cursor_col]
	local cursor_style = cursor_cell.style or rgb(224, 219, 229)
	cursor_cell.style = { fg = cursor_style.fg, bg = cursor_style.bg, attrs = { "reverse" } }
	local layout_key = table.concat({ width, height, world_rows, top_divider_row, divider_row, input_row, status_row }, ":")
	if layout_key ~= self.logged_layout then
		core.debug_log("[tui] inline strip=%sx%s terminal_height=%s flow_rows=%s divider_row=%s input_row=%s status_row=%s",
			width, height, terminal_height, world_rows, divider_row, input_row, status_row)
		self.logged_layout = layout_key
	end
	-- Reassert ownership before every repaint: terminal resets or other writers
	-- may have made the hardware cursor visible since startup. Hiding is idempotent.
	self.backend:write(lcatui.ansi.hide_cursor)
	if self.redraw_requested then
		-- Repaint only the inline strip at its existing anchor. Clearing or
		-- repositioning the screen would erase committed conversation above it.
		self.backend:write(lcatui.ansi.reset)
		self.renderer.previous = nil
		self.redraw_requested = false
	end
	local flash_style = tui_effects.flash_style(self.effect, self.flow_time)
	if flash_style then
		for row = flow_top, flow_top + world_rows - 1 do
			for col = 1, width do screen.rows[row][col].style = flash_style end
		end
	end
	self.renderer:set_cursor(nil):draw(screen)
end

-- Compatibility entry point for a full frame; use draw() for repaint-only IO.
function App:render(frame_dt)
	self:advance(frame_dt)
	self:draw()
	-- Count completed scheduled frames, not repaint-only draws. Wall time includes stalls.
	local completed = self.fps_clock()
	if self.fps_window_start then
		self.fps_intervals = self.fps_intervals + 1
		local elapsed = completed - self.fps_window_start
		if elapsed >= 1e9 then
			self.fps = self.fps_intervals * 1e9 / elapsed
			self.fps_window_start, self.fps_intervals = completed, 0
		end
	else
		self.fps_window_start = completed
	end
end

function App:commit_lines(lines)
	self.backend:write(lcatui.ansi.hide_cursor)
	self.renderer:set_cursor(nil)
	return self.renderer:commit(lines)
end

function App:commit_user(text)
	return self:commit_lines({ "", "you › " .. response_text(text, 6000), "" })
end

local TRANSCRIPT_STYLES = {
	gutter = rgb(72, 151, 153, { "dim" }),
	label = rgb(190, 142, 231, { "bold" }),
	heading = rgb(238, 190, 91, { "bold" }),
	body = rgb(211, 208, 216),
	strong = rgb(246, 238, 250, { "bold" }),
	code = rgb(102, 211, 205, { "bold" }),
	marker = rgb(176, 128, 219, { "bold" }),
}

local function transcript_paint(text, transcript_style, color)
	return lcatui.style.paint(text, transcript_style, color)
end

local function transcript_inline(text, color)
	if not color then return text end
	local parts, position = {}, 1
	while position <= #text do
		local bold_at = text:find("**", position, true)
		local code_at = text:find("`", position, true)
		local opening, kind
		if bold_at and (not code_at or bold_at < code_at) then opening, kind = bold_at, "bold"
		elseif code_at then opening, kind = code_at, "code" end
		if not opening then
			parts[#parts + 1] = transcript_paint(text:sub(position), TRANSCRIPT_STYLES.body, true)
			break
		end
		if opening > position then
			parts[#parts + 1] = transcript_paint(text:sub(position, opening - 1), TRANSCRIPT_STYLES.body, true)
		end
		local marker_length = kind == "bold" and 2 or 1
		local marker = kind == "bold" and "**" or "`"
		local closing = text:find(marker, opening + marker_length, true)
		if not closing then
			parts[#parts + 1] = transcript_paint(text:sub(opening), TRANSCRIPT_STYLES.body, true)
			break
		end
		parts[#parts + 1] = transcript_paint(text:sub(opening + marker_length, closing - 1),
			kind == "bold" and TRANSCRIPT_STYLES.strong or TRANSCRIPT_STYLES.code, true)
		position = closing + marker_length
	end
	return table.concat(parts)
end

local function wrap_transcript_text(value, columns)
	columns = math.max(1, math.floor(tonumber(columns) or 1))
	local chars = lcatui.width.chars(value)
	if #chars == 0 then return { "" } end
	local wrapped, first = {}, 1
	while first <= #chars do
		local used, last, last_space = 0, first - 1, nil
		for index = first, #chars do
			local char_width = lcatui.width.string(chars[index])
			if used + char_width > columns then break end
			used, last = used + char_width, index
			if chars[index]:match("%s") then last_space = index end
		end
		if last < first then last = first end
		if last == #chars then
			wrapped[#wrapped + 1] = table.concat(chars, "", first, last)
			break
		end
		if last_space and last_space > first then
			wrapped[#wrapped + 1] = table.concat(chars, "", first, last_space - 1)
			first = last_space + 1
			while first <= #chars and chars[first]:match("%s") do first = first + 1 end
		else
			wrapped[#wrapped + 1] = table.concat(chars, "", first, last)
			first = last + 1
		end
	end
	return wrapped
end

-- Recognize tables only when a header is followed by a matching delimiter row.
-- Stack records instead of squeezing prose into terminal-width columns.
local function transcript_table_cells(line)
	line = line:match("^%s*(.-)%s*$")
	if not line:find("|", 1, true) then return nil end
	if line:sub(1, 1) == "|" then line = line:sub(2) end
	local cells, cell, index = {}, {}, 1
	while index <= #line do
		local char = line:sub(index, index)
		if char == "\\" and line:sub(index + 1, index + 1) == "|" then
			cell[#cell + 1] = "|"
			index = index + 2
		elseif char == "|" then
			cells[#cells + 1] = table.concat(cell):match("^%s*(.-)%s*$")
			cell = {}
			index = index + 1
		else
			cell[#cell + 1] = char
			index = index + 1
		end
	end
	if #cell > 0 or line:sub(-1) ~= "|" then
		cells[#cells + 1] = table.concat(cell):match("^%s*(.-)%s*$")
	end
	return cells
end

local function transcript_tables(raw_lines)
	local result, index, fence_char, fence_length = {}, 1, nil, nil
	while index <= #raw_lines do
		local line = raw_lines[index]
		local fence = line:match("^%s*(```+)") or line:match("^%s*(~~~+)")
		if fence then
			if not fence_char then fence_char, fence_length = fence:sub(1, 1), #fence
			elseif fence:sub(1, 1) == fence_char and #fence >= fence_length
				and line:match("^%s*[`~]+%s*$") then fence_char, fence_length = nil, nil end
		end
		local header = not fence_char and not fence and transcript_table_cells(line)
		local separator = header and transcript_table_cells(raw_lines[index + 1] or "")
		local valid = separator and #header >= 2 and #separator == #header
		if valid then
			for _, cell in ipairs(separator) do
				if not cell:match("^:?%-%-%-+:?$") then valid = false end
			end
		end
		local first_row = valid and transcript_table_cells(raw_lines[index + 2] or "")
		if valid and first_row and #first_row == #header then
			result[#result + 1] = "### " .. table.concat(header, " → ")
			index = index + 2
			while index <= #raw_lines do
				local row = transcript_table_cells(raw_lines[index])
				if not row or #row ~= #header then break end
				result[#result + 1] = "- " .. row[1]
				for column = 2, #header do
					local label = #header > 2 and (header[column] .. ": ") or ""
					result[#result + 1] = "  " .. label .. row[column]
				end
				result[#result + 1] = ""
				index = index + 1
			end
		else
			result[#result + 1] = line
			index = index + 1
		end
	end
	return result
end

local function assistant_transcript_lines(text, color, terminal_width)
	terminal_width = math.max(12, math.floor(tonumber(terminal_width) or 80))
	local source, raw_lines = response_text(text, 12000), {}
	for line in (source .. "\n"):gmatch("(.-)\n") do raw_lines[#raw_lines + 1] = line end
	while #raw_lines > 0 and raw_lines[#raw_lines] == "" do table.remove(raw_lines) end
	raw_lines = transcript_tables(raw_lines)
	local lines, first_content = {}, true
	local function gutter(glyph)
		return transcript_paint(glyph, TRANSCRIPT_STYLES.gutter, color)
	end
	for _, line in ipairs(raw_lines) do
		local heading = line:match("^%s*#+%s+(.+)$")
		if first_content and line ~= "" then
			local opening = heading or line
			local pieces = wrap_transcript_text(opening, terminal_width - lcatui.width.string("╭ lca › "))
			for index, piece in ipairs(pieces) do
				local content = heading and transcript_paint(piece, TRANSCRIPT_STYLES.heading, color)
					or transcript_inline(piece, color)
				if index == 1 then
					lines[#lines + 1] = gutter("╭") .. " "
						.. transcript_paint("lca ›", TRANSCRIPT_STYLES.label, color) .. " " .. content
				else
					lines[#lines + 1] = gutter("│") .. " " .. content
				end
			end
			first_content = false
		elseif line == "" then
			lines[#lines + 1] = gutter("│")
		elseif heading then
			for index, piece in ipairs(wrap_transcript_text(heading, terminal_width - lcatui.width.string("├─ "))) do
				lines[#lines + 1] = gutter(index == 1 and "├─" or "│ ") .. " "
					.. transcript_paint(piece, TRANSCRIPT_STYLES.heading, color)
			end
		else
			local indent, marker, spacing, rest = line:match("^(%s*)([-*])(%s+)(.*)$")
			if not marker then indent, marker, spacing, rest = line:match("^(%s*)(%d+%.)(%s+)(.*)$") end
			if marker then
				local visual_marker = (marker == "-" or marker == "*") and "·" or marker
				local leader = indent .. visual_marker .. spacing
				local continuation = indent .. string.rep(" ", lcatui.width.string(visual_marker .. spacing))
				local pieces = wrap_transcript_text(rest, terminal_width - lcatui.width.string("│ " .. leader))
				for index, piece in ipairs(pieces) do
					local content_leader = index == 1
						and (indent .. transcript_paint(visual_marker, TRANSCRIPT_STYLES.marker, color) .. spacing)
						or continuation
					lines[#lines + 1] = gutter("│") .. " " .. content_leader .. transcript_inline(piece, color)
				end
			else
				local padding, body = line:match("^(%s*)(.*)$")
				padding = padding:sub(1, math.max(0, terminal_width - 3))
				for _, piece in ipairs(wrap_transcript_text(body, terminal_width - lcatui.width.string("│ " .. padding))) do
					lines[#lines + 1] = gutter("│") .. " " .. padding .. transcript_inline(piece, color)
				end
			end
		end
	end
	if first_content then
		lines[#lines + 1] = gutter("╭") .. " " .. transcript_paint("lca ›", TRANSCRIPT_STYLES.label, color)
	end
	lines[#lines + 1] = gutter("╰")
	lines[#lines + 1] = ""
	return lines
end

tui._assistant_transcript_lines = assistant_transcript_lines

function App:commit_river(status)
	if not self.state.river_trace or self.river_committed == self.state.turn_sequence then return end
	self.state.river_trace:finish(self.state.clock())
	self.river_committed = self.state.turn_sequence
	-- Plain conversation needs no tool-activity banner between prompt and reply.
	if self.state.river_trace:summary().calls == 0 then return end
	local width = select(1, self:_size())
	local lines = river_divider.render({ width = width, color = self.backend:supports_color(),
		seed = self.river_seed or "lca", turn = self.state.turn_sequence, status = status,
		design = self.state.river_design,
		trace = self.state.river_trace:summary() })
	lines[#lines + 1] = ""
	return self:commit_lines(lines)
end

function App:commit_river_details()
	local trace = self.state.river_trace
	if not trace then return self:commit_lines({ "river › no turn recorded yet", "" }) end
	local width = math.max(12, select(1, self:_size()))
	local color = self.backend:supports_color()
	local lines = { "" }
	local function emit(prefix, text, style)
		local clean = response_text(text, 12000)
		for source in (clean .. "\n"):gmatch("(.-)\n") do
			for _, piece in ipairs(wrap_transcript_text(source, width - lcatui.width.string(prefix))) do
				lines[#lines + 1] = transcript_paint(prefix, TRANSCRIPT_STYLES.gutter, color)
					.. transcript_paint(piece, style or TRANSCRIPT_STYLES.body, color)
				prefix = prefix:gsub("╭", "│"):gsub("├", "│")
			end
		end
	end
	local summary = trace:summary()
	emit("╭ ", "river › turn " .. self.state.turn_sequence, TRANSCRIPT_STYLES.heading)
	emit("│ ", string.format("%d calls · %d failed · %d same args · %.2fs in tools",
		summary.calls, summary.failed, summary.repeated, summary.seconds))
	for _, call in ipairs(trace.calls) do
		emit("│ ", "")
		emit("├ ", string.format("#%d  %s · %s · %.2fs", call.index, call.name, call.status, call.elapsed or 0),
			call.status == "failed" and TRANSCRIPT_STYLES.heading or TRANSCRIPT_STYLES.strong)
		if call.repeated then emit("│   ", "same arguments as #" .. call.repeated, TRANSCRIPT_STYLES.marker) end
		local keys = {}
		for key in pairs(call.args) do keys[#keys + 1] = key end
		table.sort(keys, function(a, b)
			if a == "command" then return b ~= "command" end
			if b == "command" then return false end
			return tostring(a) < tostring(b)
		end)
		for _, key in ipairs(keys) do
			local value = call.args[key]
			local display = type(value) == "table" and json.encode(value) or tostring(value)
			if key == "command" or display:find("\n", 1, true) then
				emit("│   ", tostring(key) .. ":", TRANSCRIPT_STYLES.code)
				emit("│     ", display)
			else emit("│   ", tostring(key) .. ": " .. display) end
		end
		if call.summary and call.summary ~= "" then
			emit("│   ", "result:", TRANSCRIPT_STYLES.code)
			emit("│     ", call.summary)
		end
	end
	emit("│ ", "")
	emit("│ ", "Marks: · call  : overlap  ≈ same args  ! failed  ? unfinished", TRANSCRIPT_STYLES.gutter)
	emit("│ ", "Left to right: call order. Repeated arguments may be necessary.", TRANSCRIPT_STYLES.gutter)
	lines[#lines + 1] = transcript_paint("╰", TRANSCRIPT_STYLES.gutter, color)
	lines[#lines + 1] = ""
	return self:commit_lines(lines)
end

function App:commit_assistant(text)
	local width = select(1, self:_size())
	return self:commit_lines(assistant_transcript_lines(text, self.backend:supports_color(), width))
end

-- Public text accompanying tools belongs in scrollback while the turn is live.
-- Final responses are committed separately after the turn's river summary.
local function message_text(item)
	local parts = {}
	for _, part in ipairs(item.content or {}) do
		if part.type == "output_text" then parts[#parts + 1] = part.text or "" end
	end
	return table.concat(parts)
end

function App:commit_commentary(item, source)
	self.work_update_ids = self.work_update_ids or {}
	local text = message_text(item)
	local key = item.id or text
	if self.work_update_ids[key] then return false end
	local displayed = self:commit_work_update_text(text, source)
	self.work_update_ids[key] = true
	return displayed
end

function App:commit_work_update_text(raw, source)
	local filter = StreamFilter.new()
	local visible = filter:feed(protocol.strip_tool_results(raw or ""))
	local text = visible .. filter:finish()
	if not text:find("%S") then
		core.debug_log("[tui-update] skipped source=%s reason=no_public_text raw_bytes=%d", source, #(raw or ""))
		return false
	end
	self:commit_assistant(text)
	core.debug_log("[tui-update] displayed source=%s bytes=%d", source, #text)
	return true
end

function App:commit_work_update(response)
	if not response then return false end
	local found, displayed = false, false
	for _, item in ipairs(response._output_items or {}) do
		if item.type == "message" and item.phase == "commentary" then
			found = true
			if self:commit_commentary(item, "response_commentary") then displayed = true end
		end
	end
	if found then
		core.debug_log("[tui-update] response commentary=true displayed=%s", tostring(displayed))
		return displayed
	end
	local calls = #(response._native_tool_calls or {})
	if calls == 0 then
		core.debug_log("[tui-update] skipped source=response reason=no_commentary_or_local_tools text_bytes=%d", #(response.text or ""))
		return false
	end
	return self:commit_work_update_text(response.text, "local_tools")
end

function App:final_response_text(response)
	local text = response.text or ""
	-- Providers can concatenate commentary and the answer into response.text.
	-- Remove only exact leading commentary; preserve the answer and its citations.
	for _, item in ipairs(response._output_items or {}) do
		if item.type == "message" and item.phase == "commentary" then
			local prefix = message_text(item)
			if prefix ~= "" and text:sub(1, #prefix) == prefix then
				text = text:sub(#prefix + 1):gsub("^%s+", "")
			end
		end
	end
	return text
end

function App:_handle_action(action)
	if not action then return end
	if action.type == "exit" then self.exit_requested = true
	elseif action.type == "cancel" then self.cancel_requested = true; self.state:cancel("cancelling")
	elseif action.type == "inspect" then
		self.inspector_open = not self.inspector_open
		self.inspector_scroll = 0
		if self.input then self.input.inspect = self.inspector_open end
	elseif action.type == "inspect_next" then
		local tools = self.state.tools
		local index = 0
		for i, tool in ipairs(tools) do if tool.id == self.inspector_id then index = i; break end end
		self.inspector_id = #tools > 0 and tools[index % #tools + 1].id or nil
		self.inspector_scroll = 0
	elseif action.type == "inspect_scroll" then
		self.inspector_scroll = clamp((self.inspector_scroll or 0) + action.delta, 0, self.inspector_max_scroll or 0)
	elseif action.type == "redraw" then self.redraw_requested = true
	elseif action.type == "focus_next" then self:focus_next()
	elseif action.type == "submit" then
		if action.text ~= "" then
			if action.text:match("^/background%s*$") or action.text:match("^/bg%s*$") or action.text:match("^/cloud%s*$") then
				self.background_requested = action.text:match("^/cloud") and "/cloud" or "/background"
			else self.submitted[#self.submitted + 1] = action.text end
			if self.on_queue then self.on_queue(self.submitted) end
		end
	end
end

function App:feed_input(chunk)
	for _, action in ipairs(self.input:feed_chunk(chunk, self.busy)) do self:_handle_action(action) end
end

local function stdin_chunk_reader(read, fd)
	return function()
		local chunk, err = read(fd or 0, 128, -1)
		if chunk then return chunk end
		if err then core.debug_log("[tui] stdin read failed: %s", tostring(err)) end
		return ""
	end
end

tui._stdin_chunk_reader = stdin_chunk_reader

function App:start_io()
	self.input = Input.new(self.editor)
	-- uv_poll makes its descriptor nonblocking. fd 0 often shares an open
	-- file description with stdout, so polling it can truncate large writes.
	-- Open the terminal independently (dup would still share those flags).
	self.stdin_fd = assert(uv.fs_open(self.backend.tty_path or "/dev/tty", "r", 0))
	self:render(0)
	self.frame_timer = uv.new_timer()
	self.frame_timer:start(FRAME_MILLISECONDS, FRAME_MILLISECONDS, function()
		self:drive_frame()
	end)
	self.active_input_reader = self.input_reader or stdin_chunk_reader(uv.fs_read, self.stdin_fd)
	local poll, poll_err = uv.new_poll(self.stdin_fd)
	if poll then
		self.stdin_poll = poll
		self.stdin_poll:start("r", function()
			self:feed_input(self.active_input_reader())
		end)
	else
		core.debug_log("[tui] stdin poll unavailable: %s; using tty stream", tostring(poll_err))
		local stream, stream_err = uv.new_tty(self.stdin_fd, true)
		if not stream then error("cannot initialize terminal input: " .. tostring(stream_err)) end
		self.stdin_stream = stream
		self.stdin_stream:read_start(function(err, chunk)
			if err then
				core.debug_log("[tui] stdin stream failed: %s", tostring(err))
				return
			end
			if chunk and chunk ~= "" then self:feed_input(chunk) end
		end)
	end
end

function App:stop_io()
	if self.frame_timer and not self.frame_timer:is_closing() then
		self.frame_timer:stop(); self.frame_timer:close()
	end
	local fd = self.stdin_fd
	if self.stdin_stream and not self.stdin_stream:is_closing() then
		self.stdin_stream:read_stop()
		self.stdin_stream:close()
		fd = nil
	elseif self.stdin_poll and not self.stdin_poll:is_closing() then
		self.stdin_poll:stop()
		self.stdin_poll:close(function() if fd then uv.fs_close(fd) end end)
	elseif fd then
		uv.fs_close(fd)
	end
	self.stdin_poll, self.stdin_stream, self.frame_timer, self.stdin_fd, self.active_input_reader = nil, nil, nil, nil, nil
	uv.run("nowait")
end

function App:drive_frame()
	local now = socket.gettime()
	local elapsed = clamp(now - self.last_frame, 0, 0.12)
	local ok, err = pcall(function() self:render(elapsed > 0 and elapsed or FRAME_SECONDS) end)
	if not ok then
		self.fatal_error = err
		self.exit_requested = true
		core.debug_log("[tui] fatal frame error: %s", tostring(err))
	end
end

function App:pump()
	uv.run("nowait")
	if self.fatal_error then error(self.fatal_error) end
end

function App:next_submission()
	while #self.submitted == 0 and not self.exit_requested and not self.background_requested do
		uv.run("once")
		if self.fatal_error then error(self.fatal_error) end
	end
	if self.exit_requested then return nil end
	if self.background_requested then local command=self.background_requested;self.background_requested=false;return command end
	return table.remove(self.submitted, 1)
end

tui.App = App

function tui.with_terminal(terminal, renderer, callback)
	local started, start_err = terminal:start({ raw = true })
	if not started then return nil, start_err or "TUI requires an interactive POSIX terminal" end
	local mounted, mount_err = pcall(function()
		-- The input cursor is painted in the buffer; hide the hardware cursor
		-- while inline animation moves the terminal's write position.
		renderer.backend:write(lcatui.ansi.hide_cursor)
		renderer:mount("inline")
	end)
	if not mounted then
		pcall(function() terminal:stop() end)
		return nil, mount_err
	end
	local results = table.pack(xpcall(callback, debug.traceback))
	if not results[1] then core.debug_log("[tui] fatal error: %s", tostring(results[2])) end
	pcall(function() renderer.backend:write(lcatui.ansi.end_synchronized_update) end)
	pcall(function() renderer:commit({}) end)
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

local function command_ui(app)
	local state = app.state
	local facade = {}
	local direct_test = false
	local command_label = "test"
	function facade.muted(text) state:notice(text) end
	function facade.error(text) state:notice("error: " .. tostring(text), "error") end
	function facade.block(text)
		if not direct_test then state:notice(text); return end
		local lines = {}
		for line in (tostring(text) .. "\n"):gmatch("(.-)\n") do
			lines[#lines + 1] = command_label .. " › " .. response_text(line, 4000)
		end
		app:commit_lines(lines)
	end
	function facade.test_begin(command,label)
		command_label = label or "test"
		direct_test = true
		app.busy, app.cancel_requested = true, false
		state.prompt = compact_text(command, 240)
		state.model_phase = "running " .. command_label .. " · Ctrl-C cancels · no model calls"
		app:drive_frame()
	end
	function facade.test_poll()
		app:pump()
		return app.cancel_requested or app.exit_requested
	end
	function facade.test_end()
		direct_test = false
		app.busy, app.cancel_requested = false, false
		state:listen()
		app:drive_frame()
	end
	function facade.compaction(removed, tokens) state:notice("compacted " .. tostring(removed) .. " messages; ~" .. tostring(math.floor((tokens or 0) / 1000)) .. "k tokens remain") end
	function facade.status(session) state:notice("model " .. tostring(session.model) .. " · " .. tostring(session:turn_count()) .. " turns · " .. tostring(session:token_status())) end
	function facade.plan(plan) state.plan = plan; state:notice(tostring(#(plan or {})) .. " plan steps") end
	function facade.jobs(list) state:notice(tostring(#(list or {})) .. " background jobs") end
	function facade.job_detail(job) state:notice((job and job.id or "job") .. " · " .. tostring(job and job.status or "unknown")) end
	function facade.job_output(id, output) state:notice(tostring(id) .. " · " .. compact_text(output, 150)) end
	return facade
end

function App:start_recording(path)
	if self.recording and self.recording.fd then
		self.state:notice("recording already active · /record off first", "error")
		return nil, "recording already active"
	end
	local Recording = require("agent.tui_recording")
	local recording, err = Recording.open(path, { effect = self.effect,
		on_error = function(message)
			self.state:notice("recording stopped: " .. tostring(message), "error")
		end,
	})
	if not recording then
		self.state:notice("cannot record: " .. tostring(err), "error")
		return nil, err
	end
	self.recording = recording:attach(self.state)
	self:commit_lines({ "recording › " .. response_text(recording.path, 500),
		"LOCAL PRIVATE CAPTURE · prompts, tool args/results may contain secrets; no redaction.", "" })
	return true
end

function App:stop_recording()
	if not self.recording then self.state:notice("recording is off"); return true end
	local recording = self.recording
	local ok, err = recording:close()
	self.recording = nil
	self:commit_lines({ "recording saved › " .. response_text(recording.path, 500),
		ok and "" or ("recording stopped early: " .. tostring(err)) })
	return ok, err
end

function tui.run(options)
	options = options or {}
	local history_path = options.history_path or ".lca-history"
	local session = options.session or session_module.create(options)
	local tool_stage = options.tool_stage
	if tool_stage == nil then
		local env = tostring(os.getenv("LCA_TOOL_STAGE") or ""):lower()
		tool_stage = not (env == "0" or env == "false" or env == "off" or env == "no")
	end
	local app = App.new({
		backend = options.backend,
		terminal = options.terminal,
		renderer = options.renderer,
		history = load_history(history_path),
		effect = options.tui_effect or os.getenv("LCA_TUI_EFFECT"),
		tool_stage = tool_stage,
	})
	local background = require("agent.background")
	app.submitted = background.load_queue(session)
	app.on_queue = function(queue) background.save_queue(session, queue) end
	local background_checkpoint, cloud_attach
	local facade = command_ui(app)
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
		local record_path = options.record_path or os.getenv("LCA_TUI_RECORD")
		if record_path and record_path ~= "" then app:start_recording(record_path) end
		app.state:notice(options.session and "session resumed locally" or "fresh session · /resume restores the last session for this project")
		last_auto_compact_messages = #session.messages
		jobs.prune(session.cwd)
		if options.mcp_tool_count and options.mcp_tool_count > 0 then app.state:notice(tostring(options.mcp_tool_count) .. " MCP tools connected") end
		app:start_io()
		while not app.exit_requested do
			app.state:listen()
			local line = app:next_submission()
			if not line then break end
			if line == "/background" or line == "/bg" or line == "/cloud" then
				local ok, value = pcall(function()
                    background.preflight()
                    return background.checkpoint(session, app.submitted)
                end)
				if ok then background_checkpoint = value; cloud_attach = line == "/cloud"; break end
				app.state:notice(tostring(value), "error")
				goto continue
			end
			session.pending_inputs = app.submitted
			if not line:match("^/resume") then background.save_queue(session, app.submitted) end
			app:commit_user(line)
			if line:sub(1, 1) == "/" or line:sub(1, 1) == "!" then
				app.state.prompt = compact_text(line, 240)
				app.state.model_phase = "running command"
				app:drive_frame()
				local requested_effect = line:match("^/effect%s+([%w_-]+)%s*$")
				if line:match("^/record%s*$") or line:match("^/record%s") then
					local value = line:match("^/record%s*(.-)%s*$")
					if value == "off" then app:stop_recording()
					elseif value == "status" or (value == "" and app.recording and app.recording.fd) then
						app:commit_lines({ app.recording and app.recording.fd and ("recording › " .. app.recording.path)
							or "recording off · /record starts; /record off stops", "" })
					else app:start_recording(value ~= "" and value or nil) end
					goto continue
				elseif line:match("^/river%s*$") then
					app:commit_river_details()
					goto continue
				elseif line:match("^/effect%s*$") then
					local auto = app.effect_auto and " · auto" or " · manual"
					app.state:notice("animation · " .. app.effect .. auto .. " · choose " .. table.concat(EFFECT_NAMES, ", "))
					goto continue
				elseif line:match("^/effect[%s]") then
					local changed, effect_err
					if requested_effect == "next" then changed, effect_err = app:next_effect()
					elseif requested_effect == "auto" then changed = app:set_effect_auto(true)
					elseif requested_effect == "manual" or requested_effect == "off" then changed = app:set_effect_auto(false)
					else changed, effect_err = app:set_effect(requested_effect) end
					if not changed then app.state:notice(effect_err, "error") end
					goto continue
				elseif line:match("^/tools%s*$") or line:match("^/stage%s*$") then
					app.state:notice("tool stage · " .. (app.tool_stage and "on" or "off") .. " · /tools on|off")
					goto continue
				elseif line:match("^/tools[%s]") or line:match("^/stage[%s]") then
					local value = line:match("^/%w+%s+(%w+)%s*$")
					if value == "on" then app:set_tool_stage(true)
					elseif value == "off" then app:set_tool_stage(false)
					else app.state:notice("usage: /tools [on|off]", "error") end
					goto continue
				end
				local command_result = commands.dispatch(line, session, facade)
				if line:match("^/resume") then app.submitted = background.load_queue(session) end
				if command_result == true then break end
				if command_result ~= "run" then goto continue end
				line = ""
			else
				session:add_user(line)
			end
			if line ~= "" or session.messages[#session.messages] then
				app:auto_advance_effect()
				app.state:submit(line ~= "" and line or "command request")
				app.work_update_ids = {}
				app.busy, app.cancel_requested = true, false
				-- Acknowledge Enter before provider setup or network waiting can block.
				-- The editor is already empty, so this moves its cursor back to the dock start.
				app:drive_frame()
				local filter = StreamFilter.new()
				local ok, turn_result = pcall(function()
					return core.run_session(session,
						function(delta)
							local visible, activity = filter:feed(delta)
							if activity then app.state:model_activity(activity) end
							if visible ~= "" then app.state:model_stream(visible) end
							app:pump()
						end,
						function(event) app.state:tool_event(event) end,
						function(info) app.state:reviewing(info); filter = StreamFilter.new() end,
						function() app:pump() end,
						{
							cancelled = function() return app.cancel_requested end,
							on_response = function(response)
								app:commit_work_update(response)
								app:pump()
							end,
							on_model_activity = function(activity)
								if activity.type == "assistant_commentary" then
									app:commit_commentary(activity.item, "live_commentary")
								end
								app.state:model_activity(activity)
								app:pump()
							end,
						}
					)
				end)
				app.busy = false
				local turn_cancelled = app.cancel_requested
				local tail = filter:finish()
				if tail ~= "" then app.state:model_stream(tail) end
				if app.cancel_requested then
					app.state:cancel("cancelled by user")
					if session.messages[#session.messages] and session.messages[#session.messages].role == "user" then table.remove(session.messages) end
					app.cancel_requested = false
				elseif ok then
					local final = protocol.strip_tool_results(protocol.strip_tool_calls(app:final_response_text(turn_result)))
					session:add_assistant(turn_result.text, turn_result._output_items)
					local final_usage = type(turn_result._turn_usage) == "table" and turn_result._turn_usage
						or type(turn_result._usage) == "table" and turn_result._usage or nil
					local model_tokens = final_usage and tonumber(final_usage.prompt_tokens)
						or session:estimated_model_input_tokens_usage_aware()
					local cache_percent
					if final_usage and final_usage.cache_available == true and model_tokens and model_tokens > 0 then
						cache_percent = (tonumber(final_usage.cached_tokens) or 0) / model_tokens * 100
					end
					app.state:assistant_complete(final, { tokens = model_tokens, cache_percent = cache_percent })
					app.river_seed = session.id
					app:commit_river()
					app:commit_assistant(final)
					maybe_auto_compact()
				else
					if app.recording then app.recording:record("failure", { text = tostring(turn_result) }) end
					app.state:notice(tostring(turn_result), "error")
					app.state.mode = "failed"
					app:commit_lines({ "error › " .. compact_text(turn_result, 240), "" })
				end
				app.river_seed = session.id
				app:commit_river(turn_cancelled and "interrupted" or not ok and "failed" or nil)
				app:drive_frame()
			end
			::continue::
			session.pending_inputs = app.submitted
			auto_save()
		end
		app:stop_io()
		auto_save()
		save_history(history_path, app.editor.history)
		return true
	end)
	if app.recording then app.recording:close() end
	if background_checkpoint then
		local command=background.command()
		local ok=os.execute(command.." background --checkpoint "..require("agent.util.shell").quote(background_checkpoint)..(cloud_attach and " --attach" or ""))
		if not ok then
            local marker=io.open(session.cwd.."/.lca-handoff.json")
            if marker then marker:close();return nil,"handoff did not complete; session remains paused; use lca recover" end
            return nil,"background setup failed; session is local; use lca --resume .lca-session.json"
        end
	end
	if not result then
		core.debug_log("[tui] exiting after fatal error: %s", tostring(err))
		return nil, err
	end
	return true
end

return tui
