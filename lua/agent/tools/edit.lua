local fs = require("agent.util.fs")
local path = require("agent.util.path")
local lint = require("agent.lint")
local read_tool = require("agent.tools.read")

local edit = {}
local MAX_MULTI_EDITS = 20
local MAX_TAG_RELOCATION_LINES = 200

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

local function replacement_lines(content)
	local lines = {}
	if content ~= "" then
		for line in (content .. "\n"):gmatch("(.-)\n") do
			lines[#lines + 1] = line
		end
		if #lines > 0 and lines[#lines] == "" and content:sub(-1) == "\n" then
			table.remove(lines)
		end
	end
	return lines
end

local function replace_line_range(lines, start_line, end_line, new_lines)
	local result = {}
	for i = 1, start_line - 1 do result[#result + 1] = lines[i] end
	for _, line in ipairs(new_lines) do result[#result + 1] = line end
	for i = end_line + 1, #lines do result[#result + 1] = lines[i] end
	return result
end

local function tagged_range(args, lines, label)
	local start_line = math.floor(tonumber(args.start_line) or 0)
	local end_line = math.floor(tonumber(args.end_line) or start_line)
	local prefix = label and (label .. ": ") or ""
	if start_line < 1 or start_line > #lines then
		return nil, prefix .. "start_line " .. start_line .. " out of range (file has " .. #lines .. " lines)", "out of range"
	end
	if end_line < start_line or end_line > #lines then
		return nil, prefix .. "end_line " .. end_line .. " out of range (file has " .. #lines .. " lines)", "out of range"
	end
	if type(args.start_tag) ~= "string" or type(args.end_tag) ~= "string" then
		return nil, prefix .. "start_tag and end_tag are required", "missing tags"
	end
	local actual_start = read_tool.line_tag(start_line, lines[start_line])
	local actual_end = read_tool.line_tag(end_line, lines[end_line])
	if args.start_tag == actual_start and args.end_tag == actual_end then
		return { start_line = start_line, end_line = end_line }
	end

	-- A prior tagged edit may insert/delete lines above an otherwise unchanged
	-- target. Relocate only when both endpoint contents uniquely reproduce their
	-- original tags at the same bounded offset. Content changes and duplicate
	-- candidate lines therefore remain stale instead of being guessed through.
	local function relocated_candidates(original_line, expected_tag)
		local candidates = {}
		local first = math.max(1, original_line - MAX_TAG_RELOCATION_LINES)
		local last = math.min(#lines, original_line + MAX_TAG_RELOCATION_LINES)
		for current_line = first, last do
			if read_tool.line_tag(original_line, lines[current_line]) == expected_tag then
				candidates[#candidates + 1] = current_line
			end
		end
		return candidates
	end
	local start_candidates = relocated_candidates(start_line, args.start_tag)
	local end_candidates = relocated_candidates(end_line, args.end_tag)
	if #start_candidates == 1 and #end_candidates == 1 then
		local relocated_start = start_candidates[1]
		local relocated_end = end_candidates[1]
		local delta = relocated_start - start_line
		if delta ~= 0 and relocated_end - end_line == delta and relocated_end >= relocated_start then
			return {
				start_line = relocated_start,
				end_line = relocated_end,
				relocated_by = delta,
				requested_start_line = start_line,
				requested_end_line = end_line,
			}
		end
	end

	if args.start_tag ~= actual_start then
		return nil, prefix .. "start_tag mismatch at line " .. start_line .. ": expected " .. args.start_tag .. " but file has " .. actual_start .. " — re-read the file", "stale tag"
	end
	return nil, prefix .. "end_tag mismatch at line " .. end_line .. ": expected " .. args.end_tag .. " but file has " .. actual_end .. " — re-read the file", "stale tag"
end

-- Tag-based edit: replace lines identified by line number + tag
local function execute_tagged(args, context)
	local target = path.resolve(args.path, context.cwd)
	local ok, content = pcall(fs.read_file, target)
	if not ok then
		return { is_error = true, content = tostring(content), summary = "failed" }
	end

	local lines = read_tool.split_lines(content)

	local range, range_error, range_summary = tagged_range(args, lines)
	if not range then
		return { is_error = true, content = range_error, summary = range_summary }
	end
	local start_line, end_line = range.start_line, range.end_line

	-- Build new file content — prefer raw content (no JSON escaping needed)
	local new_content = args._raw_content or args.content or ""
	local new_lines = replacement_lines(new_content)
	local result_lines = replace_line_range(lines, start_line, end_line, new_lines)

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
	local summary = "replaced " .. old_count .. " lines with " .. new_count .. " lines"
	if range.relocated_by then
		result_msg = result_msg .. string.format("; safely relocated requested range by %+d lines", range.relocated_by)
		summary = summary .. string.format(", relocated %+d", range.relocated_by)
	end

	return {
		is_error = false,
		content = result_msg,
		summary = summary,
	}
end

local function execute_multi(args, context)
	if type(args.edits) ~= "table" or #args.edits == 0 then
		return { is_error = true, content = "edits must be a non-empty array", summary = "missing edits" }
	end
	if #args.edits > MAX_MULTI_EDITS then
		return { is_error = true, content = "too many edits (max " .. MAX_MULTI_EDITS .. ")", summary = "too many edits" }
	end

	local target = path.resolve(args.path, context.cwd)
	local ok, content = pcall(fs.read_file, target)
	if not ok then
		return { is_error = true, content = tostring(content), summary = "failed" }
	end
	local original_lines = read_tool.split_lines(content)
	local hunks = {}
	for index, hunk in ipairs(args.edits) do
		if type(hunk) ~= "table" then
			return { is_error = true, content = "hunk #" .. index .. " must be an object", summary = "invalid hunk" }
		end
		if type(hunk.content) ~= "string" then
			return { is_error = true, content = "hunk #" .. index .. ": content is required", summary = "missing content" }
		end
		local range, range_error, range_summary = tagged_range(hunk, original_lines, "hunk #" .. index)
		if not range then
			return { is_error = true, content = range_error .. "; no edits were applied", summary = range_summary }
		end
		range.content = hunk.content
		range.index = index
		hunks[#hunks + 1] = range
	end

	table.sort(hunks, function(a, b)
		if a.start_line == b.start_line then return a.end_line < b.end_line end
		return a.start_line < b.start_line
	end)
	for index = 2, #hunks do
		if hunks[index].start_line <= hunks[index - 1].end_line then
			return {
				is_error = true,
				content = "hunks #" .. hunks[index - 1].index .. " and #" .. hunks[index].index .. " overlap; no edits were applied",
				summary = "overlapping hunks",
			}
		end
	end

	local result_lines = original_lines
	local replaced, inserted = 0, 0
	for index = #hunks, 1, -1 do
		local hunk = hunks[index]
		local new_lines = replacement_lines(hunk.content)
		replaced = replaced + hunk.end_line - hunk.start_line + 1
		inserted = inserted + #new_lines
		result_lines = replace_line_range(result_lines, hunk.start_line, hunk.end_line, new_lines)
	end

	local final = table.concat(result_lines, "\n")
	if content:sub(-1) == "\n" then final = final .. "\n" end
	local lint_output = introduced_lint_error(target, content, final)
	if lint_output then
		return {
			is_error = true,
			content = blocked_edit_content(lint_output, {
				path = args.path,
				start_line = hunks[1].start_line,
				end_line = hunks[#hunks].end_line,
			}, result_lines, hunks[1].start_line),
			summary = "syntax error — not written",
		}
	end

	local write_ok, write_error = pcall(fs.write_file, target, final)
	if not write_ok then
		return { is_error = true, content = tostring(write_error), summary = "write failed" }
	end
	return {
		is_error = false,
		content = string.format("Edited %s atomically: applied %d non-overlapping hunks (%d lines replaced, %d lines inserted)", args.path, #hunks, replaced, inserted),
		summary = tostring(#hunks) .. " hunks applied",
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
	if args.edits ~= nil then
		return execute_multi(args, context)
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
