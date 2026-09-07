local fs = require("agent.util.fs")
local read = require("agent.tools.read")
local uv = require("luv")

local evidence = {}

local GREP_CONTEXT_LINES = 2
local MAX_FILES = 8
local MAX_RANGES = 12
local MAX_BYTES = 20000

local function realpath(value)
	return value and uv.fs_realpath(value) or nil
end

local function inside(root, target)
	return target == root or target:sub(1, #root + 1) == root .. "/"
end

local function relative(root, target)
	if target == root then return "." end
	return target:sub(#root + 2)
end

local function fnv1a32(text)
	local hash = 2166136261
	for index = 1, #text do
		hash = hash ~ text:byte(index)
		hash = (hash * 16777619) & 0xFFFFFFFF
	end
	return string.format("%08x", hash)
end

local function load_source(candidate, cwd)
	local root = realpath(cwd or ".")
	local target = realpath(candidate)
	if not root or not target or not inside(root, target) then return nil end
	local stat = uv.fs_stat(target)
	if not stat or stat.type ~= "file" or stat.size > 1024 * 1024 then return nil end
	local ok, content = pcall(fs.read_file, target)
	if not ok or not content or content:find("\0", 1, true) then return nil end
	return {
		path = target,
		display_path = relative(root, target),
		content = content,
		lines = read.split_lines(content),
		snapshot = fnv1a32(content),
	}
end

local function append_range(output, source, first, last, budget)
	first = math.max(1, first)
	last = math.min(#source.lines, last)
	local header = string.format("[%s snapshot=%s lines=%d-%d]", source.display_path, source.snapshot, first, last)
	if budget.bytes + #header + 1 > MAX_BYTES then return false end
	output[#output + 1] = header
	budget.bytes = budget.bytes + #header + 1
	for line_number = first, last do
		local line = string.format("%d:%s: %s", line_number, read.line_tag(line_number, source.lines[line_number]), source.lines[line_number])
		if budget.bytes + #line + 1 > MAX_BYTES then
			output[#output + 1] = "[source evidence capped at " .. MAX_BYTES .. " bytes]"
			return false
		end
		output[#output + 1] = line
		budget.bytes = budget.bytes + #line + 1
	end
	return true
end

local function merge_lines(line_numbers, radius)
	table.sort(line_numbers)
	local ranges = {}
	for _, line_number in ipairs(line_numbers) do
		local first = math.max(1, line_number - radius)
		local last = line_number + radius
		local previous = ranges[#ranges]
		if previous and first <= previous[2] + 1 then
			previous[2] = math.max(previous[2], last)
		else
			ranges[#ranges + 1] = { first, last }
		end
	end
	return ranges
end

function evidence.enrich_grep(raw_output, cwd)
	local root = realpath(cwd or ".")
	if not root then return raw_output, 0 end
	local matches = {}
	local order = {}
	local match_count = 0
	for line in (tostring(raw_output or "") .. "\n"):gmatch("(.-)\n") do
		local raw_path, raw_line = line:match("^(.-):(%d+):")
		if raw_path then
			match_count = match_count + 1
			local candidate = raw_path:sub(1, 1) == "/" and raw_path or (root .. "/" .. raw_path)
			local target = realpath(candidate)
			if target and inside(root, target) then
				if not matches[target] then
					matches[target] = {}
					order[#order + 1] = target
				end
				matches[target][#matches[target] + 1] = tonumber(raw_line)
			end
		end
	end
	if #order == 0 then return raw_output, match_count end

	local output = {
		"[grep source evidence: matching ranges are freshly tagged and may be used directly by edit]",
	}
	local budget = { bytes = #output[1] + 1 }
	local range_count = 0
	for file_index, target in ipairs(order) do
		if file_index > MAX_FILES then break end
		local source = load_source(target, root)
		if source then
			for _, range in ipairs(merge_lines(matches[target], GREP_CONTEXT_LINES)) do
				if range_count >= MAX_RANGES then break end
				range_count = range_count + 1
				if not append_range(output, source, range[1], range[2], budget) then
					return table.concat(output, "\n"), match_count
				end
			end
		end
	end
	if #order > MAX_FILES or range_count >= MAX_RANGES then
		output[#output + 1] = "[source evidence capped; narrow the grep pattern or path for more ranges]"
	end
	return table.concat(output, "\n"), match_count
end

return evidence
