-- Host-only view. This process never runs the remote session or its tools.
local uv=require('luv')
local json=require('cjson')
local tui=require('agent.tui')
local M={}
local function commit_visible_reply(app,text)
 local protocol=require('agent.tool_protocol')
 local visible=protocol.strip_tool_results(protocol.strip_tool_calls(text))
 if visible:match('%S') then app:commit_assistant(visible) end
end
function M.apply(app,event)
 if event.type=='history' then
  app.remote_history=true
  app.remote_seen=app.remote_seen or {}
  for _,turn in ipairs(event.turns) do
   local key=tostring(turn.number)..':'..turn.prompt
   -- state.json contains completed-turn snapshots; polling must not replay them.
   if not app.remote_seen[key] and #turn.responses>0 then
    app.remote_seen[key]=true
    app:commit_user(turn.prompt)
    if turn.shell then
     local lines={};for line in (table.concat(turn.responses,'\n')..'\n'):gmatch('(.-)\n') do lines[#lines+1]='shell › '..line end
     app:commit_lines(lines)
    else
    for i=1,#turn.responses-1 do
     commit_visible_reply(app,turn.responses[i])
    end
    if turn.calls>0 then
     local lines=require('agent.river_divider').render({width=select(1,app:_size()),
      color=app.backend:supports_color(),seed=event.session_id,turn=turn.number})
     lines[#lines+1]=string.format('%d tool calls · restored history',turn.calls)
     app:commit_lines(lines)
    end
    commit_visible_reply(app,turn.responses[#turn.responses])
    end
   end
  end
 elseif event.type=='output' then
  app.remote_tail=(app.remote_tail or '')..event.text
  local lines={}
  while app.remote_tail:find('\n',1,true) do
   local line,rest=app.remote_tail:match('^(.-)\n(.*)$')
   if app.remote_history then
    if line:match('^> ') then app.remote_raw_command=line:match('^> /')~=nil end
    if app.remote_raw_command then lines[#lines+1]=line end
   else lines[#lines+1]=line end
   app.remote_tail=rest
  end
  if #lines>0 then app:commit_lines(lines) end
 elseif event.type=='notice' then
  app.state:notice(event.text)
  app:commit_lines({event.text})
 elseif event.type=='state' then
  local labels={checkpointing='backup paused',running='working',idle='ready',ready='ready',suspending='sleeping',waking='waking',reconnecting='reconnecting',failed='failed',stopped='stopped'}
  app.session_badge='remote · '..(labels[event.phase] or event.phase)
  local key=event.phase..':'..(type(event.active)=='string' and event.active or '')
  if key==app.remote_key then return end
  app.remote_key=key
  app.busy=event.phase=='running'
  if app.busy then
   app:auto_advance_effect();app.state:submit('Remote LCA')
   app.state.model_phase='working in MicroVM'
  else
   app.state:listen()
   app.state:notice(event.phase=='suspending' and 'MicroVM sleeping · send a prompt to wake' or 'Remote · '..event.phase)
  end
 end
end
function M.run(command_path,event_fd)
 local app=tui.App.new({effect=os.getenv('LCA_TUI_EFFECT')})
 app.session_badge='remote · connecting'
 app.input_hint='Enter sends · Ctrl-C/D detaches · /local brings home'
 local commands=assert(io.open(command_path,'a'));commands:setvbuf('no')
 local function send(text) commands:write(json.encode({text=text})..'\n') end
 -- Ctrl-C detaches, never claims to cancel a remote tool.
 app._handle_action=function(self,action)
  if action and action.type=='cancel' then self.exit_requested=true
  else tui.App._handle_action(self,action) end
 end
 local input=uv.new_pipe(false);input:open(assert(tonumber(event_fd)))
 local buffer=''
 local ok,err=tui.with_terminal(app.terminal,app.renderer,function()
  app.state:notice('Connecting to remote session…')
  app:start_io()
  input:read_start(function(read_err,chunk)
   if read_err then app.fatal_error=tostring(read_err);app.exit_requested=true;return end
   if not chunk then app.exit_requested=true;return end
   buffer=buffer..chunk
   while buffer:find('\n',1,true) do
    local line,rest=buffer:match('^(.-)\n(.*)$');buffer=rest
    local decoded,event=pcall(json.decode,line)
    if decoded then M.apply(app,event) else app.fatal_error='invalid remote display event';app.exit_requested=true end
   end
  end)
  while not app.exit_requested do
   local line=app:next_submission()
   if line then
    local effect=line:match('^/effect%s+(%S+)%s*$')
    if effect then
     local changed,why=pcall(app.set_effect,app,effect)
     if not changed then app.state:notice(tostring(why),'error') end
    elseif line=='/bg' or line=='/background' then send('/detach');break
    elseif line=='/cloud' then app.state:notice('Already attached to the cloud session.')
    elseif line=='/detach' or line=='/local' then send(line);break
    elseif line:sub(1,1)=='/' and not ({test=true,status=true,context=true,reasoning=true,['service-tier']=true})[line:match('^/(%S+)')] then
     app.state:notice('Remote commands: /test, /status, /context, /reasoning, /service-tier, /local, /bg, /detach','error')
    else send(line);app.state:notice('Submitting input…') end
   end
  end
  if app.exit_requested then send('/detach') end
  if app.fatal_error then error(app.fatal_error) end
  return true
 end)
 app:stop_io();input:read_stop();input:close();commands:close();uv.run('nowait')
 if not ok then error(err) end
end
if arg and arg[0] and arg[0]:match('/foreground%.lua$') then M.run(assert(arg[1]),assert(arg[2])) end
return M
