local effects = {}

local NAMES = { "drift", "mycelium", "cytoplasm", "ink", "filament", "contours" }
local NATIVE = { drift = true, filament = true, contours = true }
local KNOWN = {}
for _, name in ipairs(NAMES) do KNOWN[name] = true end

local function clamp(value, low, high)
	return math.max(low, math.min(high, value))
end

local function rgb(r, g, b, attrs)
	return { fg = { r, g, b }, attrs = attrs or {} }
end

local function hash(value)
	value = tostring(value or "")
	local result = 23
	for index = 1, #value do result = (result * 37 + value:byte(index)) % 104729 end
	return result
end

local function actor_style(scene, actor, quiet)
	if actor and actor.failed or scene.failed then return rgb(226, 69, 106, quiet and { "dim" } or { "bold" }) end
	if actor and actor.resolved or scene.proof and scene.proof > 0 then return rgb(76, 211, 162, quiet and { "dim" } or { "bold" }) end
	if scene.listening then return rgb(52, 137, 145, { "dim" }) end
	return rgb(112, 102, 190, quiet and { "dim" } or {})
end

local function plot_line(buffer, x1, y1, x2, y2, glyph, style, phase)
	local dx, dy = x2 - x1, y2 - y1
	local steps = math.max(1, math.abs(dx), math.abs(dy) * 3)
	for step = 0, steps do
		local fraction = step / steps
		local x = clamp(math.floor(x1 + dx * fraction + 0.5), 1, buffer.width)
		local y = clamp(math.floor(y1 + dy * fraction + 0.5), 1, buffer.height)
		if not phase or (step + phase) % 3 ~= 0 then buffer:set(y, x, glyph, style) end
	end
end

local function render_mycelium(buffer, context)
	local scene, time = context.scene, context.time
	local actors = scene.vortices or {}
	local root_x = math.floor(buffer.width * (0.46 + math.sin(time * 0.31) * 0.035))
	local root_y = clamp(math.floor((buffer.height + 1) / 2 + 0.5), 1, buffer.height)
	local quiet = actor_style(scene, nil, true)

	-- A persistent, breathing root system remains visible while listening.
	for branch = 1, math.max(5, math.floor(buffer.width / 24)) do
		local seed = hash("root-" .. branch)
		local reach = 8 + seed % math.max(9, math.floor(buffer.width / 5))
		local direction = branch % 2 == 0 and 1 or -1
		local tip_x = clamp(root_x + direction * reach, 1, buffer.width)
		local tip_y = clamp(root_y + (seed % buffer.height) - math.floor(buffer.height / 2), 1, buffer.height)
		plot_line(buffer, root_x, root_y, tip_x, tip_y, "·", quiet, branch + math.floor(time * 2))
		if (branch + math.floor(time * 3)) % 3 == 0 then buffer:set(tip_y, tip_x, "⠂", quiet) end
	end

	for index, actor in ipairs(actors) do
		local ax = clamp(math.floor(actor.x or (hash(actor.id) % buffer.width + 1)), 1, buffer.width)
		local ay = clamp(math.floor(actor.y or (hash(actor.id .. "y") % buffer.height + 1)), 1, buffer.height)
		local bend_x = math.floor((root_x + ax) / 2)
		local bend_y = clamp(root_y + ((hash(actor.id) % 3) - 1), 1, buffer.height)
		local style = actor_style(scene, actor, true)
		plot_line(buffer, root_x, root_y, bend_x, bend_y, actor.failed and "╳" or "╌", style, index)
		plot_line(buffer, bend_x, bend_y, ax, ay, actor.failed and "╱" or "·", style, index + 1)
		local travel = (time * (actor.resolved and 7 or 4) + hash(actor.id) * 0.01) % 1
		local px = math.floor(root_x + (ax - root_x) * travel + 0.5)
		local py = math.floor(root_y + (ay - root_y) * travel + 0.5)
		buffer:set(clamp(py, 1, buffer.height), clamp(px, 1, buffer.width), actor.failed and "×" or actor.resolved and "◆" or "◇", actor_style(scene, actor, false))
		buffer:set(ay, ax, actor.failed and "╳" or actor.resolved and "✦" or "◉", actor_style(scene, actor, false))
	end

	buffer:set(root_y, root_x, scene.failed and "╳" or scene.proof and scene.proof > 0 and "✦" or "◆", actor_style(scene, nil, false))
end

