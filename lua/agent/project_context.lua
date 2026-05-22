local fs = require("agent.util.fs")
local path = require("agent.util.path")

local project_context = {}

local CANDIDATES = { "AGENTS.md", "AGENTS.MD", "CLAUDE.md", "CLAUDE.MD" }

local function file_exists(file_path)
	local file = io.open(file_path, "r")
	if file then
		file:close()
		return true
	end
	return false
end

local function dirname(dir)
	if dir == "/" then
		return "/"
	end
	local parent = dir:match("^(.*)/[^/]+$")
	if not parent or parent == "" then
		return "/"
	end
	return parent
end

local function load_context_file(dir)
	for _, name in ipairs(CANDIDATES) do
		local candidate = path.resolve(name, dir)
		if file_exists(candidate) then
			local ok, content = pcall(fs.read_file, candidate)
			if ok then
				return {
					path = candidate,
					content = content,
				}
			end
		end
	end
	return nil
end

function project_context.load(cwd)
	local files = {}
	local seen = {}
	local stack = {}
	local current = cwd

	while current do
		stack[#stack + 1] = current
		local parent = dirname(current)
		if parent == current then
			break
		end
		current = parent
	end

	for index = #stack, 1, -1 do
		local item = load_context_file(stack[index])
		if item and not seen[item.path] then
			files[#files + 1] = item
			seen[item.path] = true
		end
	end

	return files
end

return project_context
