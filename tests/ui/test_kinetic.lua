local h = require("tests.ui.helper")
local Buffer = require("agent.ui.buffer")
local kinetic = require("agent.ui.kinetic")

h.test("classifies glyphs by visual material", function()
  h.equal(kinetic.family("─"), "horizontal")
  h.equal(kinetic.family("O"), "round")
  h.equal(kinetic.family("M"), "dense")
  h.equal(kinetic.family("/"), "angle")
end)

h.test("scattered character layouts are deterministic", function()
  local bounds = { width = 60, height = 20 }
  local left = kinetic.scatter("return value", 10, 20, bounds, 9)
  local right = kinetic.scatter("return value", 10, 20, bounds, 9)
  for index, item in ipairs(left) do
    h.equal(item.source_row, right[index].source_row)
    h.equal(item.source_col, right[index].source_col)
  end
end)

h.test("kinetic text settles into exact semantic content", function()
  local text = "return value"
  local entities = kinetic.scatter(text, 4, 3, { width = 40, height = 8 }, 4)
  local buffer = Buffer.new(40, 8)
  kinetic.draw(buffer, entities, 1)
  h.equal(buffer:plain_line(4):sub(3), text)
end)

h.finish()
