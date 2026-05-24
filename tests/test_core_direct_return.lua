#!/usr/bin/env lua

local script_dir = arg[0]:match("^(.*)/[^/]+$") or "."
local project_dir = script_dir .. "/.."
package.path = project_dir .. "/lua/?.lua;" .. project_dir .. "/lua/?/init.lua;" .. project_dir .. "/lua/?/?.lua;" .. package.path
pcall(require, "luarocks.loader")

local calls = 0

package.loaded["agent.providers"] = {
	load = function()
		return {
			complete = function()
				calls = calls + 1
				if calls > 1 then
					error("provider should not be called again after direct curl result")
				end
				return {
					text = table.concat({
						'<tool_call name="run">',
						'{"command":"printf hello","timeout":120000}',
						"</tool_call>",
					}, "\n"),
				}
			end,
		}
	end,
}

local core = require("agent.core")
local session_module = require("agent.session")

local passed = 0
local failed = 0

local function green(s) return "\27[32m" .. s .. "\27[0m" end
local function red(s) return "\27[31m" .. s .. "\27[0m" end
local function dim(s) return "\27[2m" .. s .. "\27[0m" end

local function test(name, fn)
	io.write("  " .. name .. " ")
	io.flush()
	local ok, err = pcall(fn)
	if ok then
		passed = passed + 1
		io.write(green("PASS") .. "\n")
	else
		failed = failed + 1
		io.write(red("FAIL") .. " (" .. tostring(err):sub(1, 120) .. ")\n")
	end
end

io.write("\n" .. dim("═══ Core Direct Return Tests ═══") .. "\n\n")

test("curl prompt returns run result without final model call", function()
	local session = session_module.create({})
	session.cwd = project_dir
	session:add_user("curl it")

	local result = core.run_session(session, nil, nil, nil)
	if result.text ~= "hello" then
		error("unexpected direct result: " .. tostring(result.text))
	end
	if calls ~= 1 then
		error("expected one provider call, got " .. tostring(calls))
	end
end)

io.write("\n" .. dim("─────────────────────────────────────") .. "\n")
io.write(string.format("  %s passed, %s failed\n",
	green(tostring(passed)), failed > 0 and red(tostring(failed)) or tostring(failed)))
io.write("\n")
os.exit(failed > 0 and 1 or 0)
