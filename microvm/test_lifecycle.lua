package.path='microvm/?.lua;lua/?.lua;'..package.path
pcall(require,'luarocks.loader')
local m=require('lifecycle');local uv=require('luv');local bg=require('agent.background')
local state={phase='idle',completed={}}
assert(m.eligible(state,false,false,300,0,300))
assert(not m.eligible(state,false,false,299,0,300))
assert(not m.eligible(state,true,false,300,0,300))
assert(not m.eligible(state,false,true,300,0,300))
state.phase='running';assert(not m.eligible(state,false,false,900,0,300))
state.phase='idle';state.active='model-wait';assert(not m.eligible(state,false,false,900,0,300));state.active=nil
local root=os.tmpname();os.remove(root);assert(uv.fs_mkdir(root,448));assert(uv.fs_mkdir(root..'/inbox',448))
bg.atomic(root..'/input',{id='one',text='work'});bg.atomic(root..'/state.json',state)
assert(m.lock(root));assert(not m.publish(root,root..'/input',root..'/inbox/one.json'));m.unlock(root)
state.phase='suspending';bg.atomic(root..'/state.json',state)
assert(not m.publish(root,root..'/input',root..'/inbox/one.json'))
state.phase='idle';bg.atomic(root..'/state.json',state)
assert(m.publish(root,root..'/input',root..'/inbox/one.json'));assert(m.pending(root,{}));assert(not m.pending(root,{one=true}))
os.execute('rm -rf '..require('agent.util.shell').quote(root))
print('idle eligibility and submission/suspension gate passed')
-- Real file protocol with a fake AWS request/resume, including concurrent submit.
local root2=os.tmpname();os.remove(root2);assert(uv.fs_mkdir(root2,448));assert(uv.fs_mkdir(root2..'/inbox',448))
local state2={phase='idle',completed={}}
local session={cwd=root2,serialize=function() return {id='same'} end}
local calls=0;m.busy_jobs=function() return false end
m.suspend=function(root)
 calls=calls+1
 bg.atomic(root..'/new-input',{id='late',text='late arrival'})
 assert(not m.publish(root,root..'/new-input',root..'/inbox/late.json'))
 bg.atomic(root..'/resumed.json',{time=os.time()})
 return true
end
m.tick(root2,state2,session,os.time()-10,{idle_seconds=1})
assert(calls==1 and state2.phase=='idle' and not uv.fs_stat(root2..'/control-lock'))
assert(m.publish(root2,root2..'/new-input',root2..'/inbox/late.json'))
m.tick(root2,state2,session,os.time()-10,{idle_seconds=1});assert(calls==1)
os.execute('rm -rf '..require('agent.util.shell').quote(root2))
print('submission racing suspension waits until resume; queued input stays awake')
local output={};local ui=require('headless').ui(function(s) output[#output+1]=s end)
local real_session=require('agent.session').create({model='gpt-6-astra'});real_session.cwd='/workspace'
require('agent.commands').dispatch('/status',real_session,ui)
local status=require('cjson').decode(output[1]);assert(status.session_id==real_session.id and status.turn_count==0)
assert(ui.test_poll==nil and ui.test_begin==nil)
print('headless status handles session methods without serializing them')
local retry_root=os.tmpname();os.remove(retry_root);assert(uv.fs_mkdir(retry_root,448))
local tries=0;m.resume_seen=function() return false end
m.suspend=function() tries=tries+1;if tries==1 then return nil,'unknown' end;return true end
assert(m.request_suspend(retry_root,{}, {})==true and tries==2)
tries=0;m.suspend=function() tries=tries+1;if tries==1 then return nil,'unknown' end;return false,'refused' end
assert(m.request_suspend(retry_root,{}, {})==nil and tries==3,'a later refusal cannot clear an uncertain earlier request')
tries=0;m.suspend=function() tries=tries+1;return nil,'unknown' end
m.resume_seen=function() return tries>0 end
assert(m.request_suspend(retry_root,{}, {})==true and tries==1,'resume prevents another suspend request')
os.execute('rm -rf '..require('agent.util.shell').quote(retry_root))
print('bounded uncertain-request retry and resume cancellation passed')
