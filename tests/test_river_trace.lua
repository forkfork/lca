package.path = './lua/?.lua;' .. package.path
local Trace = require('agent.river_trace')
local river = require('agent.river_divider')
local trace = Trace.new()
local function event(phase, id, args, time, result)
 trace:event({phase=phase, call_id=id, name='read', args=args, result=result}, time)
end
event('start','a',{path='a',offset=1},0)
event('start','b',{path='b'},1)
event('progress','a',{},2)
event('complete','a',{},3,{is_error=true,summary='missing'})
event('complete','b',{},4,{})
event('start','c',{offset=1,path='a'},7)
event('complete','c',{},9,{})
event('complete','c',{},10,{is_error=true}) -- duplicate completion cannot add failures
trace:finish(12)
local summary = trace:summary()
assert(summary.calls==3 and summary.peak==2 and summary.failed==1 and summary.repeated==1)
assert(summary.seconds==6, 'tool duration must use union of active intervals, excluding idle gaps')
assert(summary.events[3].repeated==1)
assert(summary.events[1].status=='failed', 'later success must not erase failure')
for _, width in ipairs({1,12,31,32,40,80,120}) do
 local lines = river.render({width=width,trace=summary})
 for _, line in ipairs(lines) do assert(utf8.len(line)<=width, line) end
 if width==80 then
  local text=table.concat(lines,'\n')
  assert(text:find('!',1,true) and text:find('≈',1,true))
  assert(text:find('1 failed',1,true) and text:find('1 same args',1,true))
 end
end
local unfinished = Trace.new()
unfinished:event({phase='start',name='run',args={command='test'}},1)
unfinished:finish(4); unfinished:finish(8)
assert(unfinished:summary().unfinished==1 and unfinished:summary().seconds==3)
assert(Trace.new():summary().calls==0)
print('River trace: concurrency, time union, repeats, failures, cancellation, and rendering passed')
