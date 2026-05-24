#!/usr/bin/env lua

local script_dir = arg[0]:match("^(.*)/[^/]+$") or "."
local project_dir = script_dir .. "/.."
package.path = project_dir .. "/lua/?.lua;" .. project_dir .. "/lua/?/init.lua;" .. package.path
pcall(require, "luarocks.loader")

local codex = require("agent.providers.codex")

local function usage()
	io.stderr:write([[usage: lca-cache-probe [--out DIR]

Generate progressively more LCA-like Codex request bodies and compare prefix stability.
No network requests are made.

Defaults:
  --out /tmp/lca-cache-probe
]])
end

local function parse_args(argv)
	local opts = { out = "/tmp/lca-cache-probe" }
	local i = 1
	while i <= #argv do
		if argv[i] == "--out" then
			i = i + 1
			opts.out = argv[i]
		elseif argv[i] == "-h" or argv[i] == "--help" then
			usage()
			os.exit(0)
		else
			error("unknown argument: " .. tostring(argv[i]))
		end
		i = i + 1
	end
	return opts
end

local function shell_quote(value)
	return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function write_file(path, text)
	local f, err = io.open(path, "wb")
	if not f then
		error("failed to write " .. path .. ": " .. tostring(err))
	end
	f:write(text)
	f:close()
end

local function common_prefix(a, b)
	local limit = math.min(#a, #b)
	for i = 1, limit do
		if a:byte(i) ~= b:byte(i) then
			return i - 1
		end
	end
	return limit
end

local function tool_call(name, body)
	return '<tool_call name="' .. name .. '">\n' .. body .. "\n</tool_call>"
end

local function tool_result(name, attrs, body)
	return '<tool_result name="' .. name .. '" status="ok" ' .. attrs .. ">\n" .. body .. "\n</tool_result>"
end

local static_file = {}
for i = 1, 220 do
	static_file[#static_file + 1] = string.format("%03d: function stable_%03d() return %d end", i, i, i)
end
static_file = table.concat(static_file, "\n")

local base_messages = {
	{ role = "user", text = "We are working in /tmp/cache-probe. Keep changes focused." },
	{ role = "assistant", text = tool_call("read", '{"path":"fake_tmux.py","offset":1,"limit":220}') },
	{ role = "user", text = tool_result("read", 'path="fake_tmux.py" offset="1" limit="220"', static_file) },
	{ role = "assistant", text = "I see the stable file shape and will inspect the command parser next." },
}

local scenarios = {
	{
		name = "01-base",
		messages = base_messages,
	},
	{
		name = "02-same-prefix-new-user-tail",
		messages = {
			base_messages[1],
			base_messages[2],
			base_messages[3],
			base_messages[4],
			{ role = "user", text = "Add status JSON next." },
		},
	},
	{
		name = "03-same-prefix-tool-tail",
		messages = {
			base_messages[1],
			base_messages[2],
			base_messages[3],
			base_messages[4],
			{ role = "user", text = "Add status JSON next." },
			{ role = "assistant", text = tool_call("read", '{"path":"README.md","offset":40,"limit":60}') },
			{ role = "user", text = tool_result("read", 'path="README.md" offset="40" limit="60"', string.rep("README stable line\n", 80)) },
		},
	},
	{
		name = "04-slimmed-old-read",
		messages = {
			base_messages[1],
			base_messages[2],
			{ role = "user", text = '<tool_result name="read" status="ok" path="fake_tmux.py" slimmed="true">[slimmed previous read result]</tool_result>' },
			base_messages[4],
			{ role = "user", text = "Add status JSON next." },
			{ role = "assistant", text = tool_call("read", '{"path":"README.md","offset":40,"limit":60}') },
			{ role = "user", text = tool_result("read", 'path="README.md" offset="40" limit="60"', string.rep("README stable line\n", 80)) },
		},
	},
}

local opts = parse_args(arg)
os.execute("rm -rf " .. shell_quote(opts.out) .. " && mkdir -p " .. shell_quote(opts.out))

local previous
print("cache probe output: " .. opts.out)
for _, scenario in ipairs(scenarios) do
	local body = codex._request_body({
		model = "gpt-5.5",
		session_id = "lca-cache-probe",
		system_prompt = "You are a coding agent. Static instructions stay at the beginning.",
		messages = scenario.messages,
	})
	local path = opts.out .. "/" .. scenario.name .. ".json"
	write_file(path, body)
	local line = string.format("  %s  %d bytes", scenario.name, #body)
	if previous then
		local common = common_prefix(previous.body, body)
		line = line .. string.format("  common-with-prev=%d bytes (%.1f%%)", common, common / math.max(1, #previous.body) * 100)
	end
	print(line)
	previous = { name = scenario.name, body = body }
end

print("")
print("Compare any pair with:")
print("  lca-prompt-diff " .. opts.out .. "/01-base.json " .. opts.out .. "/02-same-prefix-new-user-tail.json")
