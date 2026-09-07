local ansi = require("agent.ui.ansi")
local style = require("agent.ui.style")

local Renderer = {}
Renderer.__index = Renderer

local function cells_equal(left, right)
  return left and right
    and left.char == right.char
    and left.continuation == right.continuation
    and style.equal(left.style, right.style)
end

local function buffers_equal(left, right)
  if not left or not right or left.width ~= right.width or left.height ~= right.height then return false end
  for row = 1, left.height do
    for col = 1, left.width do
      local a, b = left.rows[row][col], right.rows[row][col]
      if not cells_equal(a, b) then return false end
    end
  end
  return true
end

function Renderer.new(backend, opts)
  opts = opts or {}
  return setmetatable({
    backend = assert(backend, "renderer requires a backend"),
    mode = opts.mode or "inline",
    mounted = false,
    previous = nil,
    inline_height = 0,
    cursor = nil,
    synchronized = opts.synchronized ~= false,
    damage_spans = opts.damage_spans == true,
    damage_gap = math.max(0, tonumber(opts.damage_gap) or 0),
  }, Renderer)
end

function Renderer:mount(mode)
  if self.mounted then return self end
  self.mode = mode or self.mode
  self.mounted = true
  if self.mode == "fullscreen" then
    self.backend:write(ansi.enter_alt_screen .. ansi.hide_cursor .. ansi.clear_screen)
  end
  self.backend:flush()
  return self
end

function Renderer:unmount()
  if not self.mounted then return self end
  if self.mode == "fullscreen" then
    self.backend:write(ansi.reset .. ansi.show_cursor .. ansi.leave_alt_screen)
  elseif self.inline_height > 0 then
    self.backend:write("\r\n" .. ansi.reset .. ansi.show_cursor)
  else
    self.backend:write(ansi.reset .. ansi.show_cursor)
  end
  self.backend:flush()
  self.mounted, self.previous, self.inline_height = false, nil, 0
  return self
end

function Renderer:switch(mode)
  if mode == self.mode then return self end
  if self.mode == "fullscreen" then
    self.backend:write(ansi.reset .. ansi.show_cursor .. ansi.leave_alt_screen)
  elseif self.inline_height > 0 then
    self.backend:write("\r\n")
  end
  self.previous = nil
  self.inline_height = 0
  self.mode = mode
  if mode == "fullscreen" then
    self.backend:write(ansi.enter_alt_screen .. ansi.hide_cursor .. ansi.clear_screen)
  end
  self.backend:flush()
  return self
end

function Renderer:set_cursor(row, col)
  self.cursor = row and col and { row = row, col = col } or nil
  return self
end

function Renderer:_draw_inline(buffer)
  if buffers_equal(self.previous, buffer) then return end
  local out = {}
  local old_height = self.inline_height
  if self.inline_height > 0 then
    out[#out + 1] = ansi.carriage_return .. ansi.move_up(self.inline_height - 1)
  end
  local drawn_height = math.max(old_height, buffer.height)
  for row = 1, drawn_height do
    out[#out + 1] = ansi.carriage_return .. ansi.clear_line
    if row <= buffer.height then
      out[#out + 1] = buffer:styled_line(row, self.backend:supports_color())
    end
    if row < drawn_height then out[#out + 1] = "\r\n" end
  end
  if drawn_height > buffer.height then
    out[#out + 1] = ansi.move_up(drawn_height - buffer.height)
  end
  if self.cursor then
    out[#out + 1] = ansi.carriage_return
    out[#out + 1] = ansi.move_up(buffer.height - self.cursor.row)
    out[#out + 1] = ansi.move_right(math.max(0, self.cursor.col - 1))
    out[#out + 1] = ansi.show_cursor
  end
  self.backend:write(table.concat(out))
  self.inline_height = buffer.height
end

function Renderer:_draw_fullscreen(buffer)
  local out = { ansi.hide_cursor }
  local active_style = nil
  local color_enabled = self.backend:supports_color()
  local function append_cells(row, first, last)
    out[#out + 1] = ansi.position(row, first)
    for col = first, last do
      local item = buffer.rows[row][col]
      if not item.continuation then
        local key = color_enabled ~= false and style.key(item.style) or ""
        if key ~= active_style then
          if active_style and active_style ~= "" then out[#out + 1] = ansi.reset end
          if color_enabled ~= false and item.style then out[#out + 1] = style.sequence(item.style) end
          active_style = key
        end
        out[#out + 1] = item.char
      end
    end
  end
  for row = 1, buffer.height do
    if self.damage_spans and self.previous then
      local previous_row = self.previous.rows[row]
      local first = nil
      local last = nil
      for col = 1, buffer.width do
        if not cells_equal(previous_row[col], buffer.rows[row][col]) then
          if not first then first = col end
          last = col
        elseif first and col - last > self.damage_gap then
          append_cells(row, first, last)
          first = nil
          last = nil
        end
      end
      if first then append_cells(row, first, last) end
    else
      local dirty = not self.previous or self.previous:plain_line(row) ~= buffer:plain_line(row)
        or self.previous:styled_line(row, true) ~= buffer:styled_line(row, true)
      if dirty then
        out[#out + 1] = ansi.position(row, 1) .. ansi.clear_line
        out[#out + 1] = buffer:styled_line(row, self.backend:supports_color())
      end
    end
  end
  if active_style and active_style ~= "" then out[#out + 1] = ansi.reset end
  if self.cursor then
    out[#out + 1] = ansi.position(self.cursor.row, self.cursor.col) .. ansi.show_cursor
  end
  self.backend:write(table.concat(out))
end

function Renderer:draw(buffer)
  if not self.mounted then self:mount() end
  local damage_mode = self.mode == "fullscreen" and self.damage_spans and self.previous ~= nil
  if not damage_mode and buffers_equal(self.previous, buffer) then return self end
  if self.synchronized then self.backend:write(ansi.begin_synchronized_update) end
  if self.mode == "fullscreen" then self:_draw_fullscreen(buffer) else self:_draw_inline(buffer) end
  if self.synchronized then self.backend:write(ansi.end_synchronized_update) end
  self.backend:flush()
  self.previous = buffer
  return self
end

function Renderer:commit(lines)
  lines = type(lines) == "table" and lines or { tostring(lines or "") }
  if self.mode == "fullscreen" then return false, "commit is only available in inline mode" end
  local out = {}
  if self.inline_height > 0 then
    out[#out + 1] = ansi.carriage_return .. ansi.move_up(self.inline_height - 1)
    for row = 1, self.inline_height do
      out[#out + 1] = ansi.carriage_return .. ansi.clear_line
      if row < self.inline_height then out[#out + 1] = "\r\n" end
    end
    out[#out + 1] = ansi.carriage_return .. ansi.move_up(self.inline_height - 1)
  end
  for _, line in ipairs(lines) do out[#out + 1] = tostring(line) .. "\r\n" end
  self.backend:write(table.concat(out))
  self.previous = nil
  self.inline_height = 0
  self.backend:flush()
  return true
end

return Renderer
