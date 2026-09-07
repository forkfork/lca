local Current = {}
Current.__index = Current

local function clamp(n, low, high) return math.max(low, math.min(high, n)) end
local function rgb(r, g, b, attrs) return { fg = { r, g, b }, attrs = attrs or {} } end
local function hash(text)
  local value = 17
  for index = 1, #text do value = (value * 33 + text:byte(index)) % 104729 end
  return value
end
local function style_for(scene, intensity, actor)
  if type(scene.style) == "function" then return scene.style(intensity, actor) end
  if scene.style then return scene.style end
  if scene.failed or actor.failed then return rgb(217, 66, 105, { intensity > 0.6 and "bold" or "dim" }) end
  if actor.resolved then return rgb(72, 205, 156, { intensity > 0.55 and "bold" or "dim" }) end
  if scene.listening then return rgb(49, 125, 137, { "dim" }) end
  return rgb(102, 64 + math.floor(72 * intensity), 159 + math.floor(66 * intensity), { intensity > 0.65 and "bold" or "dim" })
end

local function line(buffer, x1, y1, x2, y2, cell_style, mask)
  local dx, dy = x2 - x1, y2 - y1
  local steps = math.max(math.abs(dx), math.abs(dy))
  if steps == 0 then return end
  local glyph = math.abs(dx) > math.abs(dy) * 2 and "─" or math.abs(dy) > math.abs(dx) * 2 and "│" or dx * dy > 0 and "╲" or "╱"
  for step = 0, steps do
    local x = math.floor(x1 + dx * step / steps + 0.5)
    local y = math.floor(y1 + dy * step / steps + 0.5)
    if not mask or mask(x, y) then buffer:set(y, x, glyph, cell_style) end
  end
end

local MODES = { contours = true, drift = true }

function Current.new(cols, rows, opts)
  opts = opts or {}
  local mode = MODES[opts.mode] and opts.mode or "contours"
  return setmetatable({
    cols = cols, rows = rows, time = 0, actors = {}, mode = mode,
    morph = { energy = 0, tools = 0, failure = 0, resolution = 0, listening = 1 },
  }, Current)
end

function Current:set_mode(mode)
  if not MODES[mode] then return nil, "unknown current effect: " .. tostring(mode) end
  self.mode = mode
  return true
end

function Current.modes()
  return { "contours", "drift" }
end

local function mix(a, b, amount) return a + (b - a) * amount end

