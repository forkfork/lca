#!/usr/bin/env lua5.5
local directory = arg[0]:match("^(.*)/[^/]+$") or "."
package.path = directory .. "/../lua/?.lua;" .. package.path
local river = require("agent.river_divider")
local color, requested_width, ascii, activity, expressive, worlds = false, nil, false, false, false, false
for _, value in ipairs(arg) do
	if value == "--color" then color = true
	elseif value == "--ascii" then ascii = true
	elseif value == "--activity" then activity = true
	elseif value == "--expressive" then expressive = true
	elseif value == "--worlds" then worlds = true
	else requested_width = assert(tonumber(value), "usage: lua5.5 scripts/river-gallery.lua [width] [--color] [--ascii] [--activity|--expressive|--worlds]") end
end
if activity then
	local Trace = require("agent.river_trace")
	local function sample(kind)
		local trace = Trace.new()
		local now = 0
		for index = 1, 8 do
			local args = { path = "file-" .. (kind == "repeated" and index % 2 or index) }
			trace:event({phase="start",name="read",call_id=tostring(index),args=args},now)
			now = now + 0.4
			if kind == "overlap" then
				trace:event({phase="start",name="read",call_id="parallel-"..index,args={path="other-"..index}},now)
			end
			now = now + 0.8
			trace:event({phase="complete",name="read",call_id=tostring(index),args=args,
				result={is_error=kind=="repeated" and (index==3 or index==5)}},now)
			if kind == "overlap" then
				now = now + 0.2
				trace:event({phase="complete",name="read",call_id="parallel-"..index,result={}},now)
			end
			now = now + 1
		end
		trace:finish(now)
		return trace:summary()
	end
	print("RIVER / TOOL ACTIVITY STUDIES\n")
	for _, scenario in ipairs({{"quiet", "SEQUENTIAL / eight calls, no failures"},
		{"overlap", "OVERLAP / pairs of tools running together"},
		{"repeated", "INVESTIGATE / two failures, repeated arguments"}}) do
		print(scenario[2] .. "\n")
		print("lca > The changes are ready to review.\n")
		local lines = river.render({width=requested_width or 96,seed="gallery",turn=12,design="moonlit",
			color=color,ascii=ascii,trace=sample(scenario[1])})
		print(table.concat(lines,"\n"))
		print("\nyou > Let's look at the next part.\n\n")
	end
	return
end
local world_names = {velvet=true,petri=true,bonsai=true,crystal=true,dragon=true,cartographer=true,glass=true,horizon=true}
local titles = { velvet="VELVET LABYRINTH / woven curves, rose and cream", petri="ALIEN PETRI DISH / cellular whorls, mint and pink",
 bonsai="BONSAI CREEK / roots, branches, peach blossoms", crystal="CRYSTAL SEAM / frost dendrites, glacial light",
 dragon="DRAGON SILK / folded paths, indigo and coral", cartographer="CARTOGRAPHER'S DREAM / contours, islands, parchment",
 glass="STAINED-GLASS STREAM / jewel cells, dark seams", horizon="EVENT HORIZON / bent currents, a dark centre", chrome="CHROME THORNS / silver sigils, ice glints", fairywire="FAIRYWIRE / pearl loops, lilac constellations",
 acid="ACID ESTUARY / fluorescent pools, stippled banks",
 pirate="PIRATE RADIO / ANSI mosaics, electric blocks", moonlit = "MOONLIT RIVER / slate, teal, pale cyan", estuary = "ESTUARY / indigo, turquoise, sand",
	phosphor = "PHOSPHOR WATER / deep green, mint", dusk = "DUSK / plum, mauve, peach" }
for _, width in ipairs(requested_width and { requested_width } or { 40, 72, 100 }) do
	print("RIVER STUDIES / " .. width .. " columns\n")
	for _, name in ipairs(river.names()) do
		if (worlds and world_names[name]) or (not worlds and (not expressive or (not world_names[name] and name ~= "moonlit" and name ~= "estuary" and name ~= "phosphor" and name ~= "dusk"))) then
		print(titles[name] .. "\n")
		print("lca > The changes are ready to review.\n")
		local lines = river.render({ width = width, seed = "gallery", turn = 12, design = name, color = color, ascii = ascii, trace = (expressive or worlds) and {calls=6,failed=1,repeated=1,unfinished=0,deferred=0,peak=2,seconds=8.4,
 events={{status="ok"},{status="ok",overlap=2},{status="failed"},{status="ok"},{status="ok",repeated=2},{status="ok"}}} or nil })
		print(table.concat(lines, "\n"))
		print("\nyou > Let's look at the next part.\n\n")
		end
	end
end
