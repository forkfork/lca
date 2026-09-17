package.path='./lua/?.lua;./lua/?/init.lua;' .. package.path
local jobs=require('agent.jobs')
local uv=require('luv')
local json=require('agent.util.json')
local shell=require('agent.util.shell')
local stop=require('agent.tools.job_stop')
local root=os.tmpname(); os.remove(root); assert(uv.fs_mkdir(root,448))
local function test(name,fn) local ok,err=pcall(fn); if not ok then error(name .. ': ' .. tostring(err)) end; print('PASS '..name) end
local function child(code)
 local full='package.path=' .. json.string(package.path) .. ';' .. code
 assert(os.execute(shell.quote(uv.exepath()) .. ' -e ' .. shell.quote(full)))
end
local function file(path) local f=assert(io.open(path,'rb'));local s=f:read('*a');f:close();return s end

test('fresh process discovers waits and stops jobs after launcher exit',function()
 local cwd=root .. '/restart';assert(uv.fs_mkdir(cwd,448))
 child('local j=require("agent.jobs");local c='..json.string(cwd)..';assert(j.start({command="printf before; sleep 1; printf after"},{cwd=c}));assert(j.start({command="sleep 30"},{cwd=c}))')
 child('local j=require("agent.jobs");local c='..json.string(cwd)..';assert(#j.list(c)==2);local done=assert(j.wait(c,"job_1",{timeout_ms=5000}));assert(done.status=="exited" and done.exit_code==0);assert(j.output(c,"job_1",{offset=0})=="beforeafter");assert(j.stop(c,"job_2").status=="stopped")')
 assert(jobs.load(cwd,'job_1').exit_code==0)
 assert(jobs.load(cwd,'job_2').status=='stopped')
end)