function Current:_render_drift(buffer, scene)
  local morph = self.morph
  local intensity = clamp(0.25 + morph.energy * 0.28 + morph.tools * 0.18 + morph.failure * 0.3 + morph.resolution * 0.2, 0.2, 1)
  local quiet = style_for(scene.listening and { listening = true } or scene, intensity, {})
  local speed = 8 + morph.energy * 7 + morph.tools * 4 + morph.failure * 7
  local shift = math.floor(self.time * speed)
  local density = 1 + morph.energy * 0.45 + morph.tools * 0.35
  local count = math.max(8, math.floor(self.cols / 10 * density))
  local ribbon = clamp(morph.energy * 0.72 + morph.resolution * 0.9, 0, 1)
  for index = 0, count do
    local x = (index * 23 + shift * (index % 3 + 1)) % self.cols + 1
    local dust_y = (self.rows + 1) / 2 + math.sin(self.time * 1.8 + index * 1.7) * math.max(1, self.rows * 0.35)
    local ribbon_y = (self.rows + 1) / 2 + math.sin(x * 0.105 - self.time * 2.5 + index * 0.09) * math.max(0.7, self.rows * 0.18)
    local turbulence = math.sin(index * 9.71 + math.floor(self.time * 14) * 2.37) * morph.failure * self.rows * 0.42
    local y = clamp(math.floor(mix(dust_y, ribbon_y, ribbon) + turbulence + 0.5), 1, self.rows)
    local glyphs = morph.failure > 0.45 and { "⠿", "×", "⡇", "⠸", "·", "╳" }
      or morph.resolution > 0.45 and { "◆", "·", "─", "◇", "·", "━" }
      or ribbon > 0.38 and { "⠤", "•", "╌", "⠒", "·", "˙" }
      or { "⠁", "⠂", "⠄", "⡀", "·", "˙" }
    buffer:set(y, x, glyphs[index % #glyphs + 1], quiet)
  end

  -- Active runtime actors pull a few particles into small local eddies. Their
  -- presence eases in and out, so filenames can pass through without a snap.
  for _, actor in pairs(self.actors) do
    local presence = actor.presence * morph.tools
    if presence > 0.04 then
      local cx = clamp(math.floor(actor.x or (actor.hash % self.cols + 1)), 1, self.cols)
      local cy = clamp(math.floor(actor.y or ((actor.hash >> 3) % self.rows + 1)), 1, self.rows)
      local points = math.max(1, math.floor(4 * presence + 0.5))
      for point = 1, points do
        local angle = self.time * (2.4 + (actor.hash % 5) * 0.13) + point * math.pi * 0.5
        local radius = 1 + presence * 2.5
        local x = clamp(math.floor(cx + math.cos(angle) * radius * 2 + 0.5), 1, self.cols)
        local y = clamp(math.floor(cy + math.sin(angle) * radius * 0.7 + 0.5), 1, self.rows)
        local glyph = actor.failed and "×" or actor.resolved and "◇" or ({ "⠋", "⠙", "⠹", "⠸" })[point]
        buffer:set(y, x, glyph, style_for(scene, clamp(0.35 + presence * 0.5, 0, 1), actor))
      end
    end
  end
end

local function ease(current, target, rate, dt)
  return current + (target - current) * (1 - math.exp(-rate * math.max(0, dt)))
end

function Current:step(dt, scene)
  scene = scene or {}
  self.time = self.time + math.max(0, tonumber(dt) or 0)
  local seen, seen_count = {}, 0
  for index, source in ipairs(scene.actors or scene.resonators or scene.vortices or {}) do
    local id = tostring(source.id or ("actor-" .. index))
    local actor = self.actors[id] or { id = id, presence = 0, born = self.time, hash = hash(id) }
    for key, value in pairs(source) do actor[key] = value end
    actor._cols = self.cols
    actor.target = 1
    self.actors[id], seen[id] = actor, true
    seen_count = seen_count + 1
  end
  for id, actor in pairs(self.actors) do
    actor.target = seen[id] and 1 or 0
    local rate = actor.target > actor.presence and 7 or 2.5
    actor.presence = actor.presence + (actor.target - actor.presence) * clamp(dt * rate, 0, 1)
    if actor.presence < 0.015 and actor.target == 0 then self.actors[id] = nil end
  end
  self.listening = scene.listening == true
  self.failed = scene.failed == true
  local morph = self.morph
  morph.energy = ease(morph.energy, scene.active and clamp(tonumber(scene.activity) or 0.8, 0, 1) or 0, 2.4, dt)
  morph.tools = ease(morph.tools, seen_count > 0 and 1 or 0, 3.2, dt)
  morph.failure = ease(morph.failure, scene.failed and 1 or 0, scene.failed and 5.5 or 1.8, dt)
  morph.resolution = ease(morph.resolution, scene.proof and scene.proof > 0 and not scene.listening and 1 or 0, 3.4, dt)
  morph.listening = ease(morph.listening, scene.listening and 1 or 0, 1.7, dt)
  return self
end

function Current:render(buffer, scene)
  scene = scene or {}
  if self.mode == "drift" then self:_render_drift(buffer, scene); return buffer end
  local core_x = math.floor(scene.core_x or self.cols * 0.53)
  local core_y = math.floor(scene.core_y or self.rows * 0.52)
  local mask = scene.mask
  local count = 0
  for _, actor in pairs(self.actors) do
    count = count + 1
    local edge = actor.edge or ({ "left", "top", "right", "bottom" })[actor.hash % 4 + 1]
    local pulse = math.sin(self.time * (actor.resolved and 2.2 or 4.1) + actor.hash * 0.07)
    local radius = math.max(5, math.floor((actor.radius or math.min(self.cols * 0.22, self.rows * 1.35)) + pulse * (actor.resolved and 0.25 or 0.7)))
    local anchor = actor.anchor or ((actor.hash % 71) / 70)
    local cx, cy
    if edge == "left" then cx, cy = -math.floor(radius * 0.72), 2 + anchor * (self.rows - 3)
    elseif edge == "right" then cx, cy = self.cols + math.floor(radius * 0.72), 2 + anchor * (self.rows - 3)
    elseif edge == "top" then cx, cy = 2 + anchor * (self.cols - 3), -math.floor(radius * 0.48)
    else cx, cy = 2 + anchor * (self.cols - 3), self.rows + math.floor(radius * 0.48) end
    local intensity = clamp((actor.amplitude or actor.strength or 0.8) * actor.presence, 0.12, 1)
    local actor_style = style_for(scene, intensity, actor)
    for y = 1, self.rows do
      for x = 1, self.cols do
        local nx, ny = x - cx, (y - cy) * 2
        local distance = math.sqrt(nx * nx + ny * ny)
        if math.abs(distance - radius) < 0.48 and (not mask or mask(x, y)) then
          local tangent = math.atan(ny, nx) + math.pi / 2
          local ax, ay = math.abs(math.cos(tangent)), math.abs(math.sin(tangent))
          local glyph = ay < 0.25 and "─" or ax < 0.25 and "│" or math.cos(tangent) * math.sin(tangent) > 0 and "╲" or "╱"
          buffer:set(y, x, glyph, actor_style)
        end
      end
    end
    if actor.resolved then
      local distance = math.max(1, math.sqrt((core_x - cx)^2 + ((core_y - cy) * 2)^2))
      local sx = clamp(math.floor(cx + (core_x - cx) * radius / distance), 1, self.cols)
      local sy = clamp(math.floor(cy + (core_y - cy) * radius / distance / 2), 1, self.rows)
      line(buffer, sx, sy, core_x, core_y, actor_style, mask)
    end
  end
  if count == 0 and self.rows <= 8 then
    -- The inline adapter only has six world rows. A handful of travelling edge
    -- fragments keeps that tiny aperture alive without inventing a second mode.
    local quiet = style_for({ listening = true }, 0.25, {})
    local shift = math.floor(self.time * 20)
    for index = 0, 17 do
      local x = (index * 17 + shift * 3) % self.cols + 1
      local y = 3 + (index * 5 + shift) % math.max(1, self.rows - 2)
      buffer:set(y, x, ({ "╱", "─", "╲", "·" })[index % 4 + 1], quiet)
    end
  elseif (scene.listening or self.listening) and count == 0 then
    local quiet = style_for({ listening = true }, 0.25, {})
    local breath = math.floor(self.time * 2) % 2
    buffer:write(2 + breath, 1, "╭──", quiet, 3)
    buffer:write(math.max(1, self.rows - 2 - breath), math.max(1, self.cols - 2), "──╯", quiet, 3)
    buffer:set(math.floor(self.rows * 0.54), 1 + breath, "(", quiet)
    buffer:set(math.floor(self.rows * 0.42), self.cols - breath, ")", quiet)
  end
  return buffer
end

return Current
