#!/usr/bin/env lua

local script_dir = arg[0]:match("^(.*)/[^/]+$") or "."
local project_dir = script_dir .. "/.."
package.path = project_dir .. "/lua/?.lua;" .. project_dir .. "/lua/?/init.lua;" .. project_dir .. "/lua/?/?.lua;" .. package.path
pcall(require, "luarocks.loader")

local function usage()
	io.stderr:write([[
Usage:
  lua bin/agent.lua [prompt] [--credentials path] [--model model] [--reasoning effort]

Example:
  lua bin/agent.lua "List the files in this directory conceptually; do not run tools yet."
]])
	os.exit(2)
end

local config = require("agent.config")

local prompt = arg[1]
if not prompt or prompt == "--help" then
	usage()
end

local options = {
	credentials_path = config.default_credentials_path(),
	model = "gpt-5.4-mini",
	reasoning_effort = nil,
}

local index = 2
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

local agent = require("agent.core")
local session_module = require("agent.session")

local ok, result = pcall(function()
	local session = session_module.create(options)
	session:add_user(prompt)
	return agent.run_session(session)
end)

if not ok then
	io.stderr:write("error: " .. tostring(result) .. "\n")
	os.exit(1)
end

print(result.text or "")
