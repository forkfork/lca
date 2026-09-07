local root = (arg[0]:match("^(.*)/[^/]+$") or ".") .. "/.."
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
pcall(require, "luarocks.loader")
local duet = require("agent.effects.duet")
local effects = require("agent.tui_effects")
local ui = require("agent.ui")
local Replay = require("agent.tui_replay")
local json = require("agent.util.json")
local function advance(state, scene, frames)
  for _ = 1, frames do state = duet.step(state, 1/30, scene) end
  return state
end
local function image(buffer)
  local lines = {}
  for row = 1, buffer.height do lines[#lines + 1] = buffer:styled_line(row, true) end
  return table.concat(lines, "\n")
end
assert(effects.known("duet"))
local scene = {active=true, turn=1, tools={}}
local state = advance(nil, scene, 20)
assert(#state.voices[1].trail > 0 and #state.voices[2].trail == 0, "model-only work invented a tool voice")
scene.tools = {{id="read", status="active"}, {id="edit", status="active"}}
state = advance(state, scene, 20)
assert(#state.voices[2].trail > 0 and state.serial == 2)
scene.tools[1].status = "ok"
state = advance(state, scene, 1)
assert(state.serial == 3 and state.voices[1].remaining > 1.5, "result did not answer the lead")
scene.tools[2].status = "error"
state = advance(state, scene, 45)
assert(state.voices[2].failed and state.voices[2].trail[#state.voices[2].trail].broken)
local frozen, source = json.encode(state), json.encode(scene)
for _, size in ipairs({{1,1}, {40,3}, {100,6}, {160,8}}) do
  local a, b = ui.Buffer.new(size[1], size[2]), ui.Buffer.new(size[1], size[2])
  effects.render("duet", a, {duet=state, scene=scene})
  effects.render("duet", b, {duet=state, scene=scene})
  assert(image(a) == image(b), "repaint advanced the voices")
  for row = 1, a.height do
    for col = 1, a.width do assert(ui.width.string(a.rows[row][col].char) == 1) end
  end
end
assert(json.encode(state) == frozen and json.encode(scene) == source)
scene.active, scene.listening, scene.failed = false, true, true
state = advance(state, scene, 1)
assert(state.cadence > 0 and state.voices[1].remaining > 0 and state.voices[2].remaining > 0)
state = advance(state, scene, 150)
assert(#state.voices[1].trail == 0 and #state.voices[2].trail == 0, "completed turn never rested")
local backend = {width=100, height=24}
function backend:size() return self.width, self.height end
function backend:supports_color() return true end
function backend:write() end
function backend:flush() end
local player = Replay.new(Replay.load(root .. "/tests/fixtures/tui-replay.json"), {backend=backend, effect="duet"})
for _ = 1, 70 do player:step() end
player:feed_input("keep draft\16"); player:draw()
local before = image(player.app.renderer.previous)
player:draw()
assert(image(player.app.renderer.previous) == before, "paused repaint changed duet")
assert(player.app.editor:text() == "keep draft")
backend.width, backend.height = 60, 18
player:draw()
assert(player.app.frame.width == 60)
player:feed_input("\5"); player:draw()
assert(player.app.effect == "contours" and player.app.editor:text() == "keep draft")
print("PASS duet: event-led voices, failure/rest/cadence, deterministic repaint, resize and live switching")
