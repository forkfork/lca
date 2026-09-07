package.path = "lua/?.lua;lua/?/init.lua;tests/?.lua;" .. package.path

local helper = { passed = 0, failed = 0 }

local Memory = {}
Memory.__index = Memory

function Memory.new(opts)
  opts = opts or {}
  return setmetatable({
    width = opts.width or 80,
    height = opts.height or 24,
    writes = {},
    tty = opts.tty ~= false,
    color = opts.color ~= false,
  }, Memory)
end

function Memory:size() return self.width, self.height end
function Memory:is_tty() return self.tty end
function Memory:supports_color() return self.color end
function Memory:write(value) self.writes[#self.writes + 1] = tostring(value or "") end
function Memory:flush() end
function Memory:output() return table.concat(self.writes) end
function Memory:reset() self.writes = {} end

helper.Memory = Memory

function helper.equal(actual, expected, label)
  if actual ~= expected then
    error((label or "values differ") .. "\nexpected: " .. string.format("%q", expected) .. "\nactual:   " .. string.format("%q", actual), 2)
  end
end

function helper.truthy(value, label)
  if not value then error(label or "expected truthy value", 2) end
end

function helper.test(name, callback)
  io.write("  " .. name .. " ")
  local ok, err = xpcall(callback, debug.traceback)
  if ok then
    helper.passed = helper.passed + 1
    io.write("PASS\n")
  else
    helper.failed = helper.failed + 1
    io.write("FAIL\n" .. err .. "\n")
  end
end

function helper.finish()
  io.write(string.format("\n%d passed, %d failed\n", helper.passed, helper.failed))
  if helper.failed > 0 then os.exit(1) end
end

return helper
