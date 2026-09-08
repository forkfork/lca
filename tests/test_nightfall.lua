local root = (arg[0]:match("^(.*)/[^/]+$") or ".") .. "/.."
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
pcall(require, "luarocks.loader")
local ui = require("agent.ui")
local effects = require("agent.tui_effects")
local json = require("agent.util.json")
local function frame(w, h, time, scene)
  local b = ui.Buffer.new(w, h)
  assert(effects.render("nightfall", b, {time=time, scene=scene or {}}) == b)
  local plain, styled = {}, {}
  for y = 1, h do
    plain[y], styled[y] = b:plain_line(y), b:styled_line(y, true)
    for x = 1, w do
      local char = b.rows[y][x].char
      assert(ui.width.string(char) == 1)
      assert(not b.rows[y][x].style or b.rows[y][x].style.bg == nil, "sky overrides terminal background")
      assert(char == " " or (utf8.codepoint(char) > 0x2800 and utf8.codepoint(char) <= 0x28ff))
    end
  end
  return table.concat(plain, "\n"), table.concat(styled, "\n"), b
end
assert(effects.known("nightfall") and not effects.native("nightfall"))
local names = effects.names()
assert(names[#names] == "nightfall")
for _, size in ipairs({{1,1}, {12,2}, {40,3}, {80,4}, {120,6}}) do
  local scene = {failed=true, vortices={{id="tool", x=5, y=2}}}
  local before = json.encode(scene)
  for _, t in ipairs({0, 3, 6, 6.2, 6.7, 7.2, 7.4, 18, 24.5, 1000}) do
    local plain, styled, b = frame(size[1], size[2], t, scene)
    local again, painted = frame(size[1], size[2], t, scene)
    assert(plain == again and styled == painted, "repaint flickers")
    assert(json.encode(scene) == before, "paint mutated scene")
    assert(effects.flash_style("nightfall", t) == nil)
    b:write(1, 1, "tool", nil, size[1])
    assert(ui.width.string(b:styled_line(1, false)) <= size[1], "overlay overflow")
  end
end
local quiet, style = frame(80, 4, 0)
local still, twinkle = frame(80, 4, 3)
assert(quiet == still and style ~= twinkle, "stars should shimmer without moving")
assert(frame(80, 4, 6.3) ~= quiet, "missing shooting star")
assert(frame(80, 4, 6.7) ~= frame(80, 4, 6.3), "shooting star did not travel")
assert(frame(80, 4, 7.4) == quiet, "meteor did not fade away")
local _, _, base = frame(80, 4, 0)
local _, _, meteor = frame(80, 4, 6.7)
local moon_cells, occupied = 0, 0
for y = 1, 4 do
  for x = 1, 80 do
    local c = base.rows[y][x]
    if c.char ~= " " then occupied = occupied + 1 end
    if c.style and c.style.fg and c.style.fg[1] == 186 then
      moon_cells = moon_cells + 1
      assert(c.char == meteor.rows[y][x].char, "moon moved")
    end
  end
end
assert(moon_cells > 1 and occupied < 80 * 4 / 5, "sky should be sparse with a visible moon")
-- The haze changes star foregrounds, never positions or the terminal background.
local _, _, drift = frame(80, 4, 10)
local changed = 0
for y = 1, 4 do
  for x = 1, 80 do
    local a, b = base.rows[y][x], drift.rows[y][x]
    assert(a.char == b.char, "haze moved a star")
    assert(a.style.bg == nil and b.style.bg == nil, "sky overrides terminal background")
    if a.style.fg and b.style.fg and a.style.fg[1] ~= b.style.fg[1] then changed = changed + 1 end
  end
end
assert(changed > 0, "star shading did not change")
-- Adjacent frames must not flash, including pulse and haze cycle boundaries.
for _, t in ipairs({0, 3, 8, 10, 37.99, 38, 1000}) do
  local _, _, a = frame(80, 4, t)
  local _, _, b = frame(80, 4, t + 1/30)
  for y = 1, 4 do
    for x = 1, 80 do
      for _, channel in ipairs({"fg", "bg"}) do
        local left, right = a.rows[y][x].style[channel], b.rows[y][x].style[channel]
        if left and right then
          for c = 1, 3 do assert(math.abs(left[c] - right[c]) <= 2, "sky flashed") end
        end
      end
    end
  end
end
print("PASS nightfall: stable sky, gentle twinkles, drifting haze, meteor, resize and overlays")
