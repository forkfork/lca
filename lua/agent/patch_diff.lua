-- Lua port of OpenAI Agents SDK 0.22.3 agents/apply_diff.py (MIT).
-- See PATCH_PARSER.md and licenses/OPENAI_AGENTS_LICENSE for provenance and license.
local M = {}
local END_PATCH, END_FILE = '*** End Patch', '*** End of File'
local terminators = { END_PATCH, '*** Update File:', '*** Delete File:', '*** Add File:' }
local markers = { END_PATCH, '*** Update File:', '*** Delete File:', '*** Add File:', END_FILE }
local function starts(text, prefix) return text:sub(1, #prefix) == prefix end
local function has_prefix(text, prefixes)
	for _, prefix in ipairs(prefixes) do if starts(text, prefix) then return true end end
	return false
end
local function split(text)
	local lines = {}
	for line in (text .. '\n'):gmatch('(.-)\n') do lines[#lines + 1] = line end
	return lines
end
local function fail(message) error(message, 0) end

-- Match Python str.strip's Unicode whitespace, independently of the host locale.
local whitespace = { 0x85, 0xa0, 0x1680, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000 }
for code = 0x2000, 0x200a do whitespace[#whitespace + 1] = code end
for i, code in ipairs(whitespace) do whitespace[i] = utf8.char(code) end
local function trim(text, left)
	while true do
		local before = text
		text = text:gsub('[%s\28-\31]+$', '')
		if left then text = text:gsub('^[%s\28-\31]+', '') end
		for _, space in ipairs(whitespace) do
			if text:sub(-#space) == space then text = text:sub(1, -#space - 1) end
			if left and starts(text, space) then text = text:sub(#space + 1) end
		end
		if text == before then return text end
	end
end
local maps = { function(s) return s end, function(s) return trim(s, false) end, function(s) return trim(s, true) end }
local function find_context(lines, context, start, eof)
	local length = #lines
	if eof and lines[length] == '' then length = length - 1 end
	local function search(first)
		if #context == 0 then return first end
		for _, map in ipairs(maps) do
			for i = first + 1, length - #context + 1 do
				local matches = true
				for j, text in ipairs(context) do
					if map(lines[i + j - 1]) ~= map(text) then matches = false; break end
				end
				if matches then return i - 1 end
			end
		end
		return -1
	end
	if eof then
		local found = search(math.max(0, length - #context))
		if found ~= -1 then return found end
		start = math.min(start, length)
	end
	return search(start)
end
local function advance_anchor(anchor, lines, cursor, required, forward)
	for _, map in ipairs({ maps[1], maps[3] }) do
		if not forward then
			for i = 1, cursor do if map(lines[i]) == map(anchor) then return cursor end end
		end
		for i = cursor + 1, #lines do if map(lines[i]) == map(anchor) then return i end end
	end
	if required then fail('Invalid Anchor ' .. cursor .. ':\n' .. anchor) end
	return cursor
end
local function read_section(lines, index)
	local context, chunks, removed, added = {}, {}, {}, {}
	local mode, first = 'keep', index
	local function flush()
		if #removed > 0 or #added > 0 then
			chunks[#chunks + 1] = { orig_index = #context - #removed, removed = removed, added = added }
			removed, added = {}, {}
		end
	end
	while index <= #lines do
		local raw = lines[index]
		if starts(raw, '@@') or has_prefix(raw, markers) or raw == '***' then break end
		if starts(raw, '***') then fail('Invalid Line: ' .. raw) end
		index = index + 1
		local last = mode
		local line = raw == '' and ' ' or raw
		local prefix, content = line:sub(1, 1), line:sub(2)
		if prefix == '+' then mode = 'add'
		elseif prefix == '-' then mode = 'delete'
		elseif prefix == ' ' then mode = 'keep'
		else fail('Invalid Line: ' .. line) end
		if mode == 'keep' and last ~= mode then flush() end
		if mode == 'delete' then
			removed[#removed + 1] = content
			context[#context + 1] = content
		elseif mode == 'add' then added[#added + 1] = content
		else context[#context + 1] = content end
	end
	flush()
	if lines[index] == END_FILE then return context, chunks, index + 1, true end
	if index == first then fail('Nothing in this section - index=' .. (index - 1) .. ' ' .. (lines[index] or '')) end
	return context, chunks, index, false
end

-- Returns a complete candidate; invalid patches raise an error and never mutate files.
function M.apply(input, diff, mode)
	local newline_source = mode ~= 'create' and input:find('\n', 1, true) and input or diff
	local newline = newline_source:find('\r\n', 1, true) and '\r\n' or '\n'
	local lines = split(diff)
	for i, line in ipairs(lines) do lines[i] = line:gsub('\r+$', '') end
	if lines[#lines] == '' then table.remove(lines) end
	lines[#lines + 1] = END_PATCH
	if mode == 'create' then
		local output = {}
		for _, line in ipairs(lines) do
			if has_prefix(line, terminators) then break end
			if not starts(line, '+') then fail('Invalid Add File Line: ' .. line) end
			output[#output + 1] = line:sub(2)
		end
		return table.concat(output, newline)
	end
	local source = split((input:gsub('\r\n', '\n')))
	local chunks, cursor, index = {}, 0, 1
	while index <= #lines and not has_prefix(lines[index], markers) do
		local anchors, count = {}, 0
		while index <= #lines do
			local line, anchor = lines[index], nil
			if starts(line, '@@ ') then anchor = line:sub(4)
			elseif line == '@@' then anchor = ''
			else break end
			index, count = index + 1, count + 1
			if trim(anchor, true) ~= '' then anchors[#anchors + 1] = anchor end
		end
		if count == 0 and cursor ~= 0 then fail('Invalid Line:\n' .. (lines[index] or '')) end
		for i, anchor in ipairs(anchors) do cursor = advance_anchor(anchor, source, cursor, count > 1, i > 1) end
		local context, section, next_index, eof = read_section(lines, index)
		local found = find_context(source, context, cursor, eof)
		if found == -1 then
			fail((eof and 'Invalid EOF Context ' or 'Invalid Context ') .. cursor .. ':\n' .. table.concat(context, '\n'))
		end
		cursor, index = found + #context, next_index
		for _, chunk in ipairs(section) do
			chunk.orig_index = chunk.orig_index + found
			chunks[#chunks + 1] = chunk
		end
	end
	local output = {}
	cursor = 0
	for _, chunk in ipairs(chunks) do
		if chunk.orig_index > #source then
			fail('applyDiff: chunk.origIndex ' .. chunk.orig_index .. ' > input length ' .. #source)
		end
		if cursor > chunk.orig_index then
			fail('applyDiff: overlapping chunk at ' .. chunk.orig_index .. ' (cursor ' .. cursor .. ')')
		end
		for i = cursor + 1, chunk.orig_index do output[#output + 1] = source[i] end
		for _, line in ipairs(chunk.added) do output[#output + 1] = line end
		cursor = chunk.orig_index + #chunk.removed
	end
	for i = cursor + 1, #source do output[#output + 1] = source[i] end
	return table.concat(output, newline)
end
return M
