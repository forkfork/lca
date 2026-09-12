package.path='lua/?.lua;lua/?/init.lua;'..package.path
local tui=require('agent.tui')
local view=dofile('microvm/foreground.lua')
local app=tui.App.new({effect='drift'})
local lines={};app.commit_lines=function(_,items) for _,line in ipairs(items) do lines[#lines+1]=line end end
view.apply(app,{type='state',phase='running',active='a'})
local turn=app.state.turn_sequence
assert(app.busy)
assert(app.session_badge=='remote · working')
view.apply(app,{type='state',phase='running',active='a'})
assert(app.state.turn_sequence==turn,'polling must not restart animation')
view.apply(app,{type='output',text='first\npart'})
view.apply(app,{type='output',text='ial\n'})
assert(#lines==2 and lines[2]=='partial','partial lines must not duplicate output')
view.apply(app,require('cjson').decode('{"type":"state","phase":"suspending","active":null}'))
assert(not app.busy and app.state.mode=='listening','sleep stops active-work animation')
assert(app.session_badge=='remote · sleeping')
view.apply(app,{type='state',phase='running',active='b'})
assert(app.busy and app.state.turn_sequence==turn+1,'wake starts next activity')
print('remote display state tests passed')
local before=#lines
local history={type='history',session_id='test',turns={{number=1,prompt='build it',calls=2,responses={'Implemented and tested.'}}}}
view.apply(app,history)
local after=#lines
assert(after>before+3,'history includes framed conversation and river art')
local joined=table.concat(lines,'\n')
assert(joined:find('you › build it',1,true) and joined:find('lca ›',1,true))
assert(joined:find('2 tool calls · restored history',1,true))
view.apply(app,history);assert(#lines==after,'repeated snapshots do not duplicate history')
view.apply(app,{type='output',text='Session restored.\n\n> build it\nImplemented and tested.\n'})
assert(#lines==after,'raw model transcript must not duplicate restored conversation')
view.apply(app,{type='output',text='\n> /status\n{"turn_count":1}\n'})
assert(#lines>after,'slash-command output remains visible')
-- Captured from the source-tree turn: two tool-only assistant messages.
local replies={}
local saved_commit=app.commit_assistant
app.commit_assistant=function(_,text) replies[#replies+1]=text end
view.apply(app,{type='history',session_id='captured',turns={{number=4,prompt='show me the source tree and the functions in each',calls=3,responses={
 [=[<tool_call name="find">
{"path":".","maxDepth":2}
</tool_call>
<tool_call name="grep">
{"pattern":"^(class |def |    def )","path":".","glob":"*.py"}
</tool_call>]=],
 [=[<tool_call name="grep">
{"path":"server.py","pattern":"^def "}
</tool_call>]=],
 'Source tree, excluding Git internals:',
}}}})
assert(#replies==1 and replies[1]=='Source tree, excluding Git internals:',
 'tool-only messages must not become empty assistant boxes')
app.commit_assistant=saved_commit
