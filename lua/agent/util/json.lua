local cjson = require("cjson")

local json = {}

if cjson.decode_null_as_lightuserdata then
	cjson.decode_null_as_lightuserdata(true)
end

local cjson_null = cjson.null or (function()
	local sentinel = {}
	return sentinel
end)()

function json.decode(text)
	return cjson.decode(text)
end

function json.encode(value)
	return cjson.encode(value)
end

local STRING_ESCAPES = {
	['"'] = '\\"',
	["\\"] = "\\\\",
	["\b"] = "\\b",
	["\f"] = "\\f",
	["\n"] = "\\n",
	["\r"] = "\\r",
	["\t"] = "\\t",
}

function json.string(value)
	local escaped = tostring(value):gsub('[%z\1-\31\\"]', function(char)
		return STRING_ESCAPES[char] or string.format("\\u%04X", string.byte(char))
	end)
	return '"' .. escaped .. '"'
end

function json.field(body, name)
	local ok, tbl = pcall(cjson.decode, body)
	if not ok or type(tbl) ~= "table" then
		return nil
	end
	local val = tbl[name]
	if val == nil or val == cjson_null then
		return nil
	end
	if type(val) == "table" then
		return cjson.encode(val)
	end
	return tostring(val)
end

function json.number_field(body, name)
	local ok, tbl = pcall(cjson.decode, body)
	if not ok or type(tbl) ~= "table" then
		return nil
	end
	local val = tbl[name]
	if type(val) == "number" then
		return val
	end
	return nil
end

