local root = assert(require("luv").cwd())
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
require("luarocks.loader")
local uv = require("luv")
local json = require("agent.util.json")
local state = require("agent.operational_state")
local original_render = state.render
local shell = require("agent.util.shell")
local tmp = assert(uv.fs_mkdtemp("/tmp/lca-operational-screen-XXXXXX"))
local function read(path)
	local f = assert(io.open(path)); local body = f:read("*a"); f:close(); return body
end
local contexts = {}
for _, scenario in ipairs({"stale_pass", "unresolved_failure"}) do
	for _, arm in ipairs({"with_state", "without_state"}) do
		state.render = original_render
		local dir = tmp .. "/" .. scenario .. "-" .. arm
		assert(uv.fs_mkdir(dir, 493))
		assert(os.execute("cp -R " .. shell.quote(root .. "/evals/scenarios/compaction_stale_pass/fixture") .. " " .. shell.quote(dir .. "/workspace")))
		assert(uv.chdir(dir .. "/workspace"))
		local session = require("agent.session").create({})
		dofile(root .. "/evals/operational_screen.lua").setup(session, arm, scenario, dir)
		assert(session.messages[1].text:find("Context from previous conversation", 1, true))
		assert(not read("invoice.py"):find("subtotal +", 1, true))
		local saved = json.decode(read(dir .. "/seed-history.json"))
		assert(#saved.events == (scenario == "stale_pass" and 4 or 6))
		local sent = state.request_messages(session)
		assert(#sent == #session.messages + (arm == "with_state" and 1 or 0))
		if arm == "with_state" then contexts[scenario] = session.messages[1].text
		else assert(contexts[scenario] == session.messages[1].text, "arms must receive identical summary") end
		assert(uv.chdir(root))
	end
end
state.render = original_render
-- Clean only the isolated fixture tree created by this test.
local function remove(path)
	local stat = assert(uv.fs_stat(path))
	if stat.type ~= "directory" then assert(uv.fs_unlink(path)); return end
	local scan = assert(uv.fs_scandir(path))
	while true do local name = uv.fs_scandir_next(scan); if not name then break end; remove(path .. "/" .. name) end
	assert(uv.fs_rmdir(path))
end
remove(tmp)
print("PASS operational screen: real seed executions, compaction, identical summaries, state ablation")
