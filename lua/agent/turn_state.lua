local turn_state = {}
turn_state.__index = turn_state

local FRAME_ORDER = {
	intent = 1,
	context = 2,
	plan = 3,
	plan_step = 4,
	tool_batch = 5,
	inspect = 6,
	changes = 7,
	serve = 8,
	verify = 9,
	external = 10,
	return_value = 11,
}

local TOOL_FRAME = {
	ls = "inspect",
	find = "inspect",
	grep = "inspect",
	read = "inspect",
	edit = "changes",
	write = "changes",
	run = "verify",
	shell = "verify",
	job_start = "serve",
	job_status = "serve",
	job_output = "serve",
	job_stop = "serve",
	job_wait = "serve",
	update_plan = "plan",
}

local STATUS_RANK = {
	error = 1,
	cancelled = 2,
	running = 3,
	streaming = 4,
	pending = 5,
	warning = 6,
	ok = 7,
	unknown = 8,
}

local function new_node(kind, label, status)
	return {
		kind = kind,
		label = label or kind,
		status = status or "pending",
		detail = nil,
		evidence = {},
		children = {},
		child_index = {},
		meta = {},
	}
end

local function sort_children(node)
	table.sort(node.children, function(a, b)
		local ar = FRAME_ORDER[a.kind] or 999
		local br = FRAME_ORDER[b.kind] or 999
		if ar == br then
			return tostring(a.label) < tostring(b.label)
		end
		return ar < br
	end)
end

