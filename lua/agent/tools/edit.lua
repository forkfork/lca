local fs = require("agent.util.fs")
local path = require("agent.util.path")
local lint = require("agent.lint")
local read_tool = require("agent.tools.read")

local edit = {}

local function count_occurrences(text, needle)
	if needle == "" then
		return 0
	end
	local count = 0
	local index = 1
	while true do
		local start_at, end_at = text:find(needle, index, true)
		if not start_at then
			break
		end
		count = count + 1
		index = end_at + 1
	end
	return count
end

local function replace_once(text, old_text, new_text)
	local start_at, end_at = text:find(old_text, 1, true)
	if not start_at then
		return nil
	end
	return text:sub(1, start_at - 1) .. new_text .. text:sub(end_at + 1)
end

local function line_number_for_offset(text, offset)
	local line = 1
	for index = 1, offset - 1 do
		if text:sub(index, index) == "\n" then
			line = line + 1
		end
	end
	return line
end

local function affected_lines(text)
	if text == "" then
		return 0
	end
	local _, newline_count = text:gsub("\n", "\n")
	if text:sub(-1) == "\n" then
		return math.max(1, newline_count)
	end
	return newline_count + 1
end

local function lint_line_number(lint_output)
	if not lint_output then return nil end
	local line = lint_output:match(":(%d+):")
		or lint_output:match("line%s+(%d+)")
	return line and tonumber(line) or nil
end

local function normalize_lint_output(lint_output, display_path)
	local text = tostring(lint_output or ""):gsub("%s+$", "")
	if text == "" then
		return "syntax checker reported an error"
	end
	return text:gsub("/tmp/%S+%.%w+", display_path)
end

