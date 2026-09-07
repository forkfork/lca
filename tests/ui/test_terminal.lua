local h = require("tests.ui.helper")
local ansi = require("agent.ui.ansi")
local Memory = h.Memory
local Terminal = require("agent.ui.terminal")

h.test("restores terminal state when a callback fails", function()
  local backend = Memory.new()
  function backend:enable_raw() self.raw = true; return true end
  function backend:disable_raw() self.raw = false; self.restored = true; return true end
  local terminal = Terminal.new(backend)
  local ok, err = pcall(function()
    terminal:run({ raw = true }, function() error("boom") end)
  end)
  h.equal(ok, false)
  h.truthy(err:find("boom", 1, true))
  h.equal(backend.raw, false)
  h.truthy(backend.restored)
  h.truthy(backend:output():find(ansi.disable_bracketed_paste, 1, true))
  h.truthy(backend:output():find(ansi.show_cursor, 1, true))
end)

h.finish()