local function ensure_child(node, kind, label)
	local key = kind .. "\0" .. tostring(label or kind)
	local child = node.child_index[key]
	if not child then
		child = new_node(kind, label or kind)
		node.child_index[key] = child
		node.children[#node.children + 1] = child
		sort_children(node)
	end
	return child
end

local function set_status(node, status, detail)
	node.status = status or node.status
	if detail ~= nil then
		node.detail = detail
	end
	return node
end

local function add_evidence(node, value)
	if value and value ~= "" then
		node.evidence[#node.evidence + 1] = tostring(value)
	end
end

local function trim_text(value, max_len)
	value = tostring(value or ""):gsub("\r", ""):gsub("%s+$", "")
	max_len = max_len or 240
	if #value > max_len then
		return value:sub(1, max_len - 3) .. "..."
	end
	return value
end

local function output_headline(value)
	value = tostring(value or ""):gsub("\r", "")
	local fallback = nil
	for line in (value .. "\n"):gmatch("(.-)\n") do
		local cleaned = line:gsub("^%s+", ""):gsub("%s+$", "")
		if cleaned ~= "" then
			fallback = fallback or cleaned
			local lower = cleaned:lower()
			if lower:match("%f[%w]ok%f[%W]")
				or lower:match("%f[%w]pass%f[%W]")
				or lower:match("%f[%w]passed%f[%W]")
				or lower:match("%f[%w]success%f[%W]") then
				return trim_text(cleaned, 80)
			end
		end
	end
	return fallback and trim_text(fallback, 80) or nil
end

local function error_headline(value)
	value = tostring(value or ""):gsub("\r", "")
	local fallback = nil
	local function clean(line)
		return tostring(line or "")
			:gsub("^lua:%s*", "")
			:gsub("^%(command line%):%d+:%s*", "")
			:gsub("^%S+%.lua:%d+:%s*", "")
	end
	for line in (value .. "\n"):gmatch("(.-)\n") do
		local cleaned = line:gsub("^%s+", ""):gsub("%s+$", "")
		if cleaned ~= "" then
			fallback = fallback or cleaned
			local lower = cleaned:lower()
			if lower:find("not found", 1, true)
				or lower:find("no such", 1, true)
				or lower:find("permission denied", 1, true)
				or lower:find("syntax error", 1, true)
				or lower:find("address already in use", 1, true)
				or lower:find("connection refused", 1, true) then
				return trim_text(clean(cleaned), 96)
			end
		end
	end
	return fallback and trim_text(clean(fallback), 96) or nil
end

local function basename(path)
	path = tostring(path or "")
	return path:match("([^/]+)$") or path
end

local function compact_count(noun, count)
	count = tonumber(count) or 0
	return tostring(count) .. " " .. noun .. (count == 1 and "" or "s")
end

local function frame_for_tool(name)
	name = tostring(name or "")
	if name:match("^mcp__") then
		return "external"
	end
	return TOOL_FRAME[name] or "tool_batch"
end

local function event_status(event)
	if event.phase == "start" then
		return "running"
	end
	local result = event.result or {}
	if result.is_error then
		return "error"
	end
	if result.ui_state == "deferred" or result.summary == "dependent batch mutation" then
		return "warning"
	end
	return "ok"
end

local function event_detail(event)
	local args = event.args or {}
	local result = event.result or {}
	if event.name == "write" or event.name == "edit" then
		return args.path and basename(args.path) or event.name
	elseif event.name == "read" then
		return args.path and basename(args.path) or "read"
	elseif event.name == "grep" then
		return args.pattern and ("/" .. tostring(args.pattern) .. "/") or "grep"
	elseif event.name == "ls" or event.name == "find" then
		return args.path or "."
	elseif event.name == "run" or event.name == "shell" then
		local command = tostring(args.command or event.name):gsub("%s+", " ")
		if #command > 48 then
			command = command:sub(1, 45) .. "..."
		end
		return command
	elseif event.name == "job_start" then
		return "background job"
	elseif event.name == "update_plan" and result.plan then
		return compact_count("step", #result.plan)
	elseif result.summary then
		return result.summary
	end
	return event.name
end

local function worst_status(statuses)
	local best = "ok"
	local best_rank = STATUS_RANK[best]
	for _, status in ipairs(statuses or {}) do
		local rank = STATUS_RANK[status] or STATUS_RANK.unknown
		if rank < best_rank then
			best = status
			best_rank = rank
		end
	end
	return best
end

local function summarize_frame(node)
	local counts = node.meta.counts or {}
	if node.kind == "changes" then
		local files = node.meta.files or {}
		local names = {}
		for i = 1, math.min(#files, 3) do
			names[#names + 1] = basename(files[i])
		end
		local suffix = #files > 3 and (" +" .. tostring(#files - 3)) or ""
		if #files > 0 then
			return compact_count("file", #files) .. " saved" .. (#names > 0 and ("  " .. table.concat(names, ", ") .. suffix) or "")
		end
	end
	if node.kind == "inspect" then
		return compact_count("lookup", node.meta.total or 0)
	elseif node.kind == "verify" then
		return compact_count("check", node.meta.total or 0)
	elseif node.kind == "serve" then
		return compact_count("job action", node.meta.total or 0)
	elseif node.kind == "plan" then
		return node.detail or compact_count("update", node.meta.total or 0)
	elseif node.kind == "plan_step" then
		return node.detail or node.label
	elseif node.kind == "external" then
		return compact_count("external call", node.meta.total or 0)
	elseif node.kind == "tool_batch" then
		if (node.status == "cancelled" or node.status == "error") and node.detail then
			return node.detail
		end
			local discovered = tonumber(node.meta.discovered) or 0
			local closed = tonumber(node.meta.closed) or 0
			if discovered > 0 then
				closed = math.min(closed, discovered)
				return compact_count("tool", discovered) .. ", " .. tostring(closed) .. " closed"
			end
	end
	if node.detail then
		return node.detail
	end
	if counts and node.meta.total then
		return compact_count("event", node.meta.total)
	end
	return nil
end

local function plan_status(status)
	status = tostring(status or "pending")
	if status == "completed" then
		return "ok"
	elseif status == "in_progress" then
		return "running"
	elseif status == "cancelled" then
		return "cancelled"
	end
	return "pending"
end

local function quote(value)
	value = tostring(value or "")
	value = value:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n")
	return '"' .. value .. '"'
end

local function status_expr(node)
	local summary = summarize_frame(node)
	if summary and summary ~= "" then
		return node.status .. "(" .. quote(summary) .. ")"
	end
	return node.status .. "()"
end

local function render_node(node, indent, lines, opts)
	opts = opts or {}
	indent = indent or ""
	if #node.children == 0 or (opts.collapse_ok ~= false and node.status == "ok" and node.kind ~= "turn") then
		lines[#lines + 1] = indent .. node.kind .. " = " .. status_expr(node)
		return
	end
	lines[#lines + 1] = indent .. node.kind .. " {"
	for _, child in ipairs(node.children) do
		render_node(child, indent .. "  ", lines, opts)
	end
	local summary = summarize_frame(node)
	if summary and summary ~= "" and node.kind ~= "turn" then
		lines[#lines + 1] = indent .. "  return " .. status_expr(node)
	end
	lines[#lines + 1] = indent .. "}"
end

local function snapshot_node(node)
	local children = {}
	for i, child in ipairs(node.children or {}) do
		children[i] = snapshot_node(child)
	end
	local evidence = {}
	for i, item in ipairs(node.evidence or {}) do
		evidence[i] = item
	end
	local meta = {}
	for key, value in pairs(node.meta or {}) do
		if type(value) ~= "table" then
			meta[key] = value
		else
			local copy = {}
			for k, v in pairs(value) do
				copy[k] = v
			end
			meta[key] = copy
		end
	end
	return {
		kind = node.kind,
		label = node.label,
		status = node.status,
		detail = node.detail,
		summary = summarize_frame(node),
		evidence = evidence,
		meta = meta,
		children = children,
	}
end

local function summary_line(node)
	local summary = summarize_frame(node)
	if summary and summary ~= "" then
		return node.kind .. "=" .. node.status .. "(" .. summary .. ")"
	end
	return node.kind .. "=" .. node.status
end

local function collect_summary_lines(node, lines)
	if node.kind ~= "turn" then
		lines[#lines + 1] = summary_line(node)
	end
	for _, child in ipairs(node.children or {}) do
		collect_summary_lines(child, lines)
	end
end

function turn_state.new(opts)
	opts = opts or {}
	local self = setmetatable({
		root = new_node("turn", opts.label or "turn", "running"),
		tool_stack = {},
		active_plan_node = nil,
	}, turn_state)
	if opts.intent and opts.intent ~= "" then
		self:set_intent(opts.intent)
	end
	return self
end

function turn_state:set_intent(text)
	local node = ensure_child(self.root, "intent", "intent")
	set_status(node, "ok", tostring(text or ""))
	return node
end

function turn_state:stream_tool_open(name, detail)
	local node = ensure_child(self.root, "tool_batch", "tool_batch")
	node.meta.discovered = (tonumber(node.meta.discovered) or 0) + 1
	node.meta.current = detail or name
	node.meta.stream_counts = node.meta.stream_counts or {}
	node.meta.stream_counts[name or "tool"] = (tonumber(node.meta.stream_counts[name or "tool"]) or 0) + 1
	set_status(node, "streaming", summarize_frame(node))
	self.tool_stack[#self.tool_stack + 1] = { name = name, detail = detail }
	return node
end

function turn_state:stream_tool_progress(detail)
	local node = ensure_child(self.root, "tool_batch", "tool_batch")
	node.meta.current = detail or node.meta.current
	set_status(node, "streaming", summarize_frame(node))
	return node
end

function turn_state:stream_tool_close()
	local node = ensure_child(self.root, "tool_batch", "tool_batch")
	local discovered = tonumber(node.meta.discovered) or 0
	local closed = (tonumber(node.meta.closed) or 0) + 1
	node.meta.closed = discovered > 0 and math.min(closed, discovered) or closed
	table.remove(self.tool_stack)
	local status = discovered > 0 and node.meta.closed >= discovered and "ok" or "streaming"
	set_status(node, status, summarize_frame(node))
	return node
end

function turn_state:cancel(reason, meta)
	local node = ensure_child(self.root, "tool_batch", "tool_batch")
	if type(meta) == "table" then
		for key, value in pairs(meta) do
			node.meta[key] = value
		end
	end
	set_status(node, "cancelled", reason or summarize_frame(node))
	set_status(self.root, "cancelled", reason)
	return node
end

function turn_state:tool_event(event)
	event = event or {}
	local frame = frame_for_tool(event.name)
	local parent = self.active_plan_node or self.root
	if frame == "plan" then
		parent = self.root
	end
	local node = ensure_child(parent, frame, frame)
	node.meta.total = (tonumber(node.meta.total) or 0) + (event.phase == "start" and 0 or 1)
	node.meta.counts = node.meta.counts or {}
	node.meta.statuses = node.meta.statuses or {}
	if event.phase ~= "start" then
		node.meta.counts[event.name or "tool"] = (node.meta.counts[event.name or "tool"] or 0) + 1
	end
	local status = event_status(event)
	if event.phase == "start" then
		node.meta.current = event_detail(event)
		set_status(node, "running", summarize_frame(node) or event_detail(event))
		return node
	end
	node.meta.statuses[#node.meta.statuses + 1] = status
	if (event.name == "write" or event.name == "edit") and event.phase ~= "start" and not (event.result and event.result.is_error) then
		node.meta.files = node.meta.files or {}
		if event.args and event.args.path then
			node.meta.files[#node.meta.files + 1] = event.args.path
		end
	end
	if event.phase ~= "start" then
		node.meta.last_tool = event.name
		node.meta.last_detail = event_detail(event)
		if event.args then
			if event.args.path then
				node.meta.last_path = event.args.path
			end
			if event.args.command then
				node.meta.last_command = trim_text(event.args.command, 180)
			end
			if event.args.pattern then
				node.meta.last_pattern = trim_text(event.args.pattern, 120)
			end
		end
			if event.result then
				node.meta.last_summary = event.result.summary
				if event.result.content and event.result.content ~= "" and event.result.content ~= "(no output)" then
					node.meta.last_output = trim_text(event.result.content, 500)
					node.meta.last_headline = event.result.is_error
						and error_headline(event.result.content)
						or output_headline(event.result.content)
				elseif event.result.summary and event.result.summary ~= "" then
					node.meta.last_headline = event.result.summary
				end
		end
	end
	add_evidence(node, event_detail(event))
	if event.name == "update_plan" and event.result and event.result.plan then
		local completed = 0
		local active = nil
		for index, item in ipairs(event.result.plan) do
			if item.status == "completed" then
				completed = completed + 1
			end
			local step = ensure_child(node, "plan_step", tostring(index) .. ". " .. tostring(item.step or "step"))
			step.meta.index = index
			step.meta.raw_status = item.status
			set_status(step, plan_status(item.status), item.step)
			if item.status == "in_progress" then
				active = step
			end
		end
		node.detail = tostring(completed) .. "/" .. tostring(#event.result.plan) .. " steps"
		self.active_plan_node = active
	end
	set_status(node, worst_status(node.meta.statuses), summarize_frame(node))
	return node
end

function turn_state:set_return(value, status)
	local node = ensure_child(self.root, "return_value", "return")
	set_status(node, status or "ok", value)
	if node.status == "ok" then
		set_status(self.root, "ok", value)
	end
	return node
end

function turn_state:render(opts)
	local lines = {}
	render_node(self.root, "", lines, opts or {})
	return table.concat(lines, "\n")
end

function turn_state:snapshot()
	return snapshot_node(self.root)
end

function turn_state:summary()
	local lines = {}
	collect_summary_lines(self.root, lines)
	return table.concat(lines, "\n")
end

return turn_state
