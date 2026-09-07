local root = (arg[0]:match("^(.*)/[^/]+$") or ".") .. "/.."
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
-- Fail immediately rather than silently picking up an old standalone rock.
table.insert(package.searchers, 1, function(name)
  if name == "lcatui" or name:match("^lcatui%.") then error("standalone UI dependency: " .. name) end
end)
local spec = {}
assert(loadfile(root .. "/lca-dev-1.rockspec", "t", spec))()
for _, dependency in ipairs(spec.dependencies) do assert(not dependency:match("^lcatui")) end
assert(spec.build.modules["agent.ui"] == "lua/agent/ui/init.lua")
for name, path in pairs(spec.build.modules) do
  if name == "agent.ui" or name:match("^agent%.ui%.") then
    local file = assert(io.open(root .. "/" .. path)); file:close()
    assert(require(name), "UI module missing: " .. name)
  end
end
local ui = require("agent.ui")
local buffer = ui.Buffer.new(8, 1):write(1, 1, "a界b")
assert(buffer:plain_line(1) == "a界b")
assert(package.loaded.lcatui == nil)
print("PASS bundled UI: packaged modules load without standalone lcatui")
