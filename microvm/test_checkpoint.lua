package.path='microvm/?.lua;lua/?.lua;'..package.path
local uv=require('luv');local json=require('cjson');local bg=require('agent.background');local m=require('checkpoint')
local root=os.tmpname();os.remove(root);assert(uv.fs_mkdir(root,448));assert(uv.fs_mkdir(root..'/project',448))
local state={phase='idle',completed={},session={id='test'}};bg.atomic(root..'/state.json',state)
local f=assert(io.open(root..'/project/file','w'));f:write('preserve me');f:close()
bg.atomic(root..'/credentials.json',{secret='must not enter archive'})
local objects={['latest.json']=json.encode({key='initial.tgz'})};local deleted={};local fail=false
m.request=function(_,_,key,path,method,extra)
 if method=='GET' then
  local headers=assert(io.open(root..'/s3-response.headers','w'));headers:write('HTTP/1.1 200\r\nETag: "current"\r\n');headers:close()
  return objects[key]
 elseif method=='DELETE' then deleted[#deleted+1]=key;objects[key]=nil
 else
  if key=='latest.json' then
   assert(extra:find('If-Match:',1,true),'pointer publication must be conditional')
   if fail then error('injected upload failure') end
  end
  local src=assert(io.open(path,'rb'));objects[key]=src:read('*a');src:close()
 end
 return ''
end
for _=1,3 do m.snapshot(root,{},state) end
assert(#deleted==1,'keep latest two snapshots')
local previous=objects['latest.json'];fail=true
assert(not pcall(m.snapshot,root,{},state));assert(objects['latest.json']==previous,'failed pointer publication keeps last good snapshot')
local latest=json.decode(previous);local archive=root..'/inspect.tgz';local out=assert(io.open(archive,'wb'));out:write(objects[latest.key]);out:close()
local p=assert(io.popen('tar tzf '..require('agent.util.shell').quote(archive)));local names=p:read('*a');assert(p:close())
assert(names:find('project/file',1,true) and not names:find('credentials',1,true))
local stop=assert(io.open(root..'/stop','w'));stop:close()
assert(not m.required(root,{},state,function() error('backup down') end))
assert(state.phase=='checkpointing','failure is exposed and work stays paused')
os.execute('rm -rf '..require('agent.util.shell').quote(root))
print('conditional checkpoint publication, failure pause, retention and credential exclusion passed')
