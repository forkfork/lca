local Review = {}
Review.__index = Review

local choices = {
  l = "like",
  d = "dislike",
  s = "skip",
}

function Review.interpret(byte)
  if not byte then return nil end
  byte = byte:lower()
  if byte == "q" or byte == "\3" then return "quit" end
  return choices[byte]
end

function Review.new(backend, opts)
  opts = opts or {}
  local requested = opts.enabled
  if requested == nil then requested = os.getenv("LCATUI_REVIEW") == "1" end
  return setmetatable({
    backend = backend,
    enabled = requested and backend:is_tty(),
    path = opts.path or os.getenv("LCATUI_RATINGS") or "showcase-ratings.txt",
    ratings = {},
    quit = false,
  }, Review)
end

function Review:record(id, label, choice)
  self.ratings[id] = choice
  local file, err = io.open(self.path, "a")
  if not file then return nil, err end
  file:write(string.format("%s\t%s\t%s\t%s\n", os.date("!%Y-%m-%dT%H:%M:%SZ"), choice, id, label))
  file:close()
  return true
end

function Review:decorate(buffer, id)
  if not self.enabled then return buffer end
  local current = self.ratings[id]
  local prompt = current and ("REVIEW " .. id .. "  ·  recorded: " .. current .. "  ·  l/d/s change  q stop")
    or ("REVIEW " .. id .. "  ·  l like  d dislike  s skip  q stop")
  buffer:write(buffer.height, 1, string.rep(" ", buffer.width), nil, buffer.width)
  buffer:write(buffer.height, 2, prompt, { "bold", "reverse", "white" }, buffer.width - 2)
  return buffer
end

function Review:rate(renderer, buffer, id, label)
  if not self.enabled or self.quit then return not self.quit end
  while true do
    self:decorate(buffer, id)
    renderer:set_cursor(nil):draw(buffer)
    local choice = Review.interpret(self.backend:read_byte())
    if choice == "quit" then
      self.quit = true
      return false
    elseif choice then
      local ok, err = self:record(id, label, choice)
      if not ok then error("unable to save showcase rating: " .. tostring(err)) end
      return true
    end
  end
end

return Review
