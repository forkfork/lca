-- LCA animated logo - designed for use with luv timer
local M = {}

M.art = {
  "┃  ┌─ ┌─┐",
  "┃  │  ├─┤",
  "┗━ └─ │ │",
}

M.rows = #M.art
M.cols = 0
M.chars = {}
M.cells = {}

for r = 1, M.rows do
  M.chars[r] = {}
  for ch in M.art[r]:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    M.chars[r][#M.chars[r]+1] = ch
  end
  if #M.chars[r] > M.cols then M.cols = #M.chars[r] end
end
for r = 1, M.rows do
  while #M.chars[r] < M.cols do M.chars[r][#M.chars[r]+1] = " " end
  for c = 1, M.cols do
    if M.chars[r][c] ~= " " then
      M.cells[#M.cells+1] = {r, c, M.chars[r][c]}
    end
  end
end

M.dim = "\27[38;5;236m"
M.colors = {"\27[97;1m","\27[96;1m","\27[36m","\27[38;5;24m"}
M.hpos = 0
M.hdir = 1
M.or_ = 3
M.oc = 8

function M.render(lines_up)
  local out = {}
  for _, cell in ipairs(M.cells) do
    local r, c, ch = cell[1], cell[2], cell[3]
    local d = math.abs(c - M.hpos)
    local col = M.colors[d+1] or M.dim
    if lines_up then
      local up = lines_up - r + 1
      out[#out+1] = string.format("\27[s\27[%dA\27[%dG%s%s\27[0m\27[u", up, M.oc+c-1, col, ch)
    else
      out[#out+1] = string.format("\27[%d;%dH%s%s\27[0m", M.or_+r, M.oc+c-1, col, ch)
    end
  end
  for r = 1, M.rows do
    if M.hpos >= 1 and M.hpos <= M.cols and M.chars[r][M.hpos] == " " then
      if lines_up then
        local up = lines_up - r + 1
        out[#out+1] = string.format("\27[s\27[%dA\27[%dG\27[38;5;236m│\27[0m\27[u", up, M.oc+M.hpos-1)
      else
        out[#out+1] = string.format("\27[%d;%dH\27[38;5;236m│\27[0m", M.or_+r, M.oc+M.hpos-1)
      end
    end
    local p = M.hpos - M.hdir
    if p >= 1 and p <= M.cols and M.chars[r][p] == " " then
      if lines_up then
        local up = lines_up - r + 1
        out[#out+1] = string.format("\27[s\27[%dA\27[%dG \27[u", up, M.oc+p-1)
      else
        out[#out+1] = string.format("\27[%d;%dH ", M.or_+r, M.oc+p-1)
      end
    end
  end
  io.write(table.concat(out))
  io.flush()
  M.hpos = M.hpos + M.hdir
  if M.hpos > M.cols + 2 then M.hdir = -1 end
  if M.hpos < -2 then M.hdir = 1 end
end

function M.start(opts)
  opts = opts or {}
  M.or_ = opts.row or M.or_
  M.oc = opts.col or M.oc
  local uv = require("luv")
  io.write("\27[?25l")
  io.flush()
  M.timer = uv.new_timer()
  M.timer:start(0, 55, function() M.render() end)
end

function M.stop()
  if M.timer then
    M.timer:stop()
    M.timer:close()
    M.timer = nil
  end
  io.write("\27[?25h")
  io.flush()
end

-- standalone: run with event loop
if arg and arg[0] and arg[0]:find("lca") then
  local uv = require("luv")
  M.start()
  local quit = uv.new_timer()
  quit:start(15000, 0, function()
    M.stop()
    quit:close()
  end)
  uv.run()
end

return M
