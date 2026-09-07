local width = {}

local function is_combining(cp)
  return (cp >= 0x0300 and cp <= 0x036f)
    or (cp >= 0x1ab0 and cp <= 0x1aff)
    or (cp >= 0x1dc0 and cp <= 0x1dff)
    or (cp >= 0x20d0 and cp <= 0x20ff)
    or (cp >= 0xfe00 and cp <= 0xfe0f)
    or (cp >= 0xfe20 and cp <= 0xfe2f)
end

local function is_wide(cp)
  return cp >= 0x1100 and (
    cp <= 0x115f
    or cp == 0x2329 or cp == 0x232a
    or (cp >= 0x2e80 and cp <= 0xa4cf and cp ~= 0x303f)
    or (cp >= 0xac00 and cp <= 0xd7a3)
    or (cp >= 0xf900 and cp <= 0xfaff)
    or (cp >= 0xfe10 and cp <= 0xfe19)
    or (cp >= 0xfe30 and cp <= 0xfe6f)
    or (cp >= 0xff00 and cp <= 0xff60)
    or (cp >= 0xffe0 and cp <= 0xffe6)
    or (cp >= 0x1f300 and cp <= 0x1faff)
    or (cp >= 0x20000 and cp <= 0x3fffd)
  )
end

function width.codepoint(cp)
  if cp == 0 or is_combining(cp) then return 0 end
  if cp < 32 or (cp >= 0x7f and cp < 0xa0) then return 0 end
  return is_wide(cp) and 2 or 1
end

function width.string(value)
  local result = 0
  for _, cp in utf8.codes(tostring(value or "")) do
    result = result + width.codepoint(cp)
  end
  return result
end

function width.chars(value)
  local result = {}
  for _, cp in utf8.codes(tostring(value or "")) do
    result[#result + 1] = utf8.char(cp)
  end
  return result
end

function width.truncate(value, columns)
  columns = math.max(0, tonumber(columns) or 0)
  local result, used = {}, 0
  for _, cp in utf8.codes(tostring(value or "")) do
    local char_width = width.codepoint(cp)
    if used + char_width > columns then break end
    result[#result + 1] = utf8.char(cp)
    used = used + char_width
  end
  return table.concat(result), used
end

return width
