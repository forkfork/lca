-- A still braille sky: slow stellar shimmer and an occasional passing meteor.
local moon = { fg = { 186, 202, 221 } }
local stars = {}
for i = 0, 15 do stars[i + 1] = { fg = { 64 + i * 5, 82 + i * 5, 112 + i * 5 } } end
local trails = {
  { fg = { 51, 68, 96 } }, { fg = { 86, 105, 133 } },
  { fg = { 135, 155, 182 } }, { fg = { 210, 222, 239 } },
}
local bits = { { 1, 2, 4, 64 }, { 8, 16, 32, 128 } }
local function render(buffer, context)
  local w, h, time = buffer.width * 2, buffer.height * 4, context.time
  if w == 0 or h == 0 then return buffer end
  local cells = {}
  local function dot(x, y, style, priority)
    x, y = math.floor(x), math.floor(y)
    if x < 0 or x >= w or y < 0 or y >= h then return end
    local col, row = x // 2 + 1, y // 4 + 1
    local key = (row - 1) * buffer.width + col
    local cell = cells[key] or { row = row, col = col, mask = 0, priority = 0 }
    cell.mask = cell.mask | bits[x % 2 + 1][y % 4 + 1]
    if priority >= cell.priority then cell.style, cell.priority = style, priority end
    cells[key] = cell
  end
  local radius = math.max(1, math.min(5.5, h * 0.34, w * 0.12))
  local mx, my = math.floor(w * 0.68), (h - 1) * 0.46
  local visible = {}
  -- Keep stars outside the entire lunar disk, including its dark side.
  for i = 1, math.max(1, math.floor(buffer.width * buffer.height / 19)) do
    local x = (i * 73 + i * i * 17) % w
    local y = (i * 31 + i * i * 7) % h
    if (x - mx)^2 + (y - my)^2 > (radius + 2)^2 then
      visible[#visible + 1] = { x = x, y = y, seed = i }
    end
  end
  -- Stagger 4–8 second pulses: at most three stars brighten at once.
  local period = math.max(12, #visible * 3)
  for index, star in ipairs(visible) do
    local duration = 4 + star.seed % 5
    local age = (time - (index - 1) * 3) % period
    local pulse = age < duration and math.sin(math.pi * age / duration)^2 or 0
    local base = stars[6 + star.seed % 5].fg
    local lift = math.floor(12 * pulse + 0.5)
    dot(star.x, star.y, { fg = {base[1] + lift, base[2] + lift, base[3] + lift} }, 1)
  end
  -- Subtract an offset disk to carve a crescent, rather than using a moon emoji.
  for y = math.max(0, math.floor(my - radius)), math.min(h - 1, math.ceil(my + radius)) do
    for x = math.max(0, math.floor(mx - radius)), math.min(w - 1, math.ceil(mx + radius)) do
      if (x - mx)^2 + (y - my)^2 <= radius^2
        and (x - mx - radius * 0.58)^2 + (y - my + radius * 0.16)^2 > (radius * 0.94)^2 then
        dot(x, y, moon, 3)
      end
    end
  end
  -- One 1.4-second passage per 18 visual seconds; no random state on repaint.
  local cycle, age = math.floor(time / 18), time % 18 - 6
  if age >= 0 and age < 1.4 then
    local travel = math.min(w * 0.42, 64)
    local origin = w * (0.08 + (cycle % 3) * 0.08)
    local slope = math.min(0.22, h * 0.5 / travel)
    local head = age / 1.1 * travel
    for tail = 14, 0, -1 do
      local distance = head - tail
      local fade = math.min(1, (1.4 - age) / 0.3)
      local level = math.floor((1 - tail / 15) * fade * 4)
      if distance >= 0 and level > 0 then
        dot(origin + distance, h * 0.12 + distance * slope, trails[level], 2)
      end
    end
  end
  -- A broken, low-contrast veil crosses the sky in 38 seconds. Background
  -- shading keeps braille geometry still; covered stars dim very slightly.
  for row = 1, buffer.height do
    for col = 1, buffer.width do
      local u = (col - 0.5) / buffer.width - time / 38
      local centre = 0.48 + 0.12 * math.sin(u * math.pi * 2)
      local band = math.exp(-(((row - 0.5) / buffer.height - centre) / 0.22)^2)
      local gaps = (0.5 + 0.5 * math.cos(u * math.pi * 2))^3
      local density = band * gaps
      local cell = cells[(row - 1) * buffer.width + col]
      local shade = { bg = {math.floor(3 * density), math.floor(5 * density), math.floor(9 * density)} }
      if cell then
        local dim = cell.priority == 1 and math.floor(7 * density) or 0
        local fg = cell.style.fg
        shade.fg = {fg[1] - dim, fg[2] - dim, fg[3] - dim}
      end
      buffer:set(row, col, cell and utf8.char(0x2800 + cell.mask) or " ", shade)
    end
  end
  return buffer
end
return { render = render }
