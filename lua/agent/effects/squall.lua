-- Wind-driven rain in a slate palette, with a short river-wide lightning wash.
local tail = { fg = { 67, 96, 119 }, attrs = { "dim" } }
local rain = { fg = { 112, 148, 169 } }
local head = { fg = { 165, 191, 208 } }
local water = { fg = { 75, 111, 134 } }
local cloud = { fg = { 76, 91, 114 }, attrs = { "dim" } }
local bolt = { fg = { 232, 238, 255 }, attrs = { "bold" } }
local flash_styles = {
  { fg = { 39, 53, 69 }, bg = { 238, 243, 249 } },
  { fg = { 43, 61, 79 }, bg = { 177, 195, 212 } },
  { fg = { 184, 203, 219 }, bg = { 81, 104, 129 } },
  { fg = { 150, 177, 198 }, bg = { 27, 42, 59 } },
}
-- Overlapping slow fronts bring drizzle and gusts without random repaint flicker.
local function intensity(time)
  return 0.5 + 0.4 * math.cos(time * 0.16) + 0.1 * math.cos(time * 0.37)
end
local function strike_age(time)
  local cycle = math.floor(time / 9) * 9
  -- Decide at the strike onset so a flash always finishes its afterglow.
  if intensity(cycle + 2.1) < 0.72 then return -1 end
  return time - cycle - 2.1
end
local function flash_style(time)
  local age = strike_age(time)
  -- One quick illumination and a falling afterglow, not repeated strobing.
  if age < 0 then return nil end
  if age < 0.08 then return flash_styles[1] end
  if age < 0.16 then return flash_styles[2] end
  if age < 0.24 then return flash_styles[3] end
  if age < 0.36 then return flash_styles[4] end
end
local function plot(buffer, x, y, char, style)
  if x >= 1 and x <= buffer.width and y >= 1 and y <= buffer.height then buffer:set(y, x, char, style) end
end
local function render(buffer, context)
  local w, h, time = buffer.width, buffer.height, context.time
  local strength = intensity(time)
  local gust = math.sin(time * 0.43) + 0.3 * math.sin(time * 0.91)
  local direction = gust >= 0 and 1 or -1
  local slant = 0.15 + strength * (0.65 + math.abs(gust) * 0.45)
  -- Integral of the varying speed: drops slow down without jumping backwards.
  local travel = time * 11 + 5.6 / 0.16 * math.sin(time * 0.16) + 1.4 / 0.37 * math.sin(time * 0.37)
  local count = math.max(2, math.floor(w * h / 12 * (0.2 + 0.8 * strength)))
  local trail = strength < 0.35 and 0 or (strength < 0.7 and 1 or 2)
  local drop_style = strength < 0.4 and tail or rain
  for i = 1, count do
    local phase = (travel + i * 7.137) % (h + 4)
    local row = math.floor(phase) - 1
    local anchor = 1 + (i * 41 + math.floor(i / 7) * 13) % w
    local x = 1 + ((anchor + math.floor(phase * slant * direction) - 1) % w)
    local glyph = strength < 0.35 and "│" or (direction > 0 and "╲" or "╱")
    for length = trail, 0, -1 do
      local col = x - math.floor(length * slant * direction)
      plot(buffer, col, row - length, glyph, length == 0 and (strength > 0.7 and i % 3 == 0 and head or drop_style) or tail)
    end
    if row == h + 1 then
      plot(buffer, x, h, "⌣", strength > 0.7 and head or tail)
      if strength > 0.4 then
        plot(buffer, x - 1, h, "╴", water)
        plot(buffer, x + 1, h, "╶", water)
      end
    end
  end
  for i = 1, math.max(1, math.floor(w / 11 * (0.3 + 0.7 * strength))) do
    local x = 1 + (i * 37) % w
    -- Single-column ripples: labels/dissolves overwrite cells individually.
    local crest = math.floor(time * 4 + i) % 3 == 0
    plot(buffer, x, h, crest and "~" or "▁", strength < 0.4 and tail or water)
    if crest and strength > 0.4 then plot(buffer, x + 1, h, "~", water) end
  end
  for x = 1, w do
    if math.sin(x * 0.17 + time * 0.7) > 1 - 0.45 * strength then plot(buffer, x, 1, "╌", cloud) end
  end
  local age = strike_age(time)
  if age >= 0 and age < 0.12 then
    local origin = 1 + (math.floor(time / 9) * 47 + math.floor(w * 0.62)) % w
    local length = math.min(h, math.max(2, math.ceil(h * 0.6)))
    for y = 1, length do
      local x = origin + (y % 2)
      plot(buffer, x, y, y % 2 == 0 and "╱" or "╲", bolt)
      if y == length then plot(buffer, x + 1, y, "╲", bolt) end
    end
  end
  return buffer
end
return { render = render, flash_style = flash_style }
