-- Original acanthus scroll study, drawn at dot resolution, not glyph repetition.
-- Reference: Beham, Ornament of Satyr's Head and Wreath (1543), CMA 1922.122.
-- https://www.clevelandart.org/art/1922.122
-- The foliage vocabulary is adapted; this is not a reproduction of the print.
local engraving = {}
local pixels = {}
for y = 0, 11 do pixels[y] = {} end
local function ink(x, y)
 -- Re-rasterize the original curves into twelve dot rows, rather than crop
 -- text lines or resample finished Braille (which breaks thin stems).
 x, y = math.floor(x + 0.5), math.floor(y * 11 / 27 + 0.5)
 if pixels[y] and x >= 0 and x < 50 then pixels[y][x] = true end
end
local function curve(p, weight)
 for i = 0, 160 do
  local t, u = i / 160, 1 - i / 160
  local x = u^3*p[1] + 3*u*u*t*p[3] + 3*u*t*t*p[5] + t^3*p[7]
  local y = u^3*p[2] + 3*u*u*t*p[4] + 3*u*t*t*p[6] + t^3*p[8]
  ink(x,y)
  if weight then ink(x,y+0.7) end
 end
end
-- Individual leaves: bent midribs, scalloped edges, alternating engraved cuts.
local function leaf(x, y, tx, ty, breadth, bend)
 local dx, dy = tx-x, ty-y
 local length = math.sqrt(dx*dx+dy*dy)
 local nx, ny = -dy/length, dx/length
 for step = 0, 80 do
  local t = step/80
  local bulge = math.sin(math.pi*t)
  local cx = x + dx*t + nx*bend*bulge
  local cy = y + dy*t + ny*bend*bulge
  local radius = breadth*bulge*(0.82+0.18*math.cos(t*math.pi*7))
  for offset = -radius, radius, 0.35 do
   local edge = math.abs(offset)/math.max(0.01,radius)
   -- Pale central vein and diagonal cuts through a dark leaf silhouette.
   if edge > 0.78 or (math.abs(offset)>0.8 and (math.floor(t*24+offset*0.8)%4 ~= 0)) then
    ink(cx+nx*offset,cy+ny*offset)
   end
  end
 end
end
leaf(43,18,46,2,4.4,-3)
leaf(38,20,35,3,4.0,5)
leaf(33,22,40,27,3.1,1)
leaf(24,22,24,27,3.8,-1)
leaf(14,20,7,26,3.2,1)
leaf(9,15,0,8,3.5,-2)
leaf(12,9,7,1,3.2,2)
leaf(21,6,24,0,3.2,-1)
leaf(29,9,33,1,2.5,1)
curve({49,15,43,25,15,28,8,17},true)
curve({8,17,0,4,25,1,31,11},true)
curve({31,11,38,24,13,24,15,12},true)
curve({15,12,17,7,27,10,24,15},true)
curve({24,15,21,18,19,13,22,13})
curve({2,21,6,26,11,23,10,21})
local bits = {{1,8},{2,16},{4,32},{64,128}}
function engraving.render(width, label)
 local span = math.min(width, 88)
 local middle = math.max(15, #label+6)
 -- Match parity so the composition is reflected around a whole cell boundary.
 if (span-middle)%2 ~= 0 then span = span-1 end
 local wing = (span-middle)/2
 local margin = '' -- Keep the ornament left-aligned, including on wide terminals.
 local label_col = math.floor((span-#label)/2)
 local function dot(x,y)
  if x < wing*2 then
   return pixels[y][math.min(49,math.floor(x*50/(wing*2)))]
  elseif x >= (wing+middle)*2 then
   return pixels[y][math.min(49,math.floor((span*2-1-x)*50/(wing*2)))]
  end
  local cx = (span*2-1)/2
  local dx, dy = x-cx, y-5.5
  -- A shallow double oval: the crest and pendant become single-dot tips,
  -- leaving the middle four dot rows clear for the full-height label.
  local oval = math.sqrt((dx/(middle-1))^2+(dy/4.8)^2)
  local inner = math.sqrt((dx/(middle-3))^2+(dy/3.3)^2)
  if math.abs(oval-1)<0.09 or (math.abs(inner-1)<0.07 and math.abs(dy)>2) then return true end
  if y==0 or y==11 then return math.abs(dx)<1 end
  return false
 end
 local lines = {}
 for row = 0,2 do
  local cells = {}
  for col = 0,span-1 do
   if row == 1 and col >= label_col and col < label_col+#label then
    cells[#cells+1] = label:sub(col-label_col+1,col-label_col+1)
   elseif row == 1 and col >= label_col-1 and col <= label_col+#label then
    cells[#cells+1] = ' '
   else
    local mask = 0
    for dy=0,3 do for dx=0,1 do
     if dot(col*2+dx,row*4+dy) then mask = mask | bits[dy+1][dx+1] end
    end end
    cells[#cells+1] = mask==0 and ' ' or utf8.char(0x2800+mask)
   end
  end
  lines[#lines+1] = margin..table.concat(cells)
 end
 return lines
end
return engraving
