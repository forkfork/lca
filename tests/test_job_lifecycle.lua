package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path
pcall(require, 'luarocks.loader')
local jobs = require('agent.jobs')
local supervisor = require('agent.job_supervisor')
local uv = require('luv')
local shell = require('agent.util.shell')
local json = require('agent.util.json')
local root = os.tmpname(); os.remove(root); assert(uv.fs_mkdir(root, 448))
local failures = 0
local function test(name, fn)
 local ok, err = pcall(fn)
 print((ok and 'PASS ' or 'FAIL ') .. name .. (ok and '' or ': ' .. tostring(err)))
 if not ok then failures = failures + 1 end
end
local function fixture(name, status)
 local cwd = root .. '/' .. name; assert(uv.fs_mkdir(cwd, 448))
 local job = {id='job_1',cwd=cwd,store_cwd=cwd,status=status,command='true',started_at=jobs.now_iso()}
 job.stdout = jobs.job_dir(cwd,job.id) .. '/stdout.log'
 job.stderr = jobs.job_dir(cwd,job.id) .. '/stderr.log'
 assert(jobs.save(cwd,job))
 for _,path in ipairs({job.stdout,job.stderr}) do assert(io.open(path,'w')):close() end
 return job,cwd
end

test('stopped startup never executes the command', function()
 local job,cwd=fixture('stopped','starting')
 local marker=cwd .. '/executed'
 job.command='touch ' .. shell.quote(marker); assert(jobs.save(cwd,job))
 assert(jobs.stop(cwd,job.id))
 supervisor.main({cwd,job.id})
 assert(not uv.fs_stat(marker),'command ran after stop')
 assert(jobs.load(cwd,job.id).status=='stopped')
end)

test('lost supervisor does not leave an endless running wait', function()
 local job,cwd=fixture('lost','running')
 job.pid=2147483647; job.supervisor_pid=2147483647; assert(jobs.save(cwd,job))
 local result=assert(jobs.wait(cwd,job.id,{timeout_ms=0}))
 assert(result.status=='lost', 'expected lost, got ' .. result.status)
 assert(result.exit_code==nil,'must not invent exit success')
end)

