-- Worker-owned idle gate. AWS logic remains outside core LCA.
local uv=require('luv')
local json=require('cjson')
local bg=require('agent.background')
local shell=require('agent.util.shell')
local M={}
function M.read(path)
 local f=io.open(path);if not f then return nil end
 local s=f:read('*a');f:close();return json.decode(s)
end
function M.pending(root,completed)
 local scan=assert(uv.fs_scandir(root..'/inbox'))
 while true do local name=uv.fs_scandir_next(scan);if not name then return false end
  if name:match('%.json$') then local item=assert(M.read(root..'/inbox/'..name));if not completed[item.id] then return true end end
 end
end
function M.busy_jobs(cwd)
 for _,job in ipairs(require('agent.jobs').list(cwd)) do
  if job.alive or job.status=='starting' then return true end
 end
 return false
end
function M.eligible(state,queued,jobs,now,last,seconds)
 return state.phase=='idle' and not state.active and not queued and not jobs and now-last>=seconds
end
function M.lock(root) return uv.fs_mkdir(root..'/control-lock',448) end
function M.unlock(root) assert(uv.fs_rmdir(root..'/control-lock')) end
function M.publish(root,source,destination)
 if not M.lock(root) then return false end
 local ok,result=pcall(function()
  local state=M.read(root..'/state.json')
  if state and state.phase=='suspending' then return false end
  assert(uv.fs_rename(source,destination))
  local fd=assert(uv.fs_open(root..'/activity','w',384));uv.fs_close(fd)
  return true
 end)
 M.unlock(root);if not ok then error(result) end;return result
end
local function curl(root,config,max_seconds)
 -- Secrets are private file data, never argv or log output.
 local path=root..'/aws-request.conf'
 local fd=assert(uv.fs_open(path,'w',384));assert(uv.fs_write(fd,config,0));assert(uv.fs_close(fd))
 local p=assert(io.popen('curl --silent --show-error --connect-timeout 3 --max-time '..tostring(max_seconds or 15)..' --config '..shell.quote(path)..' 2>/dev/null','r'))
 local result=p:read('*a');local ok=p:close();os.remove(path)
 return ok,result
end
local function quoted(s) return '"'..s:gsub('\\','\\\\'):gsub('"','\\"'):gsub('\r','\\r'):gsub('\n','\\n')..'"' end
M.curl=curl;M.quoted=quoted
function M.credentials(root)
 local metadata='http://169.254.169.254/latest/'
 local ok,token=curl(root,'noproxy = "*"\nurl = "'..metadata..'api/token"\nrequest = "PUT"\nheader = "X-aws-ec2-metadata-token-ttl-seconds: 60"\nfail\n')
 if not ok then return false,'metadata token unavailable' end
 local header='header = '..quoted('X-aws-ec2-metadata-token: '..token)..'\n'
 local creds_ok,body=curl(root,'noproxy = "*"\nurl = "'..metadata..'meta-data/iam/security-credentials/execution_role"\n'..header..'fail\n')
 if not creds_ok then return false,'execution-role credentials unavailable' end
 local c=json.decode(body)
 assert(c.AccessKeyId and c.SecretAccessKey and c.Token,'invalid execution-role credential response')
 return c
end
function M.suspend(root,cfg)
 local c,reason=M.credentials(root)
 if not c then return false,reason end
 assert(cfg.region:match('^[a-z0-9-]+$') and cfg.vm_id:match('^microvm%-%w[%w-]+$'),'invalid lifecycle configuration')
 local request='url = "https://lambda.'..cfg.region..'.amazonaws.com/2025-09-09/microvms/'..cfg.vm_id..'/suspend"\nrequest = "POST"\n'
 request=request..'aws-sigv4 = "aws:amz:'..cfg.region..':lambda"\nuser = '..quoted(c.AccessKeyId..':'..c.SecretAccessKey)..'\nheader = '..quoted('X-Amz-Security-Token: '..c.Token)..'\nwrite-out = "\\n%{http_code}"\n'
 local sent,response=curl(root,request);local status=response:match('\n(%d%d%d)$')
 if sent and status=='200' then return true end
 -- A timeout/5xx could have been accepted: stay fenced until a resume hook.
 if not sent or not status or tonumber(status)>=500 then return nil,'suspend result uncertain (HTTP '..tostring(status or 'unknown')..')' end
 return false,'suspend refused (HTTP '..status..')'
end
function M.resume_seen(root,seconds)
 local deadline=uv.hrtime()+seconds*1e9
 repeat
  if uv.fs_stat(root..'/resumed.json') then return true end
  if uv.hrtime()>=deadline then return false end
  uv.sleep(100)
 until false
end
function M.request_suspend(root,cfg,state)
 -- Give an attached client one polling interval to close shell ingress.
 if M.resume_seen(root,2) then return true end
 local uncertain=false;local reason
 for attempt=1,3 do
  if M.resume_seen(root,0) then return true end
  local accepted
  accepted,reason=M.suspend(root,cfg)
  if accepted==true then return true end
  if accepted==false and not uncertain then return false,reason end
  uncertain=true
  state.suspend_error=reason;bg.atomic(root..'/state.json',state)
  print(reason..'; gate remains closed (attempt '..attempt..'/3).')
  -- If AWS accepted before the connection failed, resume ends retries.
  if M.resume_seen(root,2) then return true end
 end
 return nil,reason
end
function M.tick(root,state,session,last,cfg)
 local activity=uv.fs_stat(root..'/activity');last=math.max(last,activity and activity.mtime.sec or 0)
 local now=os.time()
 local queued=M.pending(root,state.completed);local jobs=M.busy_jobs(session.cwd)
 if queued or jobs then return now end
 if not M.eligible(state,queued,jobs,now,last,cfg.idle_seconds) or not M.lock(root) then return last end
 local ok,err=pcall(function()
  local recent=uv.fs_stat(root..'/activity')
  if M.pending(root,state.completed) or M.busy_jobs(session.cwd) or (recent and now-recent.mtime.sec<cfg.idle_seconds) or uv.fs_stat(root..'/stop') then return end
  os.remove(root..'/resumed.json')
  state.phase='suspending';state.session=session:serialize();bg.atomic(root..'/state.json',state)
  print('Idle; suspending MicroVM.')
  local accepted,reason=M.request_suspend(root,cfg,state)
  if accepted==false then
   state.phase='idle';state.suspend_error=reason;bg.atomic(root..'/state.json',state);print(reason..'; staying awake.');return
  end
  if accepted==nil then state.suspend_error=reason;bg.atomic(root..'/state.json',state);print(reason..'; waiting for a confirmed resume.') end
  -- The resume lifecycle hook is the only authority that reopens this gate.
  while not uv.fs_stat(root..'/resumed.json') do uv.sleep(100) end
  state.phase='idle';state.suspend_error=nil;bg.atomic(root..'/state.json',state)
  print('MicroVM resumed.')
 end)
 M.unlock(root);if not ok then state.phase='failed';state.error=tostring(err);bg.atomic(root..'/state.json',state);error(err) end
 return os.time()
end
return M
