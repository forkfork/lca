-- Replay the observed WebSocket close -> generic HTTP 400 without live requests.
package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path
require('luarocks.loader')
local json = require('agent.util.json')
local codex = require('agent.providers.codex')
local ws = require('agent.net.websocket_transport')
local core = require('agent.core')
local path = os.tmpname()
local f = assert(io.open(path, 'w'))
f:write(json.encode({access='test-only',accountId='test-account',expires=(os.time()+3600)*1000})); f:close()
local old_connect, old_request, old_log = ws.connect, ws.request, core.debug_log
local ok, err = xpcall(function()
 local logs = {}
 core.debug_log = function(fmt, ...) logs[#logs+1] = string.format(fmt, ...) end
 local failure = {_transport_error=true,kind='stream',phase='read',detail='websocket closed'}
 ws.connect = function() return nil, failure end
 ws.request = function() return nil, failure end
 for _, fallback in ipairs({false, true}) do
  codex._set_websocket_enabled(fallback)
  local calls, protocol = 0, {}
  codex._set_http_request(function()
   calls = calls + 1
   return {status=400,body_tail='{"detail":"Bad Request"}',headers={
    ['x-request-id']='req-test\r\ninjected', ['cf-ray']='ray-test', ['set-cookie']='secret-cookie',
   }}
  end)
  local success, message = pcall(codex.complete, {credentials_path=path,messages={{role='user',text='test'}},
   on_protocol=function(event,data) protocol[#protocol+1]={event=event,data=data} end})
  message = tostring(message)
  assert(not success and message:find('Codex HTTP error 400: {"detail":"Bad Request"}',1,true), message)
  assert(calls == 1, 'generic 400 must not be retried')
  assert(message:find('x-request-id=req-test  injected',1,true), message)
  assert(message:find('cf-ray=ray-test',1,true), message)
  assert((message:find('HTTP fallback after WebSocket failure: stream/read websocket closed',1,true) ~= nil) == fallback, message)
  assert(not message:find('secret-cookie',1,true))
  local final = protocol[#protocol]
  assert(final.event == 'transport_result' and final.data.status == 400)
  assert(final.data.diagnostics:find('req-test',1,true))
  assert(not json.encode(protocol):find('secret-cookie',1,true))
 end
 local log = table.concat(logs, '\n')
 assert(not log:find('succeeded',1,true), log)
 assert(log:find('stream stats http_error',1,true), log)
 assert(not log:find('secret-cookie',1,true))
end, debug.traceback)
ws.connect, ws.request, core.debug_log = old_connect, old_request, old_log
codex._set_http_request(nil); codex._set_websocket_enabled(true)
os.remove(path)
assert(ok, err)
print('PASS: Codex HTTP rejection and fallback diagnostics')
