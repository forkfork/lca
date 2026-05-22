#!/usr/bin/env lua

local script_dir = arg[0]:match("^(.*)/[^/]+$") or "."
local project_dir = script_dir .. "/.."
package.path = project_dir .. "/lua/?.lua;" .. project_dir .. "/lua/?/init.lua;" .. project_dir .. "/lua/?/?.lua;" .. package.path
pcall(require, "luarocks.loader")

local config = require("agent.config")

local options = {
	credentials_path = config.default_credentials_path(),
	model = "gpt-5.4-mini",
	reasoning_effort = nil,
	mcp_config = "mcp_servers.json",
}

local function usage()
	io.stderr:write([[
Usage:
  lua bin/repl.lua [--credentials path] [--model model] [--reasoning effort] [--transcript path]
]])
	os.exit(2)
end

local index = 1
while index <= #arg do
	if arg[index] == "--credentials" then
		options.credentials_path = arg[index + 1]
		index = index + 2
	elseif arg[index] == "--model" then
		options.model = arg[index + 1]
		index = index + 2
	elseif arg[index] == "--reasoning" then
		options.reasoning_effort = arg[index + 1]
		index = index + 2
	elseif arg[index] == "--transcript" then
		options.transcript = arg[index + 1]
		index = index + 2
	elseif arg[index] == "--mcp-config" then
		options.mcp_config = arg[index + 1]
		index = index + 2
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
local repl = require("agent.repl")

-- Always log to debug file (truncates each session unless MOONCLAW_LOG_APPEND=1)
local debug_log = options.transcript or os.getenv("MOONCLAW_LOG") or "/tmp/moonclaw.log"
core.set_transcript(debug_log)

-- Initialize MCP servers
local mcp_tools = registry.init_mcp(options.mcp_config)
if #mcp_tools > 0 then
	io.write(string.format("\27[2m  %d MCP tools from %s\27[0m\n",
		#mcp_tools, table.concat(require("agent.mcp").connected_servers(), ", ")))
end

local ok, err = pcall(function()
	repl.run(options)
end)

if not ok then
	io.stderr:write("error: " .. tostring(err) .. "\n")
	os.exit(1)
end