local function render_cytoplasm(buffer, context)
	local scene, time = context.scene, context.time
	local actors = scene.vortices or {}
	local centres = {}
	for _, actor in ipairs(actors) do
		centres[#centres + 1] = {
			x = clamp(actor.x or buffer.width * 0.5, 1, buffer.width),
			y = clamp(actor.y or (buffer.height + 1) / 2, 1, buffer.height),
			r = actor.radius and clamp(actor.radius, 5, 11) or 7,
			actor = actor,
		}
	end
	if #centres == 0 then
		centres[1] = {
			x = buffer.width * (0.5 + math.sin(time * 0.37) * 0.18),
			y = (buffer.height + 1) / 2 + math.sin(time * 0.71) * 0.55,
			r = scene.listening and 8 or 11,
			actor = {},
		}
	end

	local glyphs = { "·", "⠁", "⠂", "⠄", "⡀", "⠐" }
	for y = 1, buffer.height do
		for x = 1, buffer.width do
			local field, nearest = 0, centres[1]
			local nearest_distance = math.huge
			for _, centre in ipairs(centres) do
				local dx, dy = x - centre.x, (y - centre.y) * 3.2
				local distance2 = dx * dx + dy * dy
				field = field + centre.r * centre.r / (distance2 + centre.r * centre.r)
				if distance2 < nearest_distance then nearest, nearest_distance = centre, distance2 end
			end
			local membrane = field + math.sin(x * 0.17 + y * 1.9 - time * 1.4) * 0.045
			if membrane > 0.42 and membrane < 0.73 then
				local glyph = membrane > 0.58 and "⠤" or glyphs[(x + y * 3 + math.floor(time * 5)) % #glyphs + 1]
				buffer:set(y, x, glyph, actor_style(scene, nearest.actor, membrane < 0.58))
			end
		end
	end
	for _, centre in ipairs(centres) do
		local x, y = clamp(math.floor(centre.x + 0.5), 1, buffer.width), clamp(math.floor(centre.y + 0.5), 1, buffer.height)
		local actor = centre.actor
		buffer:set(y, x, actor.failed and "×" or actor.resolved and "◆" or "●", actor_style(scene, actor, false))
	end
end

local function render_ink(buffer, context)
	local scene, time = context.scene, context.time
	local actors = scene.vortices or {}
	local density = scene.listening and 7 or 11
	for ribbon = 1, density do
		local seed = hash("ink-" .. ribbon)
		local direction = ribbon % 3 == 0 and -1 or 1
		local speed = scene.failed and 16 or scene.listening and 4.5 or 9
		local head = (seed + direction * time * speed) % (buffer.width + 28) - 14
		for tail = 0, 18 do
			local x = math.floor(head - direction * tail + 0.5)
			if x >= 1 and x <= buffer.width and (tail + ribbon) % 3 ~= 1 then
				local wave = math.sin(x * 0.09 + seed * 0.013 - time * 1.7) + math.sin(x * 0.027 + ribbon)
				local y = clamp(math.floor((buffer.height + 1) / 2 + wave * buffer.height * 0.22 + 0.5), 1, buffer.height)
				local glyph = tail < 3 and "⠿" or tail < 9 and "⠤" or ({ "⠁", "⠂", "·" })[tail % 3 + 1]
				buffer:set(y, x, glyph, actor_style(scene, nil, tail > 5))
			end
		end
	end
	for _, actor in ipairs(actors) do
		local ax = clamp(math.floor(actor.x or buffer.width / 2), 1, buffer.width)
		local ay = clamp(math.floor(actor.y or buffer.height / 2), 1, buffer.height)
		for drop = 1, 6 do
			local distance = drop + math.floor((time * 5 + hash(actor.id)) % 5)
			local x = clamp(ax - distance, 1, buffer.width)
			local y = clamp(ay + ((drop + hash(actor.id)) % 3) - 1, 1, buffer.height)
			buffer:set(y, x, actor.failed and "╳" or actor.resolved and "✦" or "⠶", actor_style(scene, actor, drop > 2))
		end
	end
end

function effects.names()
	local result = {}
	for index, name in ipairs(NAMES) do result[index] = name end
	return result
end

function effects.known(name) return KNOWN[name] == true end
function effects.native(name) return NATIVE[name] == true end

function effects.render(name, buffer, context)
	if NATIVE[name] then
		context.flow:set_mode(name)
		return context.flow:render(buffer, context.scene)
	end
	if name == "mycelium" then render_mycelium(buffer, context)
	elseif name == "cytoplasm" then render_cytoplasm(buffer, context)
	elseif name == "ink" then render_ink(buffer, context)
	else error("unknown TUI effect: " .. tostring(name)) end
	return buffer
end

return effects
