-- One headless session, file inbox, AWS shell transport. No network listener.
local uv=require('luv')
local json=require('cjson')
local bg=require('agent.background')
package.path=(arg[0]:match('^(.*)/') or '.')..'/?.lua;'..package.path
local lifecycle=require('lifecycle')
local root=assert(arg[1])
local lifecycle_config=lifecycle.read(root..'/lifecycle.json')
local checkpoint=require('checkpoint')
local storage=lifecycle.read(root..'/storage.json')
local last_activity=os.time()
local function read(path) local f=assert(io.open(path));local s=f:read('*a');f:close();return json.decode(s) end
assert(uv.fs_mkdir(root..'/worker-lock',448),'worker already claimed; never replay uncertain work')
assert(uv.chdir(root..'/project'))
local data=read(root..'/checkpoint.json')
local opts=data.continuation_options or {}
opts.model=data.model;opts.reasoning_effort=data.reasoning_effort;opts.service_tier=data.service_tier
opts.credentials_path=root..'/credentials.json'
local session=require('agent.session').create(opts)
assert(session:load(root..'/checkpoint.json'))
session.cwd=assert(uv.cwd());session.credentials_path=opts.credentials_path
session.system_prompt=nil -- Regenerate machine context; retain messages and memory.
session.operational_checkpoint_pending=true
session.pending_inputs={}
local state={version=1,capabilities={shell_commands=true,durable_checkpoints=true},session_id=session.id,phase='ready',completed={},session=session:serialize()}
local function save() bg.atomic(root..'/state.json',state) end
save()
while not uv.fs_stat(root..'/commit') do uv.sleep(100) end
state.phase='idle';save()
require('agent.core').set_transcript(root..'/agent.log')
local initial=data.pending_inputs or {}
for i,text in ipairs(initial) do
    bg.atomic(root..'/inbox/000-'..string.format('%06d',i)..'.json',{id='initial-'..i,text=text})
end
io.stdout:setvbuf('no')
print('Session restored. Files, conversation, plan and queue are here.')
while not uv.fs_stat(root..'/stop') do
    local names={};local scan=assert(uv.fs_scandir(root..'/inbox'))
    while true do local name=uv.fs_scandir_next(scan);if not name then break end;if name:match('%.json$') then names[#names+1]=name end end
    table.sort(names)
    for _,name in ipairs(names) do
        if uv.fs_stat(root..'/stop') then break end
        local item=read(root..'/inbox/'..name)
        assert(type(item.id)=='string' and type(item.text)=='string')
        if not state.completed[item.id] then
            if not checkpoint.required(root,storage,state,function() checkpoint.attempt(root,storage,item) end) then break end
            state.phase='running';state.active=item.id;save()
            print('\n> '..item.text)
            local ok,result=pcall(function()
                if item.text:sub(1,1)=='/' or item.text:sub(1,1)=='!' then
                    local cmd=item.text:match('^/(%S+)')
                    assert(item.text:sub(1,1)=='!' or ({test=true,status=true,context=true,reasoning=true,['service-tier']=true})[cmd],
                        'unsupported remote command; use prompts or /test, /status, /context, /reasoning, /service-tier')
                    local ui=require('headless').ui()
                    require('agent.commands').dispatch(item.text,session,ui)
                else
                    session:add_user(item.text)
                    local r=require('agent.core').run_session(session)
                    session:add_assistant(r.text,r._output_items)
                    print(r.text or '')
                end
            end)
            if not ok then state.phase='failed';state.error=tostring(result);save();error(result) end
            last_activity=os.time()
            state.completed[item.id]=true;state.active=nil;state.phase='idle';state.session=session:serialize();save()
            if not checkpoint.required(root,storage,state,function() checkpoint.snapshot(root,storage,state) end) then break end
        end
    end
    if lifecycle_config then last_activity=lifecycle.tick(root,state,session,last_activity,lifecycle_config) end
    uv.sleep(250)
end
state.phase='stopped';state.session=session:serialize();save()
os.remove(root..'/credentials.json')
