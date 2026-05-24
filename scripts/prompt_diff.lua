#!/usr/bin/env lua

local function usage()
	io.stderr:write([[usage: lca-prompt-diff A.json B.json

Compare two dumped Codex request bodies and report where their shared prefix ends.
]])
end

local function read_file(path)
	local f, err = io.open(path, "rb")
	if not f then
		error("failed to read " .. tostring(path) .. ": " .. tostring(err))
	end
	local text = f:read("*a")
	f:close()
	return text
end

local function line_col(text, pos)
	local line, col = 1, 1
	for i = 1, math.max(0, pos - 1) do
		local byte = text:byte(i)
		if byte == 10 then
			line = line + 1
			col = 1
		else
			col = col + 1
		end
	end
	return line, col
end

local function snippet(text, pos)
	local start_at = math.max(1, pos - 80)
	local end_at = math.min(#text, pos + 160)
	local out = text:sub(start_at, end_at)
	out = out:gsub("\r", "\\r"):gsub("\n", "\\n")
	if start_at > 1 then
		out = "..." .. out
	end
	if end_at < #text then
		out = out .. "..."
	end
	return out
end

if #arg ~= 2 or arg[1] == "-h" or arg[1] == "--help" then
	usage()
	os.exit(#arg == 2 and 0 or 1)
end

local a_path, b_path = arg[1], arg[2]
local a, b = read_file(a_path), read_file(b_path)
local limit = math.min(#a, #b)
local common = 0
for i = 1, limit do
	if a:byte(i) ~= b:byte(i) then
		break
	end
	common = i
end

local pct_a = #a > 0 and common / #a * 100 or 0
local pct_b = #b > 0 and common / #b * 100 or 0
local line_a, col_a = line_col(a, common + 1)
local line_b, col_b = line_col(b, common + 1)

print("prompt diff")
print("  a: " .. a_path .. " (" .. tostring(#a) .. " bytes)")
print("  b: " .. b_path .. " (" .. tostring(#b) .. " bytes)")
print(string.format("  common prefix: %d bytes (%.1f%% of a, %.1f%% of b)", common, pct_a, pct_b))

if common == #a and common == #b then
	print("  result: identical")
else
	print(string.format("  first difference: a line %d col %d, b line %d col %d", line_a, col_a, line_b, col_b))
	print("  a around diff: " .. snippet(a, common + 1))
	print("  b around diff: " .. snippet(b, common + 1))
end
