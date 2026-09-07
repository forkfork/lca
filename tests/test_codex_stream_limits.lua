-- Exercise provider callbacks and byte limits through both transport adapters.
package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path
require('luarocks.loader')
local json = require('agent.util.json')
local codex = require('agent.providers.codex')
local ws = require('agent.net.websocket_transport')
local path = os.tmpname()
local f = assert(io.open(path, 'w'))
f:write(json.encode({access='test-only',accountId='test-account',expires=(os.time()+3600)*1000}));f:close()
local old_connect, old_request = ws.connect, ws.request
local serial = 0
local ok, err = xpcall(function()
 for _,kind in ipairs({'http','websocket'}) do
  for _,case in ipairs({
   {pieces={'hello','\0','é','🌈'}, expected='hello\0é🌈'},
   {pieces={string.rep('é',100000)}, bytes=200000},
   {pieces={string.rep('x',199999),'é'}, abort=true, delivered=199999},
   {pieces={string.rep('x',200000),'x'}, abort=true, delivered=200000},
  }) do
   serial=serial+1
   local function feed(callback,http)
    for _,delta in ipairs(case.pieces) do
     local payload=json.encode({type='response.output_text.delta',delta=delta})
     if callback(http and ('data: '..payload..'\r\n\r\n') or payload)==false then return end
    end
    local payload='{"type":"response.completed","response":{"usage":{"input_tokens":10,"output_tokens":20}}}'
    callback(http and ('data: '..payload..'\n\n') or payload)
   end
   codex._set_websocket_enabled(kind=='websocket')
   codex._set_http_request(function(opts) feed(opts.on_body_chunk,true);return {status=200} end)
   ws.connect=function() return {request=function(_,_,cb) feed(cb,false);return {status=101} end,close=function() end} end
   ws.request=function(opts) feed(opts.on_text,false);return {status=101} end
   local delivered,protocol={},{}
   local success,result=pcall(codex.complete, {session_id='stream-limit-'..serial,credentials_path=path,max_retries=0,messages={{role='user',text='test'}},
    on_protocol=function(event,data) protocol[#protocol+1]={event=event,data=data} end}, function(d) delivered[#delivered+1]=d end)
   assert(protocol[1].event=='transport_request' and protocol[1].data.transport==kind)
   assert(not protocol[1].data.body:find('test-only',1,true),'credentials leaked into protocol log')
   local raw={}
   for _,entry in ipairs(protocol) do
    if entry.event=='transport_chunk' then
     raw[#raw+1]=(entry.data.bytes_hex:gsub('..',function(hex) return string.char(tonumber(hex,16)) end))
    end
   end
   local recovered={}
   for _,chunk in ipairs(raw) do
    local payload=kind=='http' and chunk:match('data: (.-)\r?\n') or chunk
    local event=json.decode(payload)
    if event.delta then recovered[#recovered+1]=event.delta end
   end
   assert(table.concat(recovered)==table.concat(case.pieces),'raw log lost bytes, including the cutoff chunk')
   assert(protocol[#protocol].event=='transport_result')
   if case.abort then
    assert(not success and tostring(result):find('output_text_too_large',1,true),tostring(result))
    assert(#table.concat(delivered)==case.delivered)
   else
    assert(success,tostring(result));assert(result.text==table.concat(case.pieces));assert(table.concat(delivered)==result.text)
    assert(result._usage.prompt_tokens==10)
   end
  end
 end
end,debug.traceback)
codex._set_http_request(nil);codex._set_websocket_enabled(true)
ws.connect,ws.request=old_connect,old_request
os.remove(path)
assert(ok,err)
print('PASS: HTTP/WebSocket output, callbacks, usage and byte cutoff boundaries')
