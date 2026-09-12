-- Durable completed-turn snapshots and write-before-execute markers.
local uv=require('luv');local json=require('cjson');local shell=require('agent.util.shell')
local lifecycle=require('lifecycle');local bg=require('agent.background')
local M={}
local function digest(path)
 local p=assert(io.popen('sha256sum '..shell.quote(path)));local text=p:read('*a');assert(p:close());return assert(text:match('^(%x+)'))
end
function M.request(root,cfg,key,path,method,extra)
 assert(cfg.bucket:match('^[a-z0-9][a-z0-9-]+$') and cfg.region:match('^[a-z0-9-]+$') and cfg.prefix:match('^recovery/%w+$') and key:match('^[%w/.-]+$'),'invalid checkpoint location')
 local c,reason=lifecycle.credentials(root);if not c then error(reason) end
 local q=lifecycle.quoted
 local request='url = '..q('https://'..cfg.bucket..'.s3.'..cfg.region..'.amazonaws.com/'..cfg.prefix..'/'..key)..'\n'
 request=request..'request = '..q(method or 'PUT')..'\n'..(path and ('upload-file = '..q(path)..'\n') or '')..'aws-sigv4 = "aws:amz:'..cfg.region..':s3"\n'
 request=request..'user = '..q(c.AccessKeyId..':'..c.SecretAccessKey)..'\nheader = '..q('X-Amz-Security-Token: '..c.Token)..'\n'
 if path then request=request..'header = "x-amz-server-side-encryption: AES256"\nheader = '..q('x-amz-content-sha256: '..digest(path))..'\n' end
 request=request..(extra or '')..'fail\nwrite-out = "\\n%{http_code}"\n'
 local ok,response=lifecycle.curl(root,request,120)
 local body,status=response:match('^(.*)\n(%d%d%d)$')
 assert(ok and status and tonumber(status)>=200 and tonumber(status)<300,'checkpoint storage request failed (HTTP '..tostring(status or 'unknown')..')')
 return body
end
function M.put(root,cfg,key,path,extra) return M.request(root,cfg,key,path,'PUT',extra) end
function M.attempt(root,cfg,item)
 if not cfg then return end
 assert(item.id:match('^[%w-]+$'),'invalid input ID')
 local path=root..'/attempt.json';bg.atomic(path,{id=item.id,status='running',started_at=os.time()})
 M.put(root,cfg,'attempts/'..item.id..'.json',path)
end
function M.snapshot(root,cfg,state)
 if not cfg then return end
 assert(not lifecycle.busy_jobs(root..'/project'),'waiting for background jobs before checkpoint')
 local headers=root..'/s3-response.headers'
 local previous=json.decode(M.request(root,cfg,'latest.json',nil,'GET','dump-header = '..lifecycle.quoted(headers)..'\n'))
 local f=assert(io.open(headers));local etag=assert(f:read('*a'):lower():match('etag:%s*(.-)\r?\n'));f:close();os.remove(headers)
 local path=root..'/snapshot.tgz'
 -- Credentials and role material live outside these explicit archive members.
 assert(os.execute('tar -C '..shell.quote(root)..' -czf '..shell.quote(path)..' project state.json'),'workspace changed or archive failed')
 assert(uv.fs_stat(path).size<=(cfg.max_bytes or 200*1024*1024),'checkpoint exceeds 200 MiB compressed limit')
 local key='snapshots/'..os.time()..'-'..uv.hrtime()..'.tgz'
 M.put(root,cfg,key,path)
 local pointer=root..'/latest-checkpoint.json'
 bg.atomic(pointer,{format='workspace',key=key,previous_key=previous.key,sha256=digest(path),saved_at=os.time()})
 M.put(root,cfg,'latest.json',pointer,'header = '..lifecycle.quoted('If-Match: '..etag)..'\n')
 -- Preserve the initial baseline and the two most recent complete snapshots.
 if previous.previous_key and previous.previous_key:match('^snapshots/[%w-]+%.tgz$') then
  local ok,err=pcall(M.request,root,cfg,previous.previous_key,nil,'DELETE')
  if not ok then print('Checkpoint saved, but old snapshot cleanup failed: '..tostring(err)) end
 end
 os.remove(path)
 state.checkpoint={saved_at=os.time(),status='saved'}
end
function M.required(root,cfg,state,operation)
 if not cfg then operation();return true end
 local original=state.phase
 while true do
  local ok,err=pcall(operation)
  if ok then state.phase=original;state.checkpoint_error=nil;bg.atomic(root..'/state.json',state);return true end
  state.phase='checkpointing';state.checkpoint_error=tostring(err);bg.atomic(root..'/state.json',state)
  print('Backup not saved; further work paused: '..tostring(err))
  if uv.fs_stat(root..'/stop') then return false end
  for _=1,30 do if uv.fs_stat(root..'/stop') then return false end;uv.sleep(500) end
 end
end
return M