local function numbered_context(lines, center, radius)
	if #lines == 0 then
		return "(empty candidate file)"
	end
	center = math.max(1, math.min(#lines, center or 1))
	local first = math.max(1, center - radius)
	local last = math.min(#lines, center + radius)
	local out = {}
	for i = first, last do
		local marker = i == center and ">" or " "
		out[#out + 1] = string.format("%s %4d | %s", marker, i, lines[i])
	end
	return table.concat(out, "\n")
end

local function blocked_edit_content(lint_output, args, candidate_lines, fallback_line)
	local center = lint_line_number(lint_output) or fallback_line or 1
	local display_path = tostring(args.path or "<unknown>")
	return table.concat({
		"BLOCKED: edit would produce syntax errors, file NOT modified.",
		"",
		"Requested edit: " .. display_path .. " lines " .. tostring(args.start_line or "?") .. "-" .. tostring(args.end_line or args.start_line or "?"),
		"",
		normalize_lint_output(lint_output, display_path),
		"Candidate context around reported line " .. tostring(center) .. ":",
		numbered_context(candidate_lines, center, 6),
	}, "\n")
end

local function introduced_lint_error(target, original_content, candidate_content)
	local candidate_lint = lint.check_content(target, candidate_content)
	if not candidate_lint then
		return nil
	end

	local original_lint = lint.check_content(target, original_content)
	if original_lint and normalize_lint_output(original_lint, target) == normalize_lint_output(candidate_lint, target) then
		return nil
	end

	return candidate_lint
end

-- Tag-based edit: replace lines identified by line number + tag
local function execute_tagged(args, context)
	local target = path.resolve(args.path, context.cwd)
	local ok, content = pcall(fs.read_file, target)
	if not ok then
		return { is_error = true, content = tostring(content), summary = "failed" }
	end

	local lines = read_tool.split_lines(content)

	local start_line = math.floor(tonumber(args.start_line) or 0)
	local end_line = math.floor(tonumber(args.end_line) or start_line)

	if start_line < 1 or start_line > #lines then
		return { is_error = true, content = "start_line " .. start_line .. " out of range (file has " .. #lines .. " lines)", summary = "out of range" }
	end
	if end_line < start_line or end_line > #lines then
		return { is_error = true, content = "end_line " .. end_line .. " out of range (file has " .. #lines .. " lines)", summary = "out of range" }
	end

	-- Verify tags match (CAS check)
	if args.start_tag then
		local actual_tag = read_tool.line_tag(start_line, lines[start_line])
		if args.start_tag ~= actual_tag then
			return {
				is_error = true,
				content = "start_tag mismatch at line " .. start_line .. ": expected " .. args.start_tag .. " but file has " .. actual_tag .. " — re-read the file",
				summary = "stale tag",
			}
		end
	end
	if args.end_tag then
		local actual_tag = read_tool.line_tag(end_line, lines[end_line])
		if args.end_tag ~= actual_tag then
			return {
				is_error = true,
				content = "end_tag mismatch at line " .. end_line .. ": expected " .. args.end_tag .. " but file has " .. actual_tag .. " — re-read the file",
				summary = "stale tag",
			}
		end
	end

	-- Build new file content — prefer raw content (no JSON escaping needed)
	local new_content = args._raw_content or args.content or ""
	local before = {}
	for i = 1, start_line - 1 do
		before[#before + 1] = lines[i]
	end
	local after = {}
	for i = end_line + 1, #lines do
		after[#after + 1] = lines[i]
	end

	local new_lines = {}
	if new_content ~= "" then
		for line in (new_content .. "\n"):gmatch("(.-)\n") do
			new_lines[#new_lines + 1] = line
		end
		-- Remove trailing empty line from split if content ended with \n
		if #new_lines > 0 and new_lines[#new_lines] == "" and new_content:sub(-1) == "\n" then
			table.remove(new_lines)
		end
	end

	local result_lines = {}
	for _, l in ipairs(before) do result_lines[#result_lines + 1] = l end
	for _, l in ipairs(new_lines) do result_lines[#result_lines + 1] = l end
	for _, l in ipairs(after) do result_lines[#result_lines + 1] = l end

	local final = table.concat(result_lines, "\n")
	-- Preserve trailing newline if original had one
	if content:sub(-1) == "\n" then
		final = final .. "\n"
	end

	-- Pre-write syntax check — reject edits that introduce syntax errors.
	local lint_output = introduced_lint_error(target, content, final)
	if lint_output then
		return {
			is_error = true,
			content = blocked_edit_content(lint_output, args, result_lines, start_line),
			summary = "syntax error — not written",
		}
	end

	local write_ok, write_error = pcall(fs.write_file, target, final)
	if not write_ok then
		return { is_error = true, content = tostring(write_error), summary = "write failed" }
	end

	local old_count = end_line - start_line + 1
	local new_count = #new_lines
	local result_msg = string.format("Edited %s: replaced lines %d-%d (%d lines) with %d lines", args.path, start_line, end_line, old_count, new_count)

	return {
		is_error = false,
		content = result_msg,
		summary = "replaced " .. old_count .. " lines with " .. new_count .. " lines",
	}
end

function edit.execute(args, context)
	if not args.path or args.path == "" then
		return {
			is_error = true,
			content = "path is required",
			summary = "missing path",
		}
	end

	-- Tag-based edit (preferred): uses line numbers + tags
	if args.start_line then
		return execute_tagged(args, context)
	end

	-- Legacy: oldText/newText match-and-replace
	if type(args.oldText) ~= "string" or args.oldText == "" then
		return {
			is_error = true,
			content = "Either start_line (tag-based) or oldText (legacy) is required",
			summary = "missing args",
		}
	end
	if type(args.newText) ~= "string" then
		return {
			is_error = true,
			content = "newText is required",
			summary = "missing newText",
		}
	end

	local target = path.resolve(args.path, context.cwd)
	local ok, original = pcall(fs.read_file, target)
	if not ok then
		return {
			is_error = true,
			content = tostring(original),
			summary = "failed",
		}
	end

	local matches = count_occurrences(original, args.oldText)
	if matches == 0 then
		return {
			is_error = true,
			content = "oldText did not match file contents",
			summary = "no match",
		}
	end
	if matches > 1 then
		return {
			is_error = true,
			content = "oldText matched " .. matches .. " times; make it unique before editing",
			summary = "ambiguous match",
		}
	end

	local start_at = original:find(args.oldText, 1, true)
	local next_content = replace_once(original, args.oldText, args.newText)

	-- Pre-write syntax check
	local lint_output = introduced_lint_error(target, original, next_content)
	if lint_output then
		local next_lines = read_tool.split_lines(next_content)
		local fallback_line = line_number_for_offset(original, start_at)
		return {
			is_error = true,
			content = blocked_edit_content(lint_output, {
				path = args.path,
				start_line = fallback_line,
				end_line = fallback_line + affected_lines(args.oldText) - 1,
			}, next_lines, fallback_line),
			summary = "syntax error — not written",
		}
	end

	local write_ok, write_error = pcall(fs.write_file, target, next_content)
	if not write_ok then
		return {
			is_error = true,
			content = tostring(write_error),
			summary = "write failed",
		}
	end

	local old_lines = affected_lines(args.oldText)
	local new_lines = affected_lines(args.newText)
	local result_msg = "Edited " .. args.path .. " at line " .. line_number_for_offset(original, start_at)

	return {
		is_error = false,
		content = result_msg,
		summary = "replaced " .. old_lines .. " lines with " .. new_lines .. " lines",
	}
end

return edit
