#!/usr/bin/env lua

local script_dir = arg[0]:match("^(.*)/[^/]+$") or "."
local project_dir = script_dir .. "/.."
package.path = project_dir .. "/lua/?.lua;" .. project_dir .. "/lua/?/init.lua;" .. package.path
pcall(require, "luarocks.loader")

local json = require("agent.util.json")
local login = require("agent.login")

local passed = 0
local failed = 0

local function test(name, fn)
	io.write("  " .. name .. " ")
	local ok, err = pcall(fn)
	if ok then
		passed = passed + 1
		io.write("PASS\n")
	else
		failed = failed + 1
		io.write("FAIL (" .. tostring(err) .. ")\n")
	end
end

local function shell_quote(value)
	return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function write_file(path, body)
	local file = assert(io.open(path, "w"))
	assert(file:write(body))
	assert(file:close())
end

io.write("\n═══ Login Tests ═══\n\n")

test("login envelope does not append gsub replacement count", function()
	local base = os.tmpname()
	os.remove(base)
	assert(os.execute("mkdir " .. shell_quote(base)))
	local login_script = base .. "/login.lua"
	local source = assert(io.open(project_dir .. "/scripts/login.lua", "r"))
	write_file(login_script, source:read("*a"))
	source:close()

	local auth = base .. "/lca-auth"
	write_file(auth, [[#!/bin/sh
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--out" ]; then
    shift
    printf '%s\n' '{"access":"fake-access","refresh":"fake-refresh","accountId":"fake-account"}' > "$1"
    exit 0
  fi
  shift
done
exit 2
]])
	assert(os.execute("chmod 700 " .. shell_quote(auth)))
	local output = base .. "/credentials.json"
	local command = "PATH=" .. shell_quote(base .. ":" .. (os.getenv("PATH") or ""))
		.. " lua5.5 " .. shell_quote(login_script) .. " --out " .. shell_quote(output)
		.. " >/dev/null"
	assert(os.execute(command))

	local saved = assert(io.open(output, "r"))
	local body = saved:read("*a")
	saved:close()
	local decoded = json.decode(body)
	assert(decoded.providers.codex.access == "fake-access")
	assert(not body:find("}1\n  }", 1, true), "gsub replacement count leaked into JSON")

	os.remove(output)
	os.remove(auth)
	os.remove(login_script)
	assert(os.execute("rmdir " .. shell_quote(base)))
end)

test("default auth prefers Codex then falls back to the Bedrock profile", function()
	local base = os.tmpname()
	os.remove(base)
	assert(os.execute("mkdir " .. shell_quote(base)))
	local default_path = base .. "/default.json"
	local bedrock_path = base .. "/bedrock.json"
	write_file(default_path, [[{"provider":"codex","providers":{"codex":{"access":"token","accountId":"acct"}}}]])
	write_file(bedrock_path, [[{"provider":"bedrock","providers":{"bedrock":{"isengardAccount":"work"}}}]])

	local config = require("agent.config")
	local old_default = config.default_credentials_path
	local old_bedrock = config.bedrock_credentials_path
	config.default_credentials_path = function() return default_path end
	config.bedrock_credentials_path = function() return bedrock_path end
	assert(login._resolve_existing(default_path) == default_path)

	write_file(default_path, [[{"provider":"bedrock","providers":{"bedrock":{"accessKeyId":"old","secretAccessKey":"old"}}}]])
	assert(login._resolve_existing(default_path) == bedrock_path)
	write_file(bedrock_path, [[{"provider":"bedrock","providers":{"bedrock":{"region":"us-east-1"}}}]])
	assert(login._resolve_existing(default_path) == bedrock_path)

	config.default_credentials_path = old_default
	config.bedrock_credentials_path = old_bedrock
	os.remove(default_path)
	os.remove(bedrock_path)
	assert(os.execute("rmdir " .. shell_quote(base)))
end)

test("default auth detects Bedrock environment credentials", function()
	local base = os.tmpname()
	os.remove(base)
	assert(os.execute("mkdir " .. shell_quote(base)))
	local default_path = base .. "/default.json"
	local bedrock_path = base .. "/bedrock.json"

	local config = require("agent.config")
	local old_default = config.default_credentials_path
	local old_bedrock = config.bedrock_credentials_path
	config.default_credentials_path = function() return default_path end
	config.bedrock_credentials_path = function() return bedrock_path end
	login._set_getenv(function(name)
		if name == "AWS_BEARER_TOKEN_BEDROCK" then return "test-token" end
		if name == "AWS_REGION" then return "ap-southeast-2" end
	end)
	login._set_command_capture(function() error("AWS CLI should not be called") end)

	assert(login._resolve_existing(default_path) == bedrock_path)
	local file = assert(io.open(bedrock_path, "r"))
	local saved = json.decode(file:read("*a"))
	file:close()
	assert(saved.provider == "bedrock")
	assert(saved.providers.bedrock.region == "ap-southeast-2")
	assert(saved.providers.bedrock.apiKey == nil)

	login._set_getenv(nil)
	login._set_command_capture(nil)
	config.default_credentials_path = old_default
	config.bedrock_credentials_path = old_bedrock
	os.remove(bedrock_path)
	assert(os.execute("rmdir " .. shell_quote(base)))
end)

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