test('overlapping jobs reconstruct both large streams byte for byte',function()
 local cwd=root .. '/streams';assert(uv.fs_mkdir(cwd,448))
 local expected={}
 for n=1,2 do
  local out='OUT'..n..':'..string.rep('abcdefghij',13000)..'END-OUT'
  local err='ERR'..n..':'..string.rep('9876543210',9000)..'END-ERR'
  expected[n]={stdout=out,stderr=err}
  local code='import sys,time;sys.stdout.write("OUT'..n..':"+"abcdefghij"*13000+"END-OUT");sys.stdout.flush();time.sleep(0.2);sys.stderr.write("ERR'..n..':"+"9876543210"*9000+"END-ERR");sys.exit('..(n-1)..')'
  assert(jobs.start({command='python3 -c '..shell.quote(code)},{cwd=cwd}))
 end
 for n=1,2 do
  local job=assert(jobs.wait(cwd,'job_'..n,{timeout_ms=5000}))
  assert(job.status=='exited' and job.exit_code==n-1)
  for _,stream in ipairs({'stdout','stderr'}) do
   local offset,parts=0,{}
   repeat
    local text,err,next_offset,more=jobs.output(cwd,job.id,{stream=stream,offset=offset,limit=997})
    assert(text,err);assert(next_offset==offset+#text);offset=next_offset;parts[#parts+1]=text
    if not more then break end
   until false
   assert(table.concat(parts)==expected[n][stream],'missing, duplicate or cross-job bytes')
   local empty,_,next_offset,more=jobs.output(cwd,job.id,{stream=stream,offset=offset})
   assert(empty=='' and next_offset==offset and not more)
  end
 end
end)

test('live streams preserve partial lines and independent cursors across empty polls',function()
 local cwd=root .. '/live';assert(uv.fs_mkdir(cwd,448))
 local code=[[
import os,time
from pathlib import Path
for n,(out,err) in enumerate([(b'partial',b'error:'),(b' line\nnext',b' detail\n'),(b'\nfinal',b'last')],1):
 os.write(1,out);os.write(2,err)
 Path('ready'+str(n)).touch()
 deadline=time.monotonic()+10
 while not Path('release'+str(n)).exists():
  if time.monotonic()>deadline:raise RuntimeError('test release timed out')
  time.sleep(.005)
]]
 local job=assert(jobs.start({command='python3 -c '..shell.quote(code)},{cwd=cwd}))
 local offsets={stdout=0,stderr=0};local bodies={stdout='',stderr=''}
 local expected={{stdout='partial',stderr='error:'},{stdout='partial line\nnext',stderr='error: detail\n'},{stdout='partial line\nnext\nfinal',stderr='error: detail\nlast'}}
 for n=1,3 do
  local deadline=uv.hrtime()+5000000000
  while not uv.fs_stat(cwd..'/ready'..n) and uv.hrtime()<deadline do uv.sleep(5) end
  assert(uv.fs_stat(cwd..'/ready'..n),'writer failed to reach stage '..n)
  assert(jobs.status(cwd,job.id).status=='running')
  for _,stream in ipairs({'stderr','stdout'}) do
   repeat
    local body,err,next_offset,more=jobs.output(cwd,job.id,{stream=stream,offset=offsets[stream],limit=3})
    assert(body,err);assert(next_offset==offsets[stream]+#body)
    offsets[stream]=next_offset;bodies[stream]=bodies[stream]..body
    if not more then break end
   until false
   assert(bodies[stream]==expected[n][stream],'live cursor lost or duplicated bytes')
   for _=1,2 do
    local body,err,next_offset,more=jobs.output(cwd,job.id,{stream=stream,offset=offsets[stream],limit=3})
    assert(body,err);assert(body=='' and next_offset==offsets[stream] and not more)
   end
  end
  local response=require('agent.tools.job_wait').execute({id=job.id,timeout_ms=0,stdout_offset=offsets.stdout,stderr_offset=offsets.stderr},{cwd=cwd})
  assert(not response.is_error and response.content:find('wait_reason: deadline',1,true))
  assert(response.content:find('stdout_offset: '..offsets.stdout,1,true))
  assert(response.content:find('stderr_offset: '..offsets.stderr,1,true))
  local f=assert(io.open(cwd..'/release'..n,'w'));f:close()
 end
 assert(jobs.wait(cwd,job.id,{timeout_ms=5000}).exit_code==0)
end)

test('cursor beyond current output fails instead of silently skipping future bytes',function()
 local cwd=root .. '/invalid-cursor';assert(uv.fs_mkdir(cwd,448))
 local job=assert(jobs.start({command='printf abc'},{cwd=cwd}))
 assert(jobs.wait(cwd,job.id,{timeout_ms=5000}).exit_code==0)
 local body,err=jobs.output(cwd,job.id,{offset=4})
 assert(body==nil and err:find('exceeds current output size',1,true),'invalid cursor silently accepted')
 assert(jobs.output(cwd,job.id,{offset=3})=='','exact EOF must remain valid')
 for _,case in ipairs({
  {'job_output',{id=job.id,offset=4}},
  {'job_wait',{id=job.id,timeout_ms=0,stderr_offset=1}},
 }) do
  local result=require('agent.tools.'..case[1]).execute(case[2],{cwd=cwd})
  assert(result.is_error and result.content:find('exceeds current output size',1,true))
  assert(result.content:find('offset 0 to reread',1,true),'missing cursor recovery instruction')
 end
 assert(jobs.output(cwd,job.id,{offset=0})=='abc','recovery must preserve the log')
end)

test('legacy jobs remain inspectable and refused stops explain recovery',function()
 local cwd=root .. '/legacy';assert(uv.fs_mkdir(cwd,448))
 local job=assert(jobs.start({command='printf legacy-output; sleep 30'},{cwd=cwd}))
 local deadline=uv.hrtime()+3000000000
 repeat job=assert(jobs.status(cwd,job.id));if job.status=='running' then break end;uv.sleep(5) until uv.hrtime()>deadline
 assert(job.status=='running')
 local original=jobs.load(cwd,job.id)
 local legacy={};for k,v in pairs(original) do legacy[k]=v end
 legacy.boot_id=nil;legacy.process_start_ticks=nil;legacy.supervisor_start_ticks=nil
 assert(jobs.save(cwd,legacy))
 local response=stop.execute({id=job.id},{cwd=cwd})
 local alive=jobs.group_alive(original)
 assert(jobs.save(cwd,original));assert(jobs.stop(cwd,job.id))
 assert(alive,'legacy stop signalled an unverified process')
 assert(response.is_error and response.summary=='stop failed')
 assert(response.content:find('ps -o pid,pgid,lstart,args',1,true),'missing actionable recovery instruction')
 assert(file(original.stdout)=='legacy-output')
end)

os.execute('rm -rf '..shell.quote(root))
