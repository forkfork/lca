local fs = require("agent.util.fs")
local path = require("agent.util.path")
local shell = require("agent.util.shell")
local lint = require("agent.lint")

local write = {}

local function dirname(file_path)
	local dir = file_path:match("^(.*)/[^/]*$")
	if not dir or dir == "" then
		return "."
	end
	return dir
end

local function line_count(text)
	if text == "" then
		return 0
	end
	local _, newlines = text:gsub("\n", "\n")
	if text:sub(-1) == "\n" then
		return math.max(1, newlines)
	end
	return newlines + 1
end

function write.execute(args, context)
	if not args.path or args.path == "" then
		return {
			is_error = true,
			content = "path is required",
			summary = "missing path",
		}
	end

	-- Support raw content (preferred), "content" string, or "lines" array
	local content = args._raw_content
	if not content then
		content = args.content
	end
	if not content and args.lines then
		if type(args.lines) == "string" then
			local cjson = require("cjson")
			local ok, arr = pcall(cjson.decode, args.lines)
			if ok and type(arr) == "table" then
				content = table.concat(arr, "\n") .. "\n"
			else
				content = args.lines
			end
		elseif type(args.lines) == "table" then
			content = table.concat(args.lines, "\n") .. "\n"
		end
	end

	if type(content) ~= "string" then
		return {
			is_error = true,
			content = "content (string) or lines (array of strings) is required",
			summary = "missing content",
		}
	end

	-- Ensure trailing newline for raw content
	if content ~= "" and content:sub(-1) ~= "\n" then
		content = content .. "\n"
	end

	local target = path.resolve(args.path, context.cwd)
	local mkdir_ok, mkdir_error = pcall(shell.capture, "mkdir -p " .. shell.quote(dirname(target)))
	if not mkdir_ok then
		return {
			is_error = true,
			content = tostring(mkdir_error),
			summary = "mkdir failed",
		}
	end

	-- Pre-write syntax check — block writes that produce invalid syntax
	local lint_output = lint.check_content(target, content)
	if lint_output then
		return {
			is_error = true,
			content = "BLOCKED: content has syntax errors, file NOT written.\n\n" .. lint_output,
			summary = "syntax error — not written",
		}
	end

	local write_ok, write_error = pcall(fs.write_file, target, content)
	if not write_ok then
		return {
			is_error = true,
			content = tostring(write_error),
			summary = "write failed",
		}
	end

	local lines_written = line_count(content)
	local result_msg = "Wrote " .. #content .. " bytes (" .. lines_written .. " lines) to " .. args.path

	return {
		is_error = false,
		content = result_msg,
		summary = "wrote " .. lines_written .. " lines",
	}
end

return write