-- Escape raw newlines/tabs inside JSON string values so cjson can parse them.
local function sanitize_json_strings(text)
	local result = {}
	local i = 1
	local len = #text
	local in_string = false
	local escape = false

	while i <= len do
		local c = text:sub(i, i)
		if escape then
			result[#result + 1] = c
			escape = false
		elseif c == "\\" and in_string then
			result[#result + 1] = c
			escape = true
		elseif c == '"' then
			result[#result + 1] = c
			in_string = not in_string
		elseif in_string and c == "\n" then
			result[#result + 1] = "\\n"
		elseif in_string and c == "\r" then
			result[#result + 1] = "\\r"
		elseif in_string and c == "\t" then
			result[#result + 1] = "\\t"
		else
			result[#result + 1] = c
		end
		i = i + 1
	end
	return table.concat(result)
end

local function decode_object(text)
	local ok, tbl = pcall(cjson.decode, text)
	if ok and type(tbl) == "table" then
		return tbl
	end
	-- Try sanitizing raw newlines inside strings
	local sanitized = sanitize_json_strings(text)
	local ok2, tbl2 = pcall(cjson.decode, sanitized)
	if ok2 and type(tbl2) == "table" then
		return tbl2
	end
	return nil
end

-- Fallback parser for tool-call JSON that may have unescaped quotes in string values.
-- Strategy: extract short fields from the beginning, then handle long fields.
-- For edit calls (oldText + newText), we split on the boundary marker between them.
-- For other calls (write/content), assign the entire remainder to the single long field.
local function fuzzy_extract_fields(body)
	local inner = body:match("^%s*{(.*)}%s*$")
	if not inner then return nil end

	local fields = {}
	local pos = 1
	local len = #inner

	-- Known short fields that won't contain unescaped quotes
	local SHORT_FIELDS = {
		path = true, command = true, pattern = true, glob = true,
		offset = true, limit = true, maxDepth = true, timeout = true,
		start_line = true, end_line = true, start_tag = true, end_tag = true,
	}

	-- Known long fields (order matters for multi-long-field tools like edit)
	local LONG_FIELDS = {
		oldText = true, newText = true, content = true, lines = true,
	}

	-- First pass: extract short fields from the front
	while pos <= len do
		local _, ws_end = inner:find("^[%s,]+", pos)
		if ws_end then pos = ws_end + 1 end
		if pos > len then break end

			local _, key_end, key = inner:find('^"([^"]+)"%s*:%s*', pos)
		if not key then break end

		-- If this is NOT a short field, it's a long field — stop here
		if not SHORT_FIELDS[key] then
			break
		end

		pos = key_end + 1

		local num_start, num_end, num_val = inner:find("^(%d+%.?%d*)", pos)
		if num_start then
			fields[key] = tonumber(num_val)
			pos = num_end + 1
		elseif inner:sub(pos, pos) == '"' then
			pos = pos + 1
			-- For short fields, find the proper end by scanning for unescaped quote
			local val_start = pos
			while pos <= len do
				local c = inner:sub(pos, pos)
				if c == "\\" then
					pos = pos + 2
				elseif c == '"' then
					break
				else
					pos = pos + 1
				end
			end
			fields[key] = inner:sub(val_start, pos - 1)
			pos = pos + 1
		else
			break
		end
	end

	-- Skip comma/whitespace
	local _, ws_end2 = inner:find("^[%s,]+", pos)
	if ws_end2 then pos = ws_end2 + 1 end

	-- Second pass: handle long fields
	-- Check if this is a multi-long-field case (edit: oldText + newText)
	-- by looking for a second long field key marker after the first
	local remaining = inner:sub(pos)

	-- Try to find two long fields by locating the boundary between them.
	-- The boundary looks like: ","newText": or ", "newText": (after oldText value ends)
	-- Strategy: find the LAST occurrence of ,"newText": or ,"oldText": as a split point
		local _, first_key_end, first_key = remaining:find('^"([^"]+)"%s*:%s*')
	if first_key and LONG_FIELDS[first_key] then
		local after_first_key = first_key_end + 1

		-- Look for a second long field key boundary
		-- Pattern: ...","nextKey":  — we search for ","oldText": or ","newText": or ","content":
		local second_key_pattern = ',%s*"(oldText)"%s*:%s*'
		local second_key_pattern2 = ',%s*"(newText)"%s*:%s*'
			local split_pos, split_end, second_key = nil, nil, nil

		-- For edit tool: if first key is oldText, look for newText boundary
		-- For edit tool: if first key is newText, look for oldText boundary (unusual order)
		if first_key == "oldText" then
			-- Find the last occurrence of ,"newText": since the oldText value might contain that string
			local search_from = after_first_key
			while true do
				local s, e, k = remaining:find(second_key_pattern2, search_from)
				if not s then break end
				split_pos, split_end, second_key = s, e, k
				search_from = e + 1
			end
		elseif first_key == "newText" then
			local search_from = after_first_key
			while true do
				local s, e, k = remaining:find(second_key_pattern, search_from)
				if not s then break end
				split_pos, split_end, second_key = s, e, k
				search_from = e + 1
			end
		end

		if split_pos and second_key then
			-- Extract first long field value (between quotes from after_first_key to split boundary)
			local first_val_raw = remaining:sub(after_first_key, split_pos - 1)
			-- Strip surrounding quotes and trailing whitespace
			first_val_raw = first_val_raw:match('^"(.*)"$') or first_val_raw:match('^"(.*)"%s*$')
			if first_val_raw then
				fields[first_key] = first_val_raw
			end

			-- Extract second long field value (from after split_end to end)
			local second_val_raw = remaining:sub(split_end + 1)
			-- Find the content between quotes (first quote to last quote)
			local sq = second_val_raw:find('"')
			if sq then
				second_val_raw = second_val_raw:sub(sq + 1)
				local last_quote = #second_val_raw
				while last_quote >= 1 and second_val_raw:sub(last_quote, last_quote) ~= '"' do
					last_quote = last_quote - 1
				end
				if last_quote >= 1 then
					fields[second_key] = second_val_raw:sub(1, last_quote - 1)
				else
					fields[second_key] = second_val_raw
				end
			end
		else
			-- Single long field: everything from here to the last quote
			if remaining:sub(after_first_key, after_first_key) == '"' then
				local val_start = after_first_key + 1
				local val_content = remaining:sub(val_start)
				local last_quote = #val_content
				while last_quote >= 1 and val_content:sub(last_quote, last_quote) ~= '"' do
					last_quote = last_quote - 1
				end
				if last_quote >= 1 then
					fields[first_key] = val_content:sub(1, last_quote - 1)
				else
					fields[first_key] = val_content
				end
			elseif remaining:sub(after_first_key, after_first_key) == "[" then
				-- Array value (e.g., "lines": [...])
				local bracket_content = remaining:sub(after_first_key)
				local last_bracket = #bracket_content
				while last_bracket >= 1 and bracket_content:sub(last_bracket, last_bracket) ~= "]" do
					last_bracket = last_bracket - 1
				end
				if last_bracket >= 1 then
					fields[first_key] = bracket_content:sub(1, last_bracket)
				else
					fields[first_key] = bracket_content
				end
			end
		end
	end

	if next(fields) == nil then return nil end

	-- Unescape JSON string escape sequences in extracted values
	for k, v in pairs(fields) do
		if type(v) == "string" then
			local unescaped = v:gsub("\\(.)", function(c)
				if c == "n" then return "\n"
				elseif c == "t" then return "\t"
				elseif c == "r" then return "\r"
				elseif c == '"' then return '"'
				elseif c == "\\" then return "\\"
				else return "\\" .. c
				end
			end)
			fields[k] = unescaped
		end
	end
	return fields
end

function json.object_fields(body)
	local tbl = decode_object(body)
	if not tbl then
		-- Fallback: body may be raw JSON without outer braces
		local wrapped = body
		if not body:match("^%s*{") then
			wrapped = "{" .. body .. "}"
		end
		tbl = decode_object(wrapped)
	end

	if not tbl then
		-- Last resort: fuzzy extraction for malformed JSON
		tbl = fuzzy_extract_fields(body)
	end

	if not tbl then
		return {}
	end

	local fields = {}
	for k, v in pairs(tbl) do
		if v ~= cjson_null then
			if type(v) == "table" then
				fields[k] = cjson.encode(v)
			else
				fields[k] = v
			end
		end
	end
	return fields
end

function json.unescape_string(value)
	local ok, decoded = pcall(cjson.decode, '"' .. value .. '"')
	if ok then
		return decoded
	end
	-- Fallback for already-unescaped strings
	return value
end

return json
