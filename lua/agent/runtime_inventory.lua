local uv = require("luv")

local runtime_inventory = {}

local GROUPS = {
	{ label = "shell/build", names = { "sh", "bash", "git", "make" } },
	{ label = "python", names = { "python", "python3", "pip", "pip3", "uv", "pytest" } },
	{ label = "lua", names = { "lua", "luajit", "luarocks" } },
	{ label = "javascript", names = { "node", "npm", "npx", "pnpm", "yarn" } },
	{ label = "compiled", names = { "go", "cargo", "rustc" } },
}

local default_cache

local function path_directories(path_value)
	local directories = {}
	local seen = {}
	for directory in (tostring(path_value or "") .. ":"):gmatch("(.-):") do
		if directory == "" then directory = "." end
		if not seen[directory] then
			seen[directory] = true
			directories[#directories + 1] = directory
		end
	end
	return directories
end

local function resolve_in(name, directories)
	for _, directory in ipairs(directories) do
		local path = directory .. "/" .. name
		if uv.fs_access(path, "X") then return path end
	end
	return nil
end

function runtime_inventory.scan(path_value)
	path_value = path_value == nil and (os.getenv("PATH") or "") or tostring(path_value)
	if default_cache and default_cache.path_value == path_value then return default_cache end
	local directories = path_directories(path_value)
	local result = { path_value = path_value, executables = {} }
	for _, group in ipairs(GROUPS) do
		for _, name in ipairs(group.names) do
			result.executables[name] = resolve_in(name, directories)
		end
	end
	if path_value == (os.getenv("PATH") or "") then default_cache = result end
	return result
end

function runtime_inventory.resolve(name, path_value)
	local scanned = runtime_inventory.scan(path_value)
	if scanned.executables[name] ~= nil then return scanned.executables[name] end
	return resolve_in(name, path_directories(scanned.path_value))
end

function runtime_inventory.section(path_value)
	local scanned = runtime_inventory.scan(path_value)
	local lines = {
		"## Runtime executables",
		"Resolved from the startup PATH; prefer an available executable and do not try a listed missing alias unless the environment changes.",
	}
	for _, group in ipairs(GROUPS) do
		local entries = {}
		for _, name in ipairs(group.names) do
			entries[#entries + 1] = name .. "=" .. (scanned.executables[name] or "missing")
		end
		lines[#lines + 1] = "- " .. group.label .. ": " .. table.concat(entries, ", ")
	end
	return table.concat(lines, "\n")
end

return runtime_inventory
