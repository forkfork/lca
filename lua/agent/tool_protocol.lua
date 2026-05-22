local json = require("agent.util.json")

local protocol = {}

-- Find the JSON metadata and optional raw content inside a tool_call tag.
-- Returns: json_body, json_end_pos, raw_content (or nil)
--
-- Two formats supported:
-- 1. Legacy: all args in JSON (content field inside {})
-- 2. Raw: JSON metadata on first line(s), raw content follows until </tool_call>
local function extract_json_body(text, start_pos)
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

	-- Find the ACTUAL closing </tool_call> — the LAST one before the next
	-- <tool_call opens (or end of text). Raw content may contain multiple
	-- literal </tool_call> strings (e.g. in code that parses XML tags).
	local search_from = first_close + 1
	local next_open = text:find("<tool_call%s+name", search_from)
	local boundary = next_open or (#text + 1)

	-- Find the last </tool_call> before the boundary
	local close_tag = nil
	local pos = search_from
	while true do
		local found = text:find("</tool_call>", pos)
		if not found or found >= boundary then break end
		close_tag = found
		pos = found + 12
	end

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

	return json_body, first_close, raw_content
end

function protocol.extract_tool_call(text)
	local tag_start, tag_end, name = text:find('<tool_call%s+name="([^"]+)"%s*>')
	if not name then
		return nil
	end

	local body, body_end, raw_content = extract_json_body(text, tag_end + 1)
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
		local tag_start, tag_end, name = text:find('<tool_call%s+name="([^"]+)"%s*>', search_from)
		if not name then break end

		local body, body_end, raw_content = extract_json_body(text, tag_end + 1)
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
			search_from = body_end + 1
		else
			search_from = tag_end + 1
		end
	end
	return calls
end

function protocol.count_tool_calls(text)
	local count = 0
	for _ in text:gmatch('<tool_call%s+name="[^"]+"%s*>') do
		count = count + 1
	end
	return count
end

-- Find the real </tool_call> close tag — the LAST one before the next <tool_call opens.
local function find_close_tag(text, after_pos)
	local next_open = text:find("<tool_call%s+name", after_pos)
	local boundary = next_open or (#text + 1)
	local last_close = nil
	local pos = after_pos
	while true do
		local found = text:find("</tool_call>", pos)
		if not found or found >= boundary then break end
		last_close = found
		pos = found + 12
	end
	return last_close
end

function protocol.strip_tool_calls(text)
	local result = text
	while true do
		local tag_start, tag_end = result:find('%s*<tool_call%s+name="[^"]+"%s*>')
		if not tag_start then break end
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
		local tag_start, tag_end = text:find('<tool_call%s+name="[^"]+"%s*>', search_from)
		if not tag_start then break end

		local body, body_end = extract_json_body(text, tag_end + 1)
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
