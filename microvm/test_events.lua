package.path='microvm/?.lua;lua/?.lua;'..package.path
local uv=require('luv');local json=require('cjson');local events=require('events');local view=dofile('microvm/foreground.lua');local tui=require('agent.tui')
local root=os.tmpname();os.remove(root);assert(uv.fs_mkdir(root,448))
local journal=assert(events.open(root,'turn-1',{number=1,prompt='fix it',session_id='test'}))
journal:token('I am checking. '..string.rep('Details ',20));journal:flush()
journal:emit('tool',{event={phase='start',call_id='read-1',name='read',args={path='main.lua'}}})
journal:emit('tool',{event={phase='end',call_id='read-1',name='read',args={path='main.lua'},result={content='missing',is_error=true}}})
journal:emit('thinking',{info={status='Retrying after failed read'}})
local commentary={type='message',phase='commentary',id='commentary-1',content={{type='output_text',text='I will repair the missing file.'}}}
journal:emit('activity',{activity={type='assistant_commentary',item=commentary}})
journal:emit('response',{response={text='I will repair the missing file.',_output_items={commentary}}})
journal:emit('answer',{response={text='Fixed and tested.'},usage={prompt_tokens=100,cache_available=true,cached_tokens=50}})
journal:emit('finish',{});journal:close()
local app=tui.App.new({effect='drift',size_provider=function() return 100,30 end});local lines={}
app.commit_lines=function(_,items) for _,line in ipairs(items) do lines[#lines+1]=line end end
local records={};for line in io.lines(root..'/events/turn-1.jsonl') do records[#records+1]=json.decode(line) end
for i,item in ipairs(records) do
 assert(item.seq==i)
 view.apply(app,{type='live',event=item})
 if item.kind=='token' then assert(app.state.assistant_stream:find('I am checking.',1,true)) end
 if item.kind=='tool' and item.event.phase=='start' then assert(app.state.tools_by_id['read-1'].status=='active') end
 if item.kind=='tool' and item.event.phase=='end' then assert(app.state.tools_by_id['read-1'].status=='error') end
end
assert(not app.busy and not app.remote_live)
local count=#lines
for _,item in ipairs(records) do view.apply(app,{type='live',event=item}) end
view.apply(app,{type='history',session_id='test',turns={{number=1,prompt='fix it',calls=1,responses={'Fixed and tested.'}}}})
assert(#lines==count,'reconnect replay and completed snapshot must not duplicate live transcript')
assert(table.concat(lines,'\n'):find('Fixed and tested.',1,true))
local _,commentary_count=table.concat(lines,'\n'):gsub('I will repair the missing file%.','')
assert(commentary_count==1,'streamed commentary and response snapshots must not duplicate')
for i=2,5 do local j=assert(events.open(root,'turn-'..i,{number=i,prompt='x'}));j:close() end
local scan=uv.fs_scandir(root..'/events');local files=0;while uv.fs_scandir_next(scan) do files=files+1 end
assert(files==3,'journal retention bounded to three turns')
local j=assert(events.open(root,'limit',{number=6,prompt='x'}));j.bytes=9*1024*1024;j:token('ignored');j:emit('finish',{});j:close()
local kinds={};for line in io.lines(root..'/events/limit.jsonl') do kinds[#kinds+1]=json.decode(line).kind end
assert(kinds[#kinds]=='finish' and kinds[#kinds-1]=='gap','bounded log still closes the UI turn')
for line in io.lines(root..'/events/limit.jsonl') do view.apply(app,{type='live',event=json.decode(line)}) end
local before_fallback=#lines
view.apply(app,{type='history',session_id='test',turns={{number=6,prompt='x',calls=1,responses={'Result recovered from completed history.'}}}})
assert(#lines>before_fallback,'display limit must not hide the final answer from completed history')
os.execute('rm -rf '..require('agent.util.shell').quote(root))
print('live model/tool rendering, deduplication and bounded journals passed')
