local style = require("agent.ui.style")
local text_width = require("agent.ui.width")
local ansi = require("agent.ui.ansi")

local Buffer = {}
Buffer.__index = Buffer

local function cell(char, cell_style, continuation)
  return { char = char or " ", style = cell_style, continuation = continuation == true }
end

function Buffer.new(width, height)
  local self = setmetatable({ width = width, height = height, rows = {} }, Buffer)
  self:clear()
  return self
end

function Buffer:clear()
  self.rows = {}
  for row = 1, self.height do
    self.rows[row] = {}
    for col = 1, self.width do
      self.rows[row][col] = cell()
    end
  end
  return self
end

function Buffer:set(row, col, char, cell_style)
  if row < 1 or row > self.height or col < 1 or col > self.width then return self end
  local char_width = text_width.string(char)
  if char_width == 0 then
    if col > 1 then self.rows[row][col - 1].char = self.rows[row][col - 1].char .. char end
    return self
  end
  if char_width == 2 and col == self.width then return self end
  -- Cell references are live, as with fill(); clear() starts a new cell grid.
  local item = self.rows[row][col]
  item.char, item.style, item.continuation = char or " ", cell_style, false
  if char_width == 2 then
    item = self.rows[row][col + 1]
    item.char, item.style, item.continuation = "", cell_style, true
  end
  return self
end

function Buffer:fill(first_row, first_col, last_row, last_col, char, cell_style)
  first_row, first_col = math.max(1, first_row), math.max(1, first_col)
  last_row, last_col = math.min(self.height, last_row), math.min(self.width, last_col)
  char = char or " "
  for row = first_row, last_row do
    for col = first_col, last_col do
      local item = self.rows[row][col]
      item.char, item.style, item.continuation = char, cell_style, false
    end
  end
  return self
end

function Buffer:write(row, col, text, cell_style, max_width)
  local cursor = col
  local limit = math.min(self.width, col + (max_width or self.width) - 1)
  for _, cp in utf8.codes(tostring(text or "")) do
    local char = utf8.char(cp)
    local char_width = text_width.codepoint(cp)
    if char_width == 0 then
      self:set(row, cursor, char, cell_style)
    elseif cursor + char_width - 1 <= limit then
      self:set(row, cursor, char, cell_style)
      cursor = cursor + char_width
    else
      break
    end
  end
  return self
end

function Buffer:plain_line(row)
  local result = {}
  for col = 1, self.width do
    local item = self.rows[row][col]
    if not item.continuation then result[#result + 1] = item.char end
  end
  return table.concat(result):gsub("%s+$", "")
end

function Buffer:styled_line(row, color_enabled)
  local result, active, previous_style, previous_key = {}, nil, nil, nil
  for col = 1, self.width do
    local item = self.rows[row][col]
    if not item.continuation then
      -- Styles are mutable: reuse keys only within this serialization call.
      local key
      if previous_key ~= nil and item.style == previous_style then key = previous_key
      else key = style.key(item.style); previous_style, previous_key = item.style, key end
      if key ~= active then
        if active then result[#result + 1] = ansi.reset end
        if item.style then result[#result + 1] = style.sequence(item.style) end
        active = key
      end
      result[#result + 1] = item.char
    end
  end
  if active then result[#result + 1] = ansi.reset end
  local value = table.concat(result):gsub("%s+$", "")
  if color_enabled == false then
    value = value:gsub("\27%[[%d;]*m", "")
  end
  return value
end

return Buffer
