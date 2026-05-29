local json = require("agent.util.json")

local protocol = {}

local function inside_fenced_code(text, pos)
	local in_fence = false
	local line_start = 1
	while line_start < pos do
		local line_end = text:find("\n", line_start, true) or (#text + 1)
		if line_start <= pos and text:sub(line_start, line_start + 2) == "```" then
			in_fence = not in_fence
		end
		line_start = line_end + 1
	end
	return in_fence
end

local function find_tool_open(text, search_from)
	while true do
		local tag_start, tag_end, name = text:find('<tool_call%s+name="([^"]+)"%s*>', search_from)
		if not name then
			return nil
		end
		if not inside_fenced_code(text, tag_start) then
			return tag_start, tag_end, name
		end
		search_from = tag_end + 1
	end
end

local RAW_CONTENT_TOOLS = {
	edit = true,
	write = true,
}

local function contains_tool_protocol_tag(text)
	return type(text) == "string"
		and (text:find("<tool_call", 1, true) or text:find("</tool_call>", 1, true))
end

local function only_extra_close_tags(text)
	text = tostring(text or "")
	local pos = 1
	while true do
		local non_ws = text:find("%S", pos)
		if not non_ws then
			return true
		end
		if text:sub(non_ws, non_ws + 11) ~= "</tool_call>" then
			return false
		end
		pos = non_ws + 12
	end
end

local function extra_close_tags_then_prose(text)
	text = tostring(text or "")
	local pos = 1
	local consumed = false
	while true do
		local non_ws = text:find("%S", pos)
		if not non_ws then
			return consumed
		end
		if text:sub(non_ws, non_ws + 11) ~= "</tool_call>" then
			local rest = text:sub(non_ws)
			return consumed and not contains_tool_protocol_tag(rest)
		end
		consumed = true
		pos = non_ws + 12
	end
end

local function find_close_tag_before_boundary(text, after_pos, boundary)
	local closes = {}
	local pos = after_pos
	while true do
		local found = text:find("</tool_call>", pos)
		if not found or found >= boundary then break end
		closes[#closes + 1] = found
		pos = found + 12
	end
	if #closes == 0 then
		return nil
	end
	for _, found in ipairs(closes) do
		local line_start = found
		while line_start > 1 and text:sub(line_start - 1, line_start - 1) ~= "\n" and text:sub(line_start - 1, line_start - 1) ~= "\r" do
			line_start = line_start - 1
		end
		local line_end = text:find("[\r\n]", found + 12) or (boundary + 1)
		local line = text:sub(line_start, line_end - 1)
		local suffix = text:sub(found + 12, boundary - 1)
		if line:match("^%s*</tool_call>%s*$") and not suffix:find("<tool_call", 1, true) then
			return found
		end
	end
	for _, found in ipairs(closes) do
		local suffix = text:sub(found + 12, boundary - 1)
		if only_extra_close_tags(suffix) or extra_close_tags_then_prose(suffix) then
			return found
		end
	end
	for _, found in ipairs(closes) do
		local before = found == 1 and "\n" or text:sub(found - 1, found - 1)
		local after = text:sub(found + 12, found + 12)
		if (before == "\n" or before == "\r") and (after == "" or after == "\n" or after == "\r") then
			return found
		end
	end
	return closes[#closes]
end

-- Find the JSON metadata and optional raw content inside a tool_call tag.
-- Returns: json_body, json_end_pos, raw_content (or nil), close_tag_pos
--
-- Two formats supported:
-- 1. Legacy: all args in JSON (content field inside {})
-- 2. Raw: JSON metadata on first line(s), raw content follows until </tool_call>
local function extract_json_body(text, start_pos, tool_name)
	local i = text:find("{", start_pos)
	if not i then return nil, nil, nil end

	-- Find the FIRST balanced } by counting braces (scan to end of text)
	local depth = 0
	local in_str = false
	local escape = false
	local first_close = nil
	-- Only scan the first line(s) for JSON — stop at a reasonable boundary.
	-- The JSON metadata is always compact (single line), so limit scan to
	-- first 500 chars or first newline after { (whichever is larger).
	local scan_end = math.min(#text, i + 500)
	for pos = i, scan_end do
		local c = text:sub(pos, pos)
		if escape then
			escape = false
		elseif c == "\\" and in_str then
			escape = true
		elseif c == '"' then
			in_str = not in_str
		elseif not in_str then
			if c == "{" then
				depth = depth + 1
			elseif c == "}" then
				depth = depth - 1
				if depth == 0 then
					first_close = pos
					break
				end
			end
		end
	end

	if not first_close then
		-- Couldn't find balanced JSON — try finding last } before first </tool_call>
		local close_tag = text:find("</tool_call>", start_pos)
		if not close_tag then close_tag = #text + 1 end
		for pos = close_tag - 1, i, -1 do
			if text:sub(pos, pos) == "}" then
				return text:sub(i, pos), pos, nil
			end
		end
		return nil, nil, nil
	end

	local json_body = text:sub(i, first_close)

	if not RAW_CONTENT_TOOLS[tool_name] then
		local close_tag = text:find("</tool_call>", first_close + 1)
		return json_body, first_close, nil, close_tag
	end

	-- Find the ACTUAL closing </tool_call>. Literal tool-call tags inside raw
	-- content remain part of the content and are rejected later, but extra
	-- trailing close tags after a completed call are ignored.
	local search_from = first_close + 1
	local next_open = text:find("<tool_call%s+name", search_from)
	local boundary = next_open or (#text + 1)

	local close_tag = find_close_tag_before_boundary(text, search_from, boundary)
	if not close_tag then
		close_tag = #text + 1
	end

	-- Check for raw content after the JSON
	local raw_content = nil
	local after_json = first_close + 1
	if after_json < close_tag then
		local remainder = text:sub(after_json, close_tag - 1)
		-- Strip leading newline
		if remainder:sub(1, 1) == "\n" then
			remainder = remainder:sub(2)
		elseif remainder:sub(1, 2) == "\r\n" then
			remainder = remainder:sub(3)
		end
		-- Strip trailing newline
		if remainder:sub(-1) == "\n" then
			remainder = remainder:sub(1, -2)
		end
		if remainder ~= "" then
			raw_content = remainder
		end
	end

	return json_body, first_close, raw_content, close_tag
end

function protocol.extract_tool_call(text)
	local _, tag_end, name = find_tool_open(text, 1)
	if not name then
		return nil
	end

	local body, _, raw_content = extract_json_body(text, tag_end + 1, name)
	if not body then
		return nil
	end

	local args = json.object_fields(body)
	if raw_content then
		args._raw_content = raw_content
	end

	return {
		name = name,
		args = args,
		raw = body,
	}
end

function protocol.extract_all_tool_calls(text)
	local calls = {}
	local search_from = 1

	while true do
		local _, tag_end, name = find_tool_open(text, search_from)
		if not name then break end

		local body, body_end, raw_content, close_tag = extract_json_body(text, tag_end + 1, name)
		if body then
			local args = json.object_fields(body)
			if raw_content then
				args._raw_content = raw_content
			end
			calls[#calls + 1] = {
				name = name,
				args = args,
				raw = body,
			}
			search_from = close_tag and (close_tag + 12) or (body_end + 1)
		else
			search_from = tag_end + 1
		end
	end
	return calls
end

function protocol.validate_tool_calls(calls)
	for _, tc in ipairs(calls or {}) do
		local raw_content = tc.args and tc.args._raw_content
		if raw_content and not RAW_CONTENT_TOOLS[tc.name] then
			return false, "tool call " .. tostring(tc.name) .. " contains raw content, but only edit/write support raw content"
		end
		if raw_content and contains_tool_protocol_tag(raw_content) then
			return false, "tool call " .. tostring(tc.name) .. " raw content contains literal <tool_call> markup; split or escape it before editing"
		end
	end
	return true, nil
end

function protocol.count_tool_calls(text)
	local count = 0
	local search_from = 1
	while true do
		local tag_start, tag_end = find_tool_open(text, search_from)
		if not tag_start then break end
		count = count + 1
		search_from = tag_end + 1
	end
	return count
end

-- Find the real </tool_call> close tag before the next <tool_call opens.
local function find_close_tag(text, after_pos)
	local next_open = text:find("<tool_call%s+name", after_pos)
	local boundary = next_open or (#text + 1)
	return find_close_tag_before_boundary(text, after_pos, boundary)
end

function protocol.strip_tool_calls(text)
	local result = text
	while true do
		local tag_start, tag_end = find_tool_open(result, 1)
		if not tag_start then break end
		while tag_start > 1 and result:sub(tag_start - 1, tag_start - 1):match("%s") do
			tag_start = tag_start - 1
		end
		local close = find_close_tag(result, tag_end + 1)
		if close then
			local end_pos = close + 11
			local after_ws = result:find("%S", end_pos + 1)
			if after_ws and after_ws == end_pos + 1 then
				result = result:sub(1, tag_start - 1) .. result:sub(end_pos + 1)
			else
				result = result:sub(1, tag_start - 1) .. result:sub(after_ws or #result + 1)
			end
		else
			break
		end
	end
	result = result:gsub('%s*<thinking>.-</thinking>%s*', "")
	return (result:gsub("^%s+", ""):gsub("%s+$", ""))
end

function protocol.strip_tool_results(text)
	return (text:gsub('%s*<tool_result[^>]*>.-</tool_result>%s*', ""))
end

function protocol.extract_only_tool_calls_text(text)
	local parts = {}
	local search_from = 1

	while true do
		local tag_start, tag_end, name = find_tool_open(text, search_from)
		if not tag_start then break end

		local body, body_end = extract_json_body(text, tag_end + 1, name)
		if body then
			local close = find_close_tag(text, body_end + 1)
			if close then
				parts[#parts + 1] = text:sub(tag_start, close + 11)
				search_from = close + 12
			else
				parts[#parts + 1] = text:sub(tag_start, body_end) .. "\n</tool_call>"
				search_from = body_end + 1
			end
		else
			search_from = tag_end + 1
		end
	end
	return table.concat(parts, "\n")
end

function protocol.tool_result_message(name, result, args)
	local status = result.is_error and "error" or "ok"
	local header = '<tool_result name="' .. name .. '" status="' .. status .. '"'
	if args then
		if args.path then
			header = header .. ' path="' .. args.path .. '"'
		end
		if name == "read" then
			if args.offset then
				header = header .. ' offset="' .. tostring(args.offset) .. '"'
			end
			if args.limit then
				header = header .. ' limit="' .. tostring(args.limit) .. '"'
			end
		end
		if args.command then
			header = header .. ' command="' .. args.command .. '"'
		end
		if args.pattern then
			header = header .. ' pattern="' .. args.pattern .. '"'
		end
	end
	header = header .. ">"
	return table.concat({
		header,
		result.content,
		"</tool_result>",
	}, "\n")
end

return protocol
