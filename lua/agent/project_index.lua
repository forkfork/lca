local project_index = {}

local KEY_FILES = {
	"package.json",
	"tsconfig.json",
	"pyproject.toml",
	"setup.py",
	"requirements.txt",
	"Cargo.toml",
	"go.mod",
	"Gemfile",
	"pom.xml",
	"CMakeLists.txt",
	"Makefile",
	"Dockerfile",
	"docker-compose.yml",
	".env.example",
}

local KEY_FILE_MAX_LINES = 30
local TREE_MAX_FILES = 200
local TREE_MAX_DEPTH = 4

local function shell_exec(cmd)
	local handle = io.popen(cmd .. " 2>/dev/null")
	if not handle then return nil end
	local output = handle:read("*a")
	handle:close()
	if output then
		return output:gsub("%s+$", "")
	end
	return nil
end

local function is_git_repo(cwd)
	local result = shell_exec(string.format("cd %q && git rev-parse --is-inside-work-tree", cwd))
	return result == "true"
end

local function build_file_tree(cwd)
	local cmd
	if is_git_repo(cwd) then
		cmd = string.format(
			"cd %q && { git ls-files; git ls-files --others --exclude-standard; } | sort -u",
			cwd
		)
	else
		cmd = string.format(
			"cd %q && find . -maxdepth %d -type f"
			.. " -not -path '*/.git/*'"
			.. " -not -path '*/node_modules/*'"
			.. " -not -path '*/__pycache__/*'"
			.. " -not -path '*/target/*'"
			.. " -not -path '*/.venv/*'"
			.. " | sort",
			cwd, TREE_MAX_DEPTH
		)
	end

	local output = shell_exec(cmd)
	if not output or output == "" then
		return nil, false
	end

	local lines = {}
	local truncated = false
	for line in output:gmatch("[^\n]+") do
		if #lines < TREE_MAX_FILES then
			lines[#lines + 1] = line
		else
			truncated = true
			break
		end
	end

	return table.concat(lines, "\n"), truncated
end

local function detect_key_files(cwd)
	local found = {}
	for _, name in ipairs(KEY_FILES) do
		local f = io.open(cwd .. "/" .. name, "r")
		if f then
			f:close()
			found[#found + 1] = name
		end
	end
	return found
end

local function read_key_file_summary(cwd, filename)
	local f = io.open(cwd .. "/" .. filename, "r")
	if not f then return nil end

	local lines = {}
	for line in f:lines() do
		lines[#lines + 1] = line
		if #lines >= KEY_FILE_MAX_LINES then
			break
		end
	end
	f:close()

	if #lines == 0 then return nil end

	local content = table.concat(lines, "\n")
	if #lines >= KEY_FILE_MAX_LINES then
		content = content .. "\n... (truncated)"
	end
	return content
end

function project_index.build(cwd)
	cwd = cwd or "."

	local parts = {}

	local tree, truncated = build_file_tree(cwd)
	if tree then
		parts[#parts + 1] = "# Project Structure"
		parts[#parts + 1] = ""
		if truncated then
			parts[#parts + 1] = string.format("File tree (first %d files, more exist):", TREE_MAX_FILES)
		else
			parts[#parts + 1] = "File tree:"
		end
		parts[#parts + 1] = "```"
		parts[#parts + 1] = tree
		parts[#parts + 1] = "```"
		parts[#parts + 1] = ""
	end

	local key_files = detect_key_files(cwd)
	if #key_files > 0 then
		parts[#parts + 1] = "# Key Project Files"
		parts[#parts + 1] = ""
		for _, filename in ipairs(key_files) do
			local summary = read_key_file_summary(cwd, filename)
			if summary then
				parts[#parts + 1] = "## " .. filename
				parts[#parts + 1] = "```"
				parts[#parts + 1] = summary
				parts[#parts + 1] = "```"
				parts[#parts + 1] = ""
			end
		end
	end

	if #parts == 0 then
		return ""
	end

	return table.concat(parts, "\n")
end

return project_index