test('concurrent writers preserve unique IDs and every index entry', function()
 local cwd=root .. '/concurrent'; assert(uv.fs_mkdir(cwd,448))
 local pending, errors=4,{}
 for worker=1,4 do
  local code='package.path=' .. json.string(package.path) .. ';local j=require("agent.jobs");for n=1,20 do local id=assert(j.allocate_id(' .. json.string(cwd) .. '));assert(j.save(' .. json.string(cwd) .. ',{id=id,cwd=' .. json.string(cwd) .. ',status="exited",command="true",exit_code=0})) end'
  local handle
  handle=assert(uv.spawn(uv.exepath(),{args={'-e',code},stdio={nil,nil,2}},function(code)
   if code~=0 then errors[#errors+1]=code end
   pending=pending-1; handle:close()
  end))
 end
 while pending>0 do uv.run('once') end
 assert(#errors==0,'worker failed')
 assert(#jobs.list(cwd)==80,'concurrent jobs were lost: ' .. #jobs.list(cwd))
end)

test('store lock is released after Lua errors', function()
 local cwd=root .. '/error-lock'
 local ok=pcall(jobs.with_lock,cwd,function() error('injected') end)
 assert(not ok)
 assert(jobs.with_lock(cwd,function() return true end))
end)

test('kernel releases lock when owner is killed', function()
 local cwd=root .. '/killed-lock'; assert(uv.fs_mkdir(cwd,448))
 local path=cwd .. '/lock'; local ready=cwd .. '/ready'
 local code='local lock=assert(require("agent.file_lock").acquire(' .. json.string(path) .. '));assert(io.open(' .. json.string(ready) .. ',"w")):close();require("luv").sleep(10000)'
 local done=false; local handle
 handle=assert(uv.spawn(uv.exepath(),{args={'-e',code},stdio={nil,nil,2}},function()
  done=true; handle:close()
 end))
 local deadline=uv.hrtime()+3000000000
 while not uv.fs_stat(ready) and not done and uv.hrtime()<deadline do uv.run('nowait'); uv.sleep(5) end
 local locks=require('agent.file_lock')
 local lock,err=locks.acquire(path)
 handle:kill('sigkill')
 while not done do uv.run('once') end
 if lock then lock:close() end
 assert(uv.fs_stat(ready),'worker did not acquire lock')
 assert(not lock and err=='busy','competing acquisition should block')
 local recovered=assert(locks.acquire(path)); recovered:close(); recovered:close()
end)

for _,mode in ipairs({'stop','timeout'}) do
 test(mode .. ' kills descendants even after the shell leader exits', function()
  local cwd=root .. '/tree-' .. mode; assert(uv.fs_mkdir(cwd,448))
  local pidfile=cwd .. '/child.pid'
  local child='trap "" TERM; echo $$ > ' .. shell.quote(pidfile) .. '; while :; do sleep 1; done'
  local job=assert(jobs.start({command='sh -c ' .. shell.quote(child) .. ' & wait', timeout=mode=='timeout' and 600 or nil},{cwd=cwd}))
  local deadline=uv.hrtime()+3000000000
  while not uv.fs_stat(pidfile) and uv.hrtime()<deadline do uv.sleep(5) end
  local file=io.open(pidfile); local pid=file and tonumber(file:read('*a')); if file then file:close() end
  if mode=='stop' then assert(jobs.stop(cwd,job.id)) end
  local result=assert(jobs.wait(cwd,job.id,{timeout_ms=3000}))
  local death_deadline=uv.hrtime()+300000000
  while pid and jobs.process_alive(pid) and uv.hrtime()<death_deadline do uv.sleep(5) end
  local alive=pid and jobs.process_alive(pid)
  -- Always clean up on a regression before asserting.
  if alive then uv.kill(-assert(jobs.load(cwd,job.id).pgid),'sigkill') end
  assert(pid,'child did not start')
  assert(result.status==(mode=='stop' and 'stopped' or 'timed_out'),result.status)
  assert(not alive,'TERM-resistant descendant survived')
 end)
end

test('lost supervisor with live command returns control and remains stoppable', function()
 local job,cwd=fixture('orphan','running')
 local done=false; local handle,pid
 handle,pid=uv.spawn('sleep',{args={'30'},detached=true,stdio={nil,nil,nil}},function() done=true; handle:close() end)
 assert(handle,pid)
 job.pid=pid; job.pgid=pid; job.supervisor_pid=2147483647
 job.process_start_ticks,job.boot_id=jobs.process_identity(pid)
 assert(jobs.save(cwd,job))
 local result,_,reason=jobs.wait(cwd,job.id,{timeout_ms=10000})
 assert(jobs.stop(cwd,job.id))
 while not done do uv.run('once') end
 assert(result.status=='running' and result.alive and result.supervisor_lost)
 assert(reason=='supervisor_lost','wait must not sit out deadline after supervisor loss')
end)

test('pruning never treats startup as a finished job', function()
 local job,cwd=fixture('prune-start','starting')
 job.started_at='2000-01-01T00:00:00Z'; assert(jobs.save(cwd,job))
 assert(jobs.prune(cwd,{seconds=0}).count==0)
 assert(not jobs.remove(cwd,job.id),'ordinary remove must preserve startup')
 assert(jobs.load(cwd,job.id))
end)

test('signal termination never reports exit success', function()
 local cwd=root .. '/signal'; assert(uv.fs_mkdir(cwd,448))
 local job=assert(jobs.start({command='kill -KILL $$'},{cwd=cwd}))
 local result=assert(jobs.wait(cwd,job.id,{timeout_ms=3000}))
 assert(result.status=='exited' and result.exit_code==137 and result.signal==9,
  'signal exit was reported as success: ' .. tostring(result.exit_code))
 assert(jobs.describe(result):find('signal: 9',1,true))
end)

test('concurrent fast launches preserve supervisor metadata and final state', function()
 local cwd=root .. '/fast-launch'; assert(uv.fs_mkdir(cwd,448))
 local pending,errors=2,{}
 for worker=1,2 do
  local code='package.path=' .. json.string(package.path) .. ';local j=require("agent.jobs");local cwd=' .. json.string(cwd) .. ';for n=1,6 do local job=assert(j.start({command="true"},{cwd=cwd}));local final=assert(j.wait(cwd,job.id,{timeout_ms=5000}));assert(final.status=="exited" and final.exit_code==0 and final.supervisor_pid) end'
  local handle
  handle=assert(uv.spawn(uv.exepath(),{args={'-e',code},stdio={nil,nil,2}},function(code)
   if code~=0 then errors[#errors+1]=code end
   pending=pending-1; handle:close()
  end))
 end
 while pending>0 do uv.run('once') end
 assert(#errors==0,'fast launch worker failed')
 local list=jobs.list(cwd); assert(#list==12,'launched jobs missing from index')
 for _,job in ipairs(list) do assert(job.status=='exited' and job.exit_code==0 and job.supervisor_pid) end
end)

test('stale process identity cannot signal a reused PID', function()
 local job,cwd=fixture('reused-pid','running')
 local done=false; local handle,pid
 handle,pid=uv.spawn('sleep',{args={'30'},detached=true,stdio={nil,nil,nil}},function() done=true; handle:close() end)
 assert(handle,pid)
 job.pid=pid; job.pgid=pid; job.process_start_ticks='0'
 job.boot_id=assert(io.open('/proc/sys/kernel/random/boot_id')):read('*l')
 assert(jobs.save(cwd,job))
 local result,err=jobs.stop(cwd,job.id)
 local alive=jobs.process_alive(pid)
 uv.kill(-pid,'sigkill'); while not done do uv.run('once') end
 assert(not result and err:find('identity',1,true),'stop accepted stale process identity')
 assert(alive,'unrelated process was signalled')
 assert(jobs.load(cwd,job.id).status=='running','refused stop must not claim success')
end)

test('children remain visible and stoppable after supervisor and leader disappear', function()
 local job,cwd=fixture('leader-gone','running')
 local pidfile=cwd .. '/child'; local release=cwd .. '/release'
 local child='trap "" TERM; echo $$ > ' .. shell.quote(pidfile) .. '; while :; do sleep 1; done'
 local command='sh -c ' .. shell.quote(child) .. ' & while [ ! -f ' .. shell.quote(release) .. ' ]; do sleep 0.01; done'
 local done=false; local handle,pid
 handle,pid=uv.spawn('sh',{args={'-c',command},detached=true,stdio={nil,nil,2}},function() done=true; handle:close() end)
 assert(handle,pid)
 job.pid=pid; job.pgid=pid; job.supervisor_pid=2147483647
 job.process_start_ticks,job.boot_id=jobs.process_identity(pid)
 assert(job.process_start_ticks); assert(jobs.save(cwd,job))
 local deadline=uv.hrtime()+3000000000
 while not uv.fs_stat(pidfile) and uv.hrtime()<deadline do uv.sleep(5) end
 local file=assert(io.open(pidfile)); local child_pid=tonumber(file:read('*a')); file:close()
 assert(io.open(release,'w')):close()
 while not done do uv.run('once') end
 local observed=assert(jobs.status(cwd,job.id))
 local stopped,err=jobs.stop(cwd,job.id)
 local death_deadline=uv.hrtime()+300000000
 while jobs.process_alive(child_pid) and uv.hrtime()<death_deadline do uv.sleep(5) end
 local survived=jobs.process_alive(child_pid)
 if survived then uv.kill(-pid,'sigkill') end
 assert(observed.status=='running' and observed.alive and observed.supervisor_lost,'orphan group was hidden')
 assert(stopped,err)
 assert(not survived,'orphan child escaped stop')
end)

os.execute('rm -rf ' .. shell.quote(root))
assert(failures==0,tostring(failures) .. ' lifecycle tests failed')
