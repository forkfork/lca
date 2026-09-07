package.path = './lua/?.lua;' .. package.path
local river = require('agent.river_divider')
local function plain(text) return text:gsub('\27%[[%d;]*m', '') end
for _, name in ipairs(river.names()) do
	for width = 1, 160 do
		for _, status in ipairs({ false, 'interrupted', 'failed' }) do
			local options = { width = width, turn = 12, seed = 'sample', design = name, status = status or nil }
			local lines = river.render(options)
			assert(#lines >= 1 and #lines <= 3)
			assert(utf8.len(lines[1]) >= 1 and utf8.len(lines[1]) <= width)
			for _, line in ipairs(lines) do
				assert(utf8.len(line) <= width)
				assert(utf8.len(line), 'invalid UTF-8')
			end
			assert(table.concat(lines, '\n') == table.concat(river.render(options), '\n'))
			options.color = true
			assert(plain(table.concat(river.render(options), '\n')) == table.concat(lines, '\n'))
			if width >= 40 then
				assert(table.concat(lines):find('turn 12', 1, true))
				if status then assert(table.concat(lines):find(status, 1, true)) end
			end
		end
	end
end
for _, line in ipairs(river.render({width = 72, ascii = true})) do
 assert(not line:find('[^ -~]'), 'ASCII fallback contains Unicode')
end
local seen = {}
for turn = 1, #river.names() do
	local _, name = river.render({ turn = turn, seed = 'session' })
	assert(not seen[name], 'design repeated within one cycle')
	seen[name] = true
end
local hostile = river.render({ seed = '\27[2J\n', width = 72 })
assert(not table.concat(hostile):find('\27', 1, true), 'seed leaked into output')
assert(not pcall(river.render, { status = 'invented success' }))
-- The cat is a static dot drawing, not phase-shifted or dependent on ANSI color.
local styles = require('agent.river_styles')
assert(seen.cat, 'cat missing from the turn divider rotation')
local cat_lines = river.render({width = 80, design = 'cat', turn = 12})
local dots = 0
for row = 0, 2 do
 for col = 0, 79 do
  local char = styles.cell('cat', col, row, 80, 0)
  assert(char == styles.cell('cat', col, row, 80, 5), 'cat moved with phase')
  local code = utf8.codepoint(char)
  assert(char == ' ' or (code >= 0x2800 and code <= 0x28ff))
  if code >= 0x2800 then dots = dots + 1 end
 end
 assert(utf8.len(cat_lines[row + 1]) == 80)
end
assert(dots > 20, 'cat sprite missing')
local traced = river.render({width = 80, design = 'cat', turn = 12,
 trace = {calls = 2, peak = 1, failed = 1, repeated = 0, unfinished = 0,
 deferred = 0, seconds = 1, events = {{status = 'failed'}, {status = 'done'}}}})
for row = 1, 3 do
 assert(traced[row]:sub(utf8.offset(traced[row], 66)) ==
  cat_lines[row]:sub(utf8.offset(cat_lines[row], 66)), 'trace obscured cat')
end
assert(#river.render({width = 32, design = 'cat', status = 'interrupted'}) == 1,
 'long status should fall back rather than obscure cat')
for _, line in ipairs(river.render({width = 80, design = 'cat', ascii = true})) do
 assert(not line:find('[^ -~]'), 'cat ASCII fallback contains Unicode')
end
print('River divider geometry, deterministic variation, labels, and color checks passed')
