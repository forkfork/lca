local fs = require("agent.util.fs")
local path = require("agent.util.path")

local read = {}

local DEFAULT_LIMIT = 2000
local MAX_LIMIT = 2000

local function split_lines(text)
	local lines = {}
	text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
	for line in (text .. "\n"):gmatch("(.-)\n") do
		lines[#lines + 1] = line
	end
	return lines
end

-- Generate a 4-char tag for a line based on its content and line number.
-- Used as a lightweight CAS token so the edit tool can verify the line
-- hasn't changed since it was last read.
local TAG_CHARS = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

local function line_tag(line_num, content)
	-- Simple hash: mix line number with all content bytes
	local h = line_num * 2654435761
	for i = 1, #content do
		h = ((h ~ content:byte(i)) * 2246822519) & 0xFFFFFFFF
	end
	h = ((h ~ (h >> 16)) * 2246822519) & 0xFFFFFFFF

	local tag = {}
	for _ = 1, 4 do
		local idx = (h % #TAG_CHARS) + 1
		tag[#tag + 1] = TAG_CHARS:sub(idx, idx)
		h = math.floor(h / #TAG_CHARS)
	end
	return table.concat(tag)
end

read.line_tag = line_tag
read.split_lines = split_lines

function read.execute(args, context)
	if not args.path or args.path == "" then
		return {
			is_error = true,
			content = "path is required",
			summary = "missing path",
		}
	end

	local target = path.resolve(args.path, context.cwd)
	local ok, content = pcall(fs.read_file, target)
	if not ok then
		local msg = tostring(content)
		msg = msg:gsub("^.-:%d+:%s*", "")
		return {
			is_error = true,
			content = msg,
			summary = "failed",
		}
	end
	if not content then
		return {
			is_error = true,
			content = "could not read: " .. target,
			summary = "failed",
		}
	end

	local lines = split_lines(content)
	local offset = math.floor(math.max(1, tonumber(args.offset) or 1))
	local limit = math.floor(math.min(MAX_LIMIT, math.max(1, tonumber(args.limit) or DEFAULT_LIMIT)))
	local last = math.min(#lines, offset + limit - 1)
	local output = {}
	for index = offset, last do
		local tag = line_tag(index, lines[index])
		output[#output + 1] = string.format("%d:%s: %s", index, tag, lines[index])
	end

	local suffix = ""
	if last < #lines then
		suffix = "\n[truncated: showing lines " .. offset .. "-" .. last .. " of " .. #lines .. "]"
	end

	return {
		is_error = false,
		content = table.concat(output, "\n") .. suffix,
		summary = tostring(last - offset + 1) .. " lines",
	}
end

return read
