-- Two event-led voices. Simulation advances only on frames, never on repaint.
local duet = {}
local function clamp(x, a, b) return math.max(a, math.min(b, x)) end
local function phrase(voice, duration, seed, failed)
  voice.remaining, voice.duration = duration, duration
  voice.seed, voice.failed = seed, failed
end
function duet.step(state, dt, scene)
  state = state or { time = 0, seen = {}, voices = {
    { remaining = 0, seed = 0, trail = {} }, { remaining = 0, seed = 1, trail = {} },
  }, next_phrase = 0, serial = 0 }
  dt = clamp(dt, 0, 0.12)
  state.time = state.time + dt
  local lead, answer = state.voices[1], state.voices[2]
  if state.turn ~= scene.turn then
    state.turn, state.seen, state.next_phrase = scene.turn, {}, state.time
  end
  local active, changed, returned, failed = 0, false, false, false
  local seen = {}
  for _, tool in ipairs(scene.tools or {}) do
    seen[tool.id] = tool.status
    if tool.status == "active" then active = active + 1 end
    if state.seen[tool.id] ~= tool.status then
      changed = true
      returned = returned or tool.status == "ok"
      failed = failed or tool.status == "error"
      state.serial = state.serial + 1
    end
  end
  state.seen = seen
  if changed then
    phrase(answer, failed and 2.4 or returned and 1.9 or 2.8, state.serial, failed)
    if returned then phrase(lead, 1.6, state.serial, false) end
  elseif active > 0 and answer.remaining <= -0.5 then
    phrase(answer, 2.1 + math.min(active, 4) * 0.25, state.serial + active, false)
  end
  if scene.active and state.time >= state.next_phrase then
    -- Tools take the foreground; the lead leaves longer rests during their work.
    phrase(lead, active > 0 and 1.3 or 2.5, state.serial + math.floor(state.time / 3), false)
    state.next_phrase = state.time + (active > 0 and 4.7 or 3.6)
  end
  if state.was_active and not scene.active then
    state.cadence = 1.8
    phrase(lead, 1.8, state.serial, scene.failed)
    phrase(answer, 1.8, state.serial, scene.failed)
  end
  state.was_active = scene.active
  state.cadence = math.max(0, (state.cadence or 0) - dt)
  state.accumulator = (state.accumulator or 0) + dt
  while state.accumulator >= 1 / 30 do
    state.accumulator = state.accumulator - 1 / 30
    for index, voice in ipairs(state.voices) do
      voice.remaining = voice.remaining - 1 / 30
      for i = #voice.trail, 1, -1 do
        local point = voice.trail[i]
        point.age = point.age + 1 / 30
        if point.age > 1.35 then table.remove(voice.trail, i) end
      end
      if voice.remaining > 0 then
        local p = 1 - voice.remaining / voice.duration
        local direction = index == 1 and 1 or -1
        local x = index == 1 and (0.06 + p * 0.88) or (0.94 - p * 0.88)
        -- A stepped melodic contour, smoothly joined, rather than orbiting waves.
        local notes = { 0.18, 0.72, 0.42, 0.86, 0.30, 0.58, 0.12 }
        local pos = p * 5
        local n = math.floor(pos)
        local blend = (pos - n) ^ 2 * (3 - 2 * (pos - n))
        local a = notes[(n + voice.seed) % #notes + 1]
        local b = notes[(n + voice.seed + 1) % #notes + 1]
        local y = a + (b - a) * blend
        if index == 2 then y = 1 - y end
        if state.cadence > 0 then
          x = 0.5 + direction * (0.44 * (1 - p))
          y = y * (1 - p) + 0.5 * p
        elseif voice.failed and p > 0.55 then
          x = index == 1 and 0.54 or 0.46 -- suspend the broken answer
          y = 0.28
        end
        voice.trail[#voice.trail + 1] = { x = x, y = y, age = 0, broken = voice.failed and p > 0.55 }
      end
    end
  end
  return state
end
local palettes = { { 109, 199, 224 }, { 235, 177, 123 } }
function duet.render(buffer, context)
  local state = context.duet
  if not state then return buffer end
  for index, voice in ipairs(state.voices) do
    local previous
    for _, point in ipairs(voice.trail) do
      local x = 1 + math.floor(point.x * (buffer.width - 1))
      local y = 1 + math.floor(point.y * (buffer.height - 1))
      local brightness = 0.25 + 0.75 * (1 - point.age / 1.35)
      local color = point.broken and { 213, 120, 150 } or palettes[index]
      local style = { fg = { math.floor(color[1] * brightness), math.floor(color[2] * brightness), math.floor(color[3] * brightness) } }
      local char = point.broken and "·" or point.age < 0.07 and (index == 1 and "◆" or "◇") or "─"
      if previous and not point.broken and point.age >= 0.07 then
        local dx, dy = x - previous.x, y - previous.y
        char = dy == 0 and "─" or dx * dy >= 0 and "╲" or "╱"
        local steps = math.max(math.abs(dx), math.abs(dy), 1)
        for i = 1, steps - 1 do
          buffer:set(math.floor(previous.y + dy * i / steps + 0.5), math.floor(previous.x + dx * i / steps + 0.5), char, style)
        end
      end
      buffer:set(y, x, char, style)
      previous = { x = x, y = y }
    end
  end
  -- A quiet breath, not a second voice inventing tool activity while idle.
  if #state.voices[1].trail == 0 and #state.voices[2].trail == 0 then
    local x = 1 + math.floor((0.5 + math.sin(state.time * 0.6) * 0.12) * (buffer.width - 1))
    buffer:set(math.max(1, math.ceil(buffer.height / 2)), x, "·", { fg = { 57, 100, 115 }, attrs = { "dim" } })
  end
  return buffer
end
return duet
