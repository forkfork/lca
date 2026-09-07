local ansi = require("agent.ui.ansi")

local Terminal = {}
Terminal.__index = Terminal

function Terminal.new(backend)
  return setmetatable({ backend = backend, active = false }, Terminal)
end

function Terminal:start(opts)
  opts = opts or {}
  if self.active then return true end
  self.active = true
  if opts.raw and self.backend.enable_raw then
    local ok, err = self.backend:enable_raw()
    if not ok then self.active = false; return false, err end
  end
  self.backend:write(ansi.enable_bracketed_paste)
  self.backend:flush()
  return true
end

function Terminal:stop()
  if not self.active then return true end
  self.backend:write(ansi.disable_bracketed_paste .. ansi.reset .. ansi.show_cursor)
  self.backend:flush()
  if self.backend.disable_raw then self.backend:disable_raw() end
  self.active = false
  return true
end

function Terminal:run(opts, callback)
  local ok, err = self:start(opts)
  if not ok then return nil, err end
  local results = table.pack(xpcall(callback, debug.traceback))
  self:stop()
  if not results[1] then error(results[2], 0) end
  return table.unpack(results, 2, results.n)
end

return Terminal
