-- Deterministic, static river studies. Geometry and color need no model or clock.
local river = {}
local styles = require("agent.river_styles")
local designs = {
	{ name = "moonlit", palette = { {42, 64, 91}, {45, 141, 155}, {174, 236, 235} } },
	{ name = "estuary", palette = { {57, 59, 114}, {43, 164, 169}, {218, 191, 139} } },
	{ name = "phosphor", palette = { {29, 66, 59}, {53, 153, 111}, {184, 255, 204} } },
	{ name = "dusk", palette = { {75, 49, 92}, {156, 91, 145}, {242, 179, 155} } },
	{ name = "fleuron", palette = {{101,77,48},{202,156,79},{255,226,163}} },
}
for _, design in ipairs(styles.designs) do designs[#designs + 1] = design end
local statuses = { interrupted = true, failed = true }
local function hash(value)
	local result = 2166136261
	for index = 1, #value do result = ((result ~ value:byte(index)) * 16777619) & 0xffffffff end
	return result
end
local function mix(palette, value)
	value = math.max(0, math.min(1, value)) * 2
	local first = math.min(2, math.floor(value) + 1)
	local fraction = value - first + 1
	local rgb = {}
	for channel = 1, 3 do
		rgb[channel] = math.floor(palette[first][channel] * (1 - fraction) + palette[first + 1][channel] * fraction)
	end
	return rgb
end
local function paint(text, rgb, color)
	if not color then return text end
	return string.format("\27[38;2;%d;%d;%dm%s\27[0m", rgb[1], rgb[2], rgb[3], text)
end
function river.names()
	local names = {}
	for _, design in ipairs(designs) do names[#names + 1] = design.name end
	return names
end

local function caption(lines, trace, width, color, ascii)
	if not trace then return end
	local parts = { trace.calls .. " calls" }
	if trace.peak > 1 then parts[#parts + 1] = trace.peak .. " max concurrent" end
	if trace.failed > 0 then parts[#parts + 1] = trace.failed .. " failed" end
	if trace.repeated > 0 then parts[#parts + 1] = trace.repeated .. " same args" end
	if trace.unfinished > 0 then parts[#parts + 1] = trace.unfinished .. " unfinished" end
	if trace.deferred > 0 then parts[#parts + 1] = trace.deferred .. " deferred" end
	parts[#parts + 1] = string.format("%.1fs in tools", trace.seconds)
	parts[#parts + 1] = "/river"
	local text = table.concat(parts, ascii and " / " or " · ")
	local line = ""
	for word in text:gmatch("%S+") do
		if utf8.len(line) + utf8.len(word) + 1 > width and line ~= "" then
			lines[#lines + 1] = paint(line, {119, 139, 150}, color); line = ""
		end
		if utf8.len(word) > width then
			for _, code in utf8.codes(word) do
				if utf8.len(line) == width then lines[#lines + 1] = paint(line, {119,139,150}, color); line = "" end
				line = line .. utf8.char(code)
			end
		else line = line == "" and word or line .. " " .. word end
	end
	if line ~= "" then lines[#lines + 1] = paint(line, {119,139,150}, color) end
end

function river.render(options)
	options = options or {}
	local width = math.max(1, math.min(500, math.floor(tonumber(options.width) or 80)))
	local turn = math.max(1, math.floor(tonumber(options.turn) or 1))
	local seed = hash(tostring(options.seed or "river"))
	local design = designs[(seed + turn - 1) % #designs + 1]
	if options.design then
		for _, candidate in ipairs(designs) do
			if candidate.name == options.design then design = candidate; break end
		end
		assert(design.name == options.design, "unknown river design")
	end
	assert(options.status == nil or statuses[options.status], "unknown river status")
	local label = "turn " .. turn
	if options.status then label = label .. " / " .. options.status end
	if #label + 4 > width then label = options.status or ("t" .. turn) end
	if design.name == 'fleuron' and not options.ascii and width >= 56 and #label + 28 <= width then
		local lines = require('agent.book_engraving').render(width, label)
		for row, line in ipairs(lines) do
			lines[row] = paint(line, design.palette[row == 2 and 3 or 2], options.color)
		end
		caption(lines, options.trace, width, options.color)
		return lines, design.name
	end
	if design.name == 'fleuron' or options.ascii or width < 32 or (design.name == "cat" and #label + 4 + 15 > width) then
		local text = (#label + 4 <= width) and ("-- " .. label .. " " .. string.rep("-", width - #label - 4))
			or label:sub(1, width)
		local lines = { paint(text, design.palette[3], options.color) }
		caption(lines, options.trace, width, options.color, options.ascii or design.name == 'fleuron')
		return lines, design.name
	end
	local phase = (hash(seed .. ":" .. turn) % 6283) / 1000
	local dots, intensity = {}, {}
	for y = 0, 11 do dots[y], intensity[y] = {}, {} end
	local function dot(x, y, brightness)
		x, y = math.floor(x), math.floor(y + 0.5)
		if x >= 0 and x < width * 2 and y >= 0 and y < 12 then
			dots[y][x] = true
			intensity[y][x] = math.max(intensity[y][x] or 0, brightness)
		end
	end
	for x = 0, width * 2 - 1 do
		local t = x / (width * 2 - 1)
		local wave = t * math.pi * 3 + phase
		if design.name == "moonlit" then
			for strand = 0, 4 do
				local y = 5.5 + 3.1 * math.sin(wave + strand * 0.48) + (strand - 2) * 0.65
				if (x + strand * 3) % 11 ~= 0 then dot(x, y, 0.28 + strand * 0.15) end
			end
		elseif design.name == "estuary" then
			local spread = (0.5 + 0.5 * math.sin(t * math.pi * 2 + phase)) ^ 2
			for strand = -2, 2 do
				local y = 5.5 + 1.8 * math.sin(wave) + strand * (0.4 + 1.45 * spread)
				dot(x, y, strand == 0 and 0.95 or (0.36 + 0.12 * (strand + 2)))
			end
		elseif design.name == "phosphor" then
			local y = 4 + 2.4 * math.sin(wave) + 0.8 * math.sin(wave * 2.1)
			for echo = 3, 1, -1 do
				if (x + echo) % (echo + 1) ~= 0 then dot(x, y + echo * 1.25, 0.55 - echo * 0.13) end
			end
			dot(x, y, 0.96)
		elseif design.name == "dusk" then
			for band = 0, 2 do
				local y = 2.2 + band * 3 + 1.9 * math.sin(wave * 0.68 + band * 0.8)
				for thickness = 0, 2 do
					if thickness == 0 or (x + thickness + band) % 3 ~= 0 then
						dot(x, y + thickness * 0.65, 0.25 + band * 0.27 + thickness * 0.06)
					end
				end
			end
		end
	end
	local marks = {}
	if options.trace then
		local events = options.trace.events
		local last = width - (design.name == "cat" and 16 or 1)
		local first = math.min(last, #label + 6)
		for index, event in ipairs(events) do
			local col = first + math.floor((index - 1) * (last - first) / math.max(1, #events - 1))
			local kind = event.status == "failed" and "!" or event.status == "unfinished" and "?"
				or event.repeated and "≈" or (event.overlap or 1) > 1 and ":" or "·"
			local priority = kind == "!" and 5 or kind == "?" and 4 or kind == "≈" and 3 or kind == ":" and 2 or 1
			if not marks[col] or priority > marks[col].priority then marks[col] = { kind = kind, priority = priority } end
			if kind == "!" or kind == "≈" then
				for offset = -2, 2 do dot(col * 2 + offset, 5 + math.abs(offset), 0.65) end
			end
		end
	end
	local bits = { {1, 8}, {2, 16}, {4, 32}, {64, 128} }
	local lines = {}
	for row = 0, 2 do
		local parts = {}
		for col = 0, width - 1 do
			-- A quiet opening in the middle current keeps the label readable.
			if row == 1 and marks[col] then
				local mark = marks[col]
				local rgb = mark.kind == "!" and {221, 164, 91} or mark.kind == "?" and {185, 165, 140}
					or mark.kind == "≈" and {173, 159, 193} or design.palette[2]
				parts[#parts + 1] = paint(mark.kind, rgb, options.color)
			elseif row == 1 and col >= 2 and col < #label + 4 then
				local position = col - 2
				local char
				if position == 0 or position == #label + 1 then char = " "
				else char = label:sub(position, position) end
				parts[#parts + 1] = paint(char, design.palette[3], options.color)
			else
				local mask, brightness = 0, 0
				for dy = 0, 3 do
					for dx = 0, 1 do
						local x, y = col * 2 + dx, row * 4 + dy
						if dots[y][x] then
							mask = mask | bits[dy + 1][dx + 1]
							brightness = math.max(brightness, intensity[y][x])
						end
					end
				end
				local tint = math.max(0, brightness - 0.14 * (0.5 + 0.5 * math.sin(col * 0.11 + phase)))
				local styled, value = styles.cell(design.name, col, row, width, phase)
				if styled then parts[#parts + 1] = paint(styled, mix(design.palette, value), options.color)
				else parts[#parts + 1] = mask == 0 and " " or paint(utf8.char(0x2800 + mask), mix(design.palette, tint), options.color) end
			end
		end
		lines[#lines + 1] = table.concat(parts)
	end
	caption(lines, options.trace, width, options.color)
	return lines, design.name
end
return river
