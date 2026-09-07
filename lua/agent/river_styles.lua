-- Character-cell compositions for the river design library.
local styles = {}
styles.designs = {
 {name='chrome', palette={{48,69,98},{138,173,202},{235,248,255}}},
 {name='fairywire', palette={{86,63,119},{181,132,194},{249,217,240}}},
 {name='acid', palette={{36,58,92},{67,187,105},{205,255,91}}},
 {name='pirate', palette={{37,44,109},{109,88,212},{241,103,185}}},
 {name='velvet', palette={{62,37,76},{167,103,140},{236,211,186}}},
 {name='petri', palette={{27,70,93},{66,188,157},{247,126,193}}},
 {name='bonsai', palette={{57,75,66},{124,161,102},{234,173,166}}},
 {name='crystal', palette={{34,52,109},{94,177,209},{223,248,255}}},
 {name='dragon', palette={{55,53,114},{206,113,131},{245,216,157}}},
 {name='cartographer', palette={{31,71,79},{76,151,143},{214,211,170}}},
 {name='glass', palette={{45,65,147},{149,69,154},{233,163,189}}},
 {name='horizon', palette={{37,35,76},{115,101,183},{189,231,249}}},
 {name='cat', palette={{64,54,79},{177,132,158},{250,211,167}}},
}
-- Original 28 x 12 dot sprite: pointed ears, sleepy eyes, paws, curled tail.
local cat = {
 '    #       #               ',
 '    ##     ##               ',
 '    # #   # #               ',
 '    #  ###  #               ',
 '   #         #       ####   ',
 '###  ##   ##  ###   #    #  ',
 '   #    #    #     #     #  ',
 '###   # # #   ###  #    #   ',
 '    ##   ###       #  #     ',
 '    #       ######## #      ',
 '    #  #  #          #      ',
 '     ################       ',
}
local glyph_cache = {}
local function pick(text, index)
 local chars = glyph_cache[text]
 if not chars then
  chars = {}
  for _, code in utf8.codes(text) do chars[#chars+1]=utf8.char(code) end
  glyph_cache[text] = chars
 end
 return chars[index % #chars + 1]
end
-- Eight virtual dots per cell give the organic studies fine edges.
local bits = {{1,8},{2,16},{4,32},{64,128}}
local function stipple(col, row, sample)
 local mask, light, count = 0, 0, 0
 for dy=0,3 do for dx=0,1 do
  local on, value = sample(col*2+dx,row*4+dy)
  if on then mask=mask | bits[dy+1][dx+1]; light=light+(value or 0.6); count=count+1 end
 end end
 return mask==0 and ' ' or utf8.char(0x2800+mask),count>0 and light/count or 0
end
function styles.cell(name, col, row, width, phase)
 local x = col / math.max(1,width-1)
 local shift = math.floor(phase*3)
 if name=='cat' then
  return stipple(col,row,function(px,py)
   local sx = px - (width * 2 - 30)
   if sx >= 0 and sx < 28 then
    return cat[py+1]:sub(sx+1,sx+1)=='#',py<4 and 0.95 or 0.75
   end
   return py==11 and px%6<2,0.25
  end)
 elseif name=='velvet' then
  local p=(col+shift)%12
  local patterns={'╭──╮╭──╮╭──╮','│╭─╯╰─╮││╭─╯','╰╯╭───╯╰╯╰──'}
  return pick(patterns[row+1],p),0.36+0.5*math.sin(col*0.12+row+phase)^2
 elseif name=='petri' then
  return stipple(col,row,function(px,py)
   local u=px*0.12+phase
   local v=py*0.47
   local field=math.sin(u+math.cos(v*1.4))+math.cos(v+math.sin(u*1.7))
   local ridge=math.abs(field)
   return ridge>0.35 and ridge<1.1,0.3+0.65*(math.sin(u*0.45+v)+1)/2
  end)
 elseif name=='bonsai' then
  local p=(col+shift)%32
  local patterns={'   ⣠⣶⣤⣀⣤⣶⣦     ⣀⣤⣄            ',
   '    ╲╱│╲╱       ╲│╱      ⠤⠒⠢⠤⠒⠢',
   '⠤⣀⣀⣠⠴┴⠦⣄⣀⠤⠒⠢⣀⣠┴⣄⣀⠤⠒⠒⠢⣀⡀     '}
  return pick(patterns[row+1],p),row==0 and (0.45+0.48*math.sin(p*0.3)^2) or row==1 and 0.35 or 0.55
 elseif name=='crystal' then
  return stipple(col,row,function(px,py)
   local p=(px+shift*2)%38
   local d=math.abs(p-19)
   local y=py-5.5
   local stem=math.abs(y)<0.6
   local branch=math.abs(math.abs(y)-d*0.7)<0.6 and d<8
   local needles=math.abs(math.abs(y)-(d-4)*0.85)<0.5 and d>4 and d<10
   return stem or branch or needles,0.45+0.5*(1-math.min(1,d/19))
  end)
 elseif name=='dragon' then
  local p=(col+shift)%24
  local patterns={'╭─╮ ╭──╮  ╭─╮╭─╮  ╭──╮  ',
   '│ ╰─╯╭─╯╭─╯ ││ ╰──╯╭─╯╭─',
   '╰────╯  ╰───╯╰─────╯  ╰─'}
  return pick(patterns[row+1],p),0.3+0.65*(col%24)/23
 elseif name=='cartographer' then
  return stipple(col,row,function(px,py)
   local u=(px+shift*2)%66-33
   local v=(py-5.5)*2.7
   local r=math.sqrt(u*u+v*v)+1.4*math.sin(u*0.18+phase)
   return (r/4.5)%1<0.27,0.35+0.5*(0.5+0.5*math.cos(r*0.12))
  end)
 elseif name=='glass' then
  local nearest,second,owner=1e9,1e9,1
  -- A repeated strip of deterministic Voronoi seeds, with dark cell seams.
  local px=(col+shift)%30
  for index=-2,8 do
   local sx=index*5+2*math.sin(index*7+phase)
   local sy=1+math.sin(index*4+phase)*1.6
   local d=((px-sx)/3)^2+(row-sy)^2
   if d<nearest then second,nearest,owner=nearest,d,index
   elseif d<second then second=d end
  end
  if second-nearest<0.45 then return ' ',0 end
  local char=nearest>2 and '▒' or nearest>0.8 and '▓' or '█'
  return char,0.2+0.75*((owner*7+shift)%11)/10
 elseif name=='horizon' then
  return stipple(col,row,function(px,py)
   local u=(px-width)/(width*0.29)
   local v=(py-5.5)/4.4
   local r=math.sqrt(u*u+v*v)
   if r<0.64 then return false end
   local ring=math.abs(r-0.85)<0.08 or math.abs(r-1.05)<0.065
   local stream=math.abs(v-0.20*math.sin(u*4+phase)/(0.5+math.abs(u)))<0.13 and math.abs(u)>0.7
   return ring or stream,ring and 0.5+0.45*(1-v)/2 or 0.5
  end)
 elseif name=='chrome' then
  local p=(col+shift)%28
  if row==1 then
   return pick('⠒⠒⠦⣄⣀⣀⣠⠴⠚⠉⠉⠓⠦⣄⣀⣠⠴⠚⠉⠉⠓⠦⣄⣀⣠⠴⠒⠒',p),0.6+0.35*math.sin(p/28*math.pi)^2
  end
  local motif = row==0 and '   ⢀⣠⠴⠋  ╱   ⢀⡴⠋⠁   ⣠⠞   ✧  '
   or ' ⠙⠦⣄   ╲  ⠈⠳⣄⡀    ⠙⠦⣄⡀   ╲  '
  return pick(motif,p),0.4+0.55*math.sin(p*0.37)^2
 elseif name=='fairywire' then
  local p=(col+shift)%20
  if row==1 then return pick('⠒⠢⡀⠀⢀⠔⠊⠉⠑⠢⡀⠀⢀⠔⠊⠉⠒⠢⠤⠔',p),0.4+0.35*math.sin(col*0.2)^2 end
  if row==0 then
   if p==4 then return '✦',0.95 elseif p==14 then return '˙',0.5 end
   if p>=7 and p<=11 then return pick('⠠⠤⠤⠤⠄',p-7),0.4 end
  else
   if p==0 then return '⋆',0.85 elseif p==10 then return '˚',0.75 end
   if p>=3 and p<=7 then return pick('⠈⠢⣀⠔⠁',p-3),0.6 end
  end
  return ' ',0
 elseif name=='acid' then
  local a=math.sin(x*18+phase+row*1.7)
  local b=math.cos(x*31-phase-row*1.9)
  local field=a+b*0.65
  if field < -0.6 then return ' ',0 end
  return pick('░▒▓█',math.min(3,math.max(0,math.floor((field+0.6)*2)))),0.35+math.min(0.65,(field+0.6)*0.38)
 elseif name=='pirate' then
  local p=(col+shift)%18
  if row==1 then
   return pick('▀▀▓▓▄▄░░▀▀▓▓▄▄░░──',p),0.45+0.45*(p/17)
  end
  local q=row==0 and p or 17-p
  if q<4 then return pick('▗▄▟█',q),0.3+q*0.17 end
  if q>=8 and q<12 then return pick('█▙▄▖',q-8),0.85-(q-8)*0.15 end
  return ' ',0
 end
end
return styles
