#!/usr/bin/env lua

local script_dir = arg[0]:match("^(.*)/[^/]+$") or "."
local project_dir = script_dir .. "/.."
package.path = project_dir .. "/lua/?.lua;" .. project_dir .. "/lua/?/init.lua;" .. project_dir .. "/lua/?/?.lua;" .. package.path
pcall(require, "luarocks.loader")

local shell = require("agent.util.shell")

local provider_calls = 0

package.loaded["agent.providers"] = {
	load = function()
		return {
			complete = function(request)
				provider_calls = provider_calls + 1
				for _, message in ipairs(request.messages or {}) do
					if tostring(message.text or ""):find("Read%-only loop guard") then
						return { text = "done after guard" }
					end
				end
				return {
					text = table.concat({
						'<tool_call name="read">',
						'{"path":"loop.txt","offset":1,"limit":5}',
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

local function write_file(path, content)
	local f = assert(io.open(path, "w"))
	f:write(content)
	f:close()
end

local tmp_dir = os.tmpname() .. "_lca_read_loop_guard_tests"
os.execute("rm -rf " .. shell.quote(tmp_dir))
os.execute("mkdir -p " .. shell.quote(tmp_dir))

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

io.write("\n" .. dim("═══ Core Read Loop Guard Tests ═══") .. "\n\n")

test("repeated read-only batches are steered instead of executed forever", function()
	write_file(tmp_dir .. "/loop.txt", "one\ntwo\nthree\nfour\nfive\n")
	provider_calls = 0

	local session = session_module.create({})
	session.cwd = tmp_dir
	session:add_user("trigger repeated reads")

	local read_results = 0
	local result = core.run_session(session, nil, function(event)
		if event.name == "read" and event.result then
			read_results = read_results + 1
		end
	end, nil)

	if result.text ~= "done after guard" then
		error("unexpected result: " .. tostring(result.text))
	end
	if provider_calls ~= 7 then
		error("expected 7 provider calls, got " .. tostring(provider_calls))
	end
	if read_results ~= 1 then
		error("expected one executed read before duplicate-range skips, got " .. tostring(read_results))
	end
end)

os.execute("rm -rf " .. shell.quote(tmp_dir))

io.write("\n" .. dim("─────────────────────────────────────") .. "\n")
io.write(string.format("  %s passed, %s failed\n",
	green(tostring(passed)), failed > 0 and red(tostring(failed)) or tostring(failed)))
io.write("\n")
os.exit(failed > 0 and 1 or 0)
