local Posix = {}
Posix.__index = Posix

local function shell_success(command)
  local ok, why, code = os.execute(command)
  if type(ok) == "number" then return ok == 0 end
  return ok == true and (why ~= "exit" or code == 0)
end

function Posix.new(opts)
  opts = opts or {}
  return setmetatable({
    input = opts.input or io.stdin,
    output = opts.output or io.stdout,
    tty_path = opts.tty_path or "/dev/tty",
    saved_stty = nil,
    tty = nil,
    color = nil,
    width = nil,
    height = nil,
  }, Posix)
end

function Posix:is_tty()
  if self.tty ~= nil then return self.tty end
  self.tty = os.getenv("TERM") ~= "dumb" and shell_success("test -t 0 && test -t 1")
  return self.tty
end

function Posix:supports_color()
  if self.color == nil then self.color = self:is_tty() and os.getenv("NO_COLOR") == nil end
  return self.color
end

function Posix:refresh_size()
  local columns = tonumber(os.getenv("COLUMNS"))
  local lines = tonumber(os.getenv("LINES"))
  local handle = io.popen("stty size < /dev/tty 2>/dev/null", "r")
  if handle then
    local result = handle:read("*a")
    handle:close()
    local read_lines, read_columns = result:match("(%d+)%s+(%d+)")
    read_lines, read_columns = tonumber(read_lines), tonumber(read_columns)
    lines = read_lines and read_lines > 0 and read_lines or lines
    columns = read_columns and read_columns > 0 and read_columns or columns
  end
  columns = columns and columns > 0 and columns or 80
  lines = lines and lines > 0 and lines or 24
  self.width, self.height = columns, lines
  return self.width, self.height
end

function Posix:size()
  if not self.width then return self:refresh_size() end
  return self.width, self.height
end

function Posix:write(value)
  self.output:write(tostring(value or ""))
end

function Posix:flush()
  self.output:flush()
end

function Posix:enable_raw()
  if self.saved_stty or not self:is_tty() then return self:is_tty() end
  local handle = io.popen("stty -g < /dev/tty 2>/dev/null", "r")
  if not handle then return false, "unable to inspect terminal mode" end
  self.saved_stty = handle:read("*l")
  handle:close()
  if not self.saved_stty or self.saved_stty == "" then return false, "unable to inspect terminal mode" end
  local ok = shell_success("stty raw -echo < /dev/tty 2>/dev/null")
  if not ok then
    self.saved_stty = nil
    return false, "unable to enter raw mode"
  end
  return true
end

function Posix:disable_raw()
  if not self.saved_stty then return true end
  local safe_mode = self.saved_stty:match("^[%w:;%-]+$")
  local ok = safe_mode and shell_success("stty " .. self.saved_stty .. " < /dev/tty 2>/dev/null")
  self.saved_stty = nil
  return ok == true
end

function Posix:read_byte()
  return self.input:read(1)
end

return Posix
