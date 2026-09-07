local h = require("tests.ui.helper")
local Buffer = require("agent.ui.buffer")
local Current = require("agent.ui.current")

local function nonblank(buffer, first_col, last_col)
  local count = 0
  for row = 1, buffer.height do
    for col = first_col, last_col do
      if buffer.rows[row][col].char ~= " " then count = count + 1 end
    end
  end
  return count
end

h.test("actors appear from edges and leave the centre sparse", function()
  local current = Current.new(100, 24)
  for _ = 1, 6 do
    current:step(0.1, { actors = {
      { id = "left", edge = "left", anchor = 0.3 },
      { id = "right", edge = "right", anchor = 0.7 },
    } })
  end
  local buffer = Buffer.new(100, 24)
  current:render(buffer, {})
  h.truthy(nonblank(buffer, 1, 20) > 2)
  h.truthy(nonblank(buffer, 81, 100) > 2)
  h.truthy(nonblank(buffer, 41, 60) < nonblank(buffer, 1, 20) + nonblank(buffer, 81, 100))
end)

h.test("resolved actors return a stroke to assembly", function()
  local current = Current.new(80, 20)
  current:step(1, { actors = { { id = "done", edge = "left", anchor = 0.5, resolved = true } } })
  local buffer = Buffer.new(80, 20)
  current:render(buffer, { core_x = 44, core_y = 10, style = { "bold" } })
  h.truthy(nonblank(buffer, 25, 44) > 8)
end)

h.test("waiting retains only quiet edge fossils", function()
  local current = Current.new(80, 20)
  current:step(0.5, { listening = true })
  local buffer = Buffer.new(80, 20)
  current:render(buffer, { listening = true })
  h.truthy(nonblank(buffer, 1, 80) >= 8)
  h.equal(nonblank(buffer, 25, 55), 0)
end)

h.test("filament spans the aperture and responds to concurrent actors", function()
  local current = Current.new(100, 6, { mode = "filament" })
  for _ = 1, 20 do
    current:step(0.04, { actors = {
      { id = "read-a", x = 20, strength = 1.1 },
      { id = "edit-b", x = 78, strength = 1.4, failed = true },
    } })
  end
  local buffer = Buffer.new(100, 6)
  current:render(buffer, { failed = true })
  h.truthy(nonblank(buffer, 1, 20) > 12)
  h.truthy(nonblank(buffer, 41, 60) > 12)
  h.truthy(nonblank(buffer, 81, 100) > 12)
end)

h.test("effect modes can be changed without replacing the current", function()
  local current = Current.new(80, 6, { mode = "drift" })
  local drift = Buffer.new(80, 6)
  current:step(0.2, { listening = true })
  current:render(drift, { listening = true })
  h.truthy(nonblank(drift, 1, 80) >= 8)
  h.truthy(current:set_mode("filament"))
  local filament = Buffer.new(80, 6)
  current:render(filament, { listening = true })
  h.truthy(nonblank(filament, 1, 80) >= 60)
  h.equal(current:set_mode("unknown"), nil)
end)

h.test("drift morphs between listening activity tools failure and resolution", function()
  local current = Current.new(100, 6, { mode = "drift" })
  current:step(0.2, { listening = true })
  h.truthy(current.morph.listening > 0.9)
  current:step(0.2, { active = true, activity = 0.9 })
  h.truthy(current.morph.energy > 0)
  h.truthy(current.morph.energy < 0.9)
  current:step(0.2, { active = true, activity = 0.9, actors = { { id = "edit", x = 50, y = 3 } } })
  h.truthy(current.morph.tools > 0)
  h.truthy(current.morph.tools < 1)
  current:step(0.2, { active = true, failed = true })
  h.truthy(current.morph.failure > 0.5)
  current:step(0.2, { active = true, proof = 1 })
  h.truthy(current.morph.resolution > 0)
  h.truthy(current.morph.failure > 0)
  current:step(0.2, { listening = true })
  h.truthy(current.morph.energy > 0)
  h.truthy(current.morph.listening > 0)
end)

h.finish()
