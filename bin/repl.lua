#!/usr/bin/env lua

local script_dir = arg[0]:match("^(.*)/[^/]+$") or "."
local project_dir = script_dir .. "/.."
package.path = project_dir .. "/lua/?.lua;" .. project_dir .. "/lua/?/init.lua;" .. project_dir .. "/lua/?/?.lua;" .. package.path
pcall(require, "luarocks.loader")

local config = require("agent.config")
local uv = require("luv")

local options = {
	credentials_path = config.default_credentials_path(),
	model = config.default_model(),
	reasoning_effort = nil,
	service_tier = nil,
	mcp_config = "mcp_servers.json",
}

local function usage()
	io.stderr:write([[
Usage:
  lua bin/repl.lua [--model model] [--tui-effect drift|mycelium|cytoplasm|ink|filament|contours|auto] [--tool-stage|--no-tool-stage] [--credentials path] [--reasoning effort] [--service-tier tier] [--transcript path]
]])
	os.exit(2)
end

local index = 1
while index <= #arg do
	if arg[index] == "--credentials" then
		options.credentials_path = arg[index + 1]
		index = index + 2
	elseif arg[index] == "--model" then
		options.model = assert(arg[index + 1], "--model requires a model id")
		index = index + 2
	elseif arg[index] == "--reasoning" then
		options.reasoning_effort = arg[index + 1]
		index = index + 2
	elseif arg[index] == "--service-tier" then
		options.service_tier = arg[index + 1]
		index = index + 2
	elseif arg[index] == "--transcript" then
		options.transcript = arg[index + 1]
		index = index + 2
	elseif arg[index] == "--mcp-config" then
		options.mcp_config = arg[index + 1]
		index = index + 2
	elseif arg[index] == "--tui-effect" then
		options.tui_effect = arg[index + 1]
		if not options.tui_effect then usage() end
		index = index + 2
	elseif arg[index] == "--tool-stage" then
		options.tool_stage = true
		index = index + 1
	elseif arg[index] == "--no-tool-stage" then
		options.tool_stage = false
		index = index + 1
	elseif arg[index] == "--help" then
		usage()
	else
		usage()
	end
end

local login = require("agent.login")

local login_ok, login_err = login.ensure_credentials(options.credentials_path)
if not login_ok then
	io.stderr:write("error: " .. tostring(login_err) .. "\n")
	os.exit(1)
end

local core = require("agent.core")
local registry = require("agent.tool_registry")

local function mkdir_if_missing(path)
	local ok, err = uv.fs_mkdir(path, tonumber("755", 8))
	if not ok and not tostring(err):find("EEXIST", 1, true) then
		return nil, err
	end
	return true
end

local function default_transcript_path()
	local root = "/tmp/lca"
	local logs = root .. "/logs"
	local root_ok = mkdir_if_missing(root)
	local logs_ok = root_ok and mkdir_if_missing(logs)

	local name = string.format("lca-%s-%d.log", os.date("%Y%m%d-%H%M%S"), uv.getpid())
	local path = logs_ok and (logs .. "/" .. name) or ("/tmp/" .. name)
	local latest = "/tmp/lca.log"
	local file = io.open(path, "a")
	if file then file:close() end
	if root_ok then
		local pointer = io.open(root .. "/latest", "w")
		if pointer then
			pointer:write(path .. "\n")
			pointer:close()
		end
	end
	os.remove(latest)
	local link_ok = uv.fs_symlink(path, latest)
	if not link_ok then
		pcall(function() uv.fs_link(path, latest) end)
	end
	return path
end

-- Explicit transcript paths are used as-is. The default log is per-session,
-- with /tmp/lca.log kept as a stable pointer to the latest session log.
local debug_log = options.transcript or os.getenv("LCA_LOG") or default_transcript_path()
core.set_transcript(debug_log)
options.transcript_path = debug_log
core.debug_log(
	"[session] pid=%d cwd=%s model=%s transcript=%s argv=%s",
	uv.getpid(),
	uv.cwd() or "",
	tostring(options.model),
	tostring(debug_log),
	table.concat(arg, " ")
)

-- Initialize MCP servers
local mcp_tools = registry.init_mcp(options.mcp_config)
options.mcp_tool_count = #mcp_tools
local frontend = require("agent.tui")
local ok, result, frontend_err = pcall(function()
	return frontend.run(options)
end)
core.set_transcript(nil)

if not ok or result == nil then
	if frontend.cleanup_terminal then pcall(function() frontend.cleanup_terminal() end) end
	io.stderr:write("error: " .. tostring(ok and frontend_err or result) .. "\n")
	os.exit(1)
end
