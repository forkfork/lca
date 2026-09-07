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
print('River divider geometry, deterministic variation, labels, and color checks passed')
