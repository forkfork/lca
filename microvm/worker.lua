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
local state={version=1,capabilities={shell_commands=true,durable_checkpoints=true,live_events=true},session_id=session.id,phase='ready',completed={},session=session:serialize()}
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
            local number=1
            for _,message in ipairs(session.messages) do
                if message.role=='user' and not message.tool_name and not message.operational_snapshot and not message.shell_result then number=number+1 end
            end
            local journal=require('events').open(root,item.id,{prompt=item.text,number=number,session_id=session.id,command=item.text:sub(1,1)=='/' or item.text:sub(1,1)=='!'})
            local function emit(kind,payload) if journal then journal:emit(kind,payload) end end
            state.live=journal and {id=item.id,number=number,prompt=item.text,complete=false} or nil
            state.phase='running';state.active=item.id;save()
            print('\n> '..item.text)
            local ok,result=pcall(function()
                if item.text:sub(1,1)=='/' or item.text:sub(1,1)=='!' then
                    local cmd=item.text:match('^/(%S+)')
                    assert(item.text:sub(1,1)=='!' or ({test=true,status=true,context=true,reasoning=true,['service-tier']=true})[cmd],
                        'unsupported remote command; use prompts or /test, /status, /context, /reasoning, /service-tier')
                    local command_failed=false
                    local ui=require('headless').ui(function(text)
                        local code=tostring(text):match(' · exit (%d+)');if code and tonumber(code)~=0 then command_failed=true end
                        print(text);emit('command_output',{text=text})
                    end)
                    ui.test_begin=function(command)
                        emit('tool',{event={phase='start',name='run',call_id=item.id,args={command=command}}})
                    end
                    ui.test_end=function() emit('tool',{event={phase='end',name='run',call_id=item.id,result={summary=command_failed and 'Command failed; see output' or 'Command finished; see output',is_error=command_failed}}}) end
                    require('agent.commands').dispatch(item.text,session,ui)
                else
                    session:add_user(item.text)
                    local r=require('agent.core').run_session(session,
                        function(text) if journal then journal:token(text) end end,
                        function(event) emit('tool',{event=event}) end,
                        function(info) emit('thinking',{info=info}) end,
                        function() if journal then journal:tick() end end,
                        {on_response=function(response)
                            emit('response',{response={text=response.text,_output_items=response._output_items,_native_tool_calls=response._native_tool_calls}})
                         end,on_model_activity=function(activity) emit('activity',{activity=activity}) end})
                    emit('answer',{response={text=r.text,_output_items=r._output_items},usage=r._turn_usage or r._usage})
                    session:add_assistant(r.text,r._output_items)
                    print(r.text or '')
                end
            end)
            emit('finish',{error=not ok and tostring(result) or nil})
            if journal then journal:close();state.live.complete=true;state.live.error=journal.failed;state.live.bytes=journal.bytes end
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
