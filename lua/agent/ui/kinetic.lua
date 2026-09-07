local width = require("agent.ui.width")

local kinetic = {}

local families = {
  horizontal = { "·", "‐", "─", "━" },
  vertical = { "·", "╎", "│", "┃" },
  round = { "·", "°", "○", "◉" },
  angle = { "·", "‹", "⌁", "◆" },
  dense = { "·", "░", "▒", "▓" },
  soft = { "·", "˙", "•", "◦" },
}

local unicode_family = {
  ["─"] = "horizontal", ["━"] = "horizontal", ["═"] = "horizontal",
  ["│"] = "vertical", ["┃"] = "vertical", ["║"] = "vertical",
  ["○"] = "round", ["●"] = "round", ["◉"] = "round",
  ["◆"] = "angle", ["◇"] = "angle", ["⌁"] = "angle",
  ["█"] = "dense", ["▓"] = "dense", ["▒"] = "dense", ["░"] = "dense",
}

local function hash(value)
  local x = math.sin(value * 12.9898 + 78.233) * 43758.5453
  return x - math.floor(x)
end

function kinetic.ease(value)
  value = math.max(0, math.min(1, value))
  return value * value * (3 - 2 * value)
end

function kinetic.family(char)
  if unicode_family[char] then return unicode_family[char] end
  if char:match("[%-_=~]") then return "horizontal" end
  if char:match("[|ilI1!]") then return "vertical" end
  if char:match("[oO0QCG@]") then return "round" end
  if char:match("[/%\\<>%^vVxX]") then return "angle" end
  if char:match("[#MWN8%%&]") then return "dense" end
  return "soft"
end

function kinetic.material(char, amount)
  if amount >= 1 then return char end
  if char == " " then return " " end
  local set = families[kinetic.family(char)]
  local index = math.max(1, math.min(#set, math.floor(amount * #set) + 1))
  return set[index]
end

function kinetic.scatter(text, target_row, target_col, bounds, seed)
  local entities, cursor = {}, target_col
  bounds = bounds or { width = 80, height = 24 }
  seed = seed or 1
  for index, char in ipairs(width.chars(text)) do
    local char_width = width.string(char)
    if char ~= " " then
      entities[#entities + 1] = {
        char = char,
        target_row = target_row,
        target_col = cursor,
        source_row = 2 + math.floor(hash(seed * 101 + index * 17) * math.max(1, bounds.height - 3)),
        source_col = 1 + math.floor(hash(seed * 211 + index * 29) * math.max(1, bounds.width - 1)),
        delay = hash(seed * 307 + index * 43) * 0.38,
      }
    end
    cursor = cursor + char_width
  end
  return entities
end

function kinetic.draw(buffer, entities, progress, opts)
  opts = opts or {}
  local reverse = opts.reverse == true
  for index, entity in ipairs(entities) do
    local local_progress = kinetic.ease(math.max(0, math.min(1, (progress - entity.delay) / (1 - entity.delay))))
    if reverse then local_progress = 1 - local_progress end
    local row = math.floor(entity.source_row + (entity.target_row - entity.source_row) * local_progress + 0.5)
    local col = math.floor(entity.source_col + (entity.target_col - entity.source_col) * local_progress + 0.5)
    local glyph = kinetic.material(entity.char, local_progress)
    local cell_style = type(opts.style) == "function" and opts.style(entity, local_progress, index) or opts.style
    buffer:set(row, col, glyph, cell_style)
  end
  return buffer
end

return kinetic
