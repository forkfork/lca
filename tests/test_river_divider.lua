package.path = './lua/?.lua;' .. package.path
local river = require('agent.river_divider')
local function plain(text) return text:gsub('\27%[[%d;]*m', '') end
for _, name in ipairs(river.names()) do
	for width = 1, 160 do
		for _, status in ipairs({ false, 'interrupted', 'failed' }) do
			local options = { width = width, turn = 12, seed = 'sample', design = name, status = status or nil }
			local lines = river.render(options)
			assert(#lines >= 1 and #lines <= 5)
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
-- Only the three-line Braille fleuron remains; unsupported terminals get a rule.
assert(seen.fleuron, 'fleuron missing from rotation')
for _, name in ipairs({'ribbon', 'vine', 'colophon'}) do
 assert(not seen[name], 'removed book ornament remains in rotation')
 assert(not pcall(river.render, {design=name}), 'removed book ornament still renders')
end
for _, width in ipairs({1, 20, 32, 40, 80, 160, 500}) do
 local fallback = river.render({width=width,design='fleuron',ascii=true,turn=12})
 assert(#fallback == 1, 'ASCII fallback should be a plain rule, not old book art')
 local traced = river.render({width=width,design='fleuron',ascii=true,turn=12,
  trace={calls=2,peak=2,failed=1,repeated=1,unfinished=1,deferred=1,seconds=1.2,events={}}})
 for _, line in ipairs(traced) do
  assert(#line<=width and not line:find('[^ -~]'), 'invalid ASCII fallback or caption')
 end
 if width>=40 then assert(table.concat(traced):find('1 failed',1,true)) end
end
assert(#river.render({width=40,design='fleuron'}) == 1, 'narrow fallback retained old book art')
local engraved = river.render({width=80, design='fleuron', turn=12})
assert(#engraved == 3 and engraved[2]:find('turn 12',1,true))
-- Wider terminals must not add a centering margin to the capped ornament.
local left_aligned = river.render({width=88,design='fleuron',turn=12})
for _, width in ipairs({89, 120, 160, 500}) do
 local wide = river.render({width=width,design='fleuron',turn=12})
 for row=1,3 do assert(wide[row]==left_aligned[row], 'fleuron shifted away from the left edge') end
end
for _, width in ipairs({56, 72, 88, 120}) do
 local compact = river.render({width=width,design='fleuron',turn=12,status='interrupted'})
 assert(#compact == 3 and compact[2]:find('turn 12 / interrupted',1,true))
end
local masks, ink = {}, 0
for _, line in ipairs(engraved) do
 for _, code in utf8.codes(line) do
  if code > 0x2800 and code <= 0x28ff then masks[code]=true; ink=ink+1 end
 end
end
local variety = 0
for _ in pairs(masks) do variety=variety+1 end
assert(ink>150 and variety>30, 'engraving lost its dot contours and tonal variation')
assert(table.concat(engraved,'\n') == table.concat(river.render({width=80,design='fleuron',turn=12,seed='other'}),'\n'))
local with_trace = river.render({width=80,design='fleuron',turn=12,
 trace={calls=2,peak=1,failed=1,repeated=0,unfinished=0,deferred=0,seconds=1,events={}}})
assert(#with_trace == 4, 'engraving should use three lines plus its caption')
for row=1,3 do assert(with_trace[row]==engraved[row], 'trace damaged the engraving') end
assert(table.concat(with_trace,'\n'):find('1 failed',1,true))
print('River divider geometry, deterministic variation, labels, and color checks passed')
