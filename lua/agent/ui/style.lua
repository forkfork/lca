local ansi = require("agent.ui.ansi")

local style = {}

local function arrays_equal(left, right)
  if left == right then return true end
  if type(left) ~= "table" or type(right) ~= "table" or #left ~= #right then return false end
  for index = 1, #left do if left[index] ~= right[index] then return false end end
  return true
end

function style.equal(left, right)
  if left == right then return true end
  if type(left) ~= type(right) then return false end
  if type(left) ~= "table" then return left == right end
  local left_attrs, right_attrs = left.attrs or left, right.attrs or right
  return arrays_equal(left_attrs, right_attrs)
    and arrays_equal(left.fg, right.fg)
    and arrays_equal(left.bg, right.bg)
end

local codes = {
  reset = 0,
  bold = 1,
  dim = 2,
  italic = 3,
  underline = 4,
  reverse = 7,
  black = 30,
  red = 31,
  green = 32,
  yellow = 33,
  blue = 34,
  magenta = 35,
  cyan = 36,
  white = 37,
}

function style.sequence(value)
  if not value then return "" end
  if type(value) == "string" then value = { value } end
  local result = {}
  local attrs = value.attrs or value
  for _, name in ipairs(attrs) do
    local code = codes[name]
    if code then result[#result + 1] = tostring(code) end
  end
  if type(value.fg) == "table" then
    result[#result + 1] = string.format("38;2;%d;%d;%d", value.fg[1] or 255, value.fg[2] or 255, value.fg[3] or 255)
  end
  if type(value.bg) == "table" then
    result[#result + 1] = string.format("48;2;%d;%d;%d", value.bg[1] or 0, value.bg[2] or 0, value.bg[3] or 0)
  end
  if #result == 0 then return "" end
  return ansi.ESC .. table.concat(result, ";") .. "m"
end

function style.key(value)
  if not value then return "" end
  if type(value) == "string" then return value end
  local parts = {}
  for _, name in ipairs(value.attrs or value) do parts[#parts + 1] = tostring(name) end
  if type(value.fg) == "table" then parts[#parts + 1] = "fg:" .. table.concat(value.fg, ",") end
  if type(value.bg) == "table" then parts[#parts + 1] = "bg:" .. table.concat(value.bg, ",") end
  return table.concat(parts, ";")
end

function style.paint(text, value, enabled)
  if enabled == false or not value then return tostring(text or "") end
  local prefix = style.sequence(value)
  if prefix == "" then return tostring(text or "") end
  return prefix .. tostring(text or "") .. ansi.reset
end

return style
