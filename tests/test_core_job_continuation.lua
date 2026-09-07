package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path
pcall(require,'luarocks.loader')
local fixture = dofile('tests/native_fixture.lua')
local active, calls
package.loaded['agent.providers'] = {load=function() return {complete=function(messages)
 calls=calls+1
 if calls==1 then
  return fixture.response({text='<tool_call name="'..active..'">\n{"id":"job_22"}\n</tool_call>'})
 end
 assert(calls==2,'unexpected extra model call')
 local found=false
 for _,message in ipairs(messages.messages) do
  if (message.text or ''):find('status: exited',1,true) then found=true end
 end
 assert(found,'model did not receive job result')
 return {text='Review findings: the test job exited successfully. The project still needs review of error handling.'}
end} end}
for _,name in ipairs({'job_status','job_output','job_wait','job_stop'}) do
 require('agent.tools.'..name).execute=function()
  return {content='id: job_22\nstatus: exited\nexit_code: 0',summary='exited',is_error=false}
 end
end
local core=require('agent.core')
local sessions=require('agent.session')
for _,name in ipairs({'job_status','job_output','job_wait','job_stop'}) do
 active,calls=name,0
 local session=sessions.create({})
 session:add_user('review the quality of this project lca')
 local result=core.run_session(session)
 assert(calls==2,name..' terminated the review')
 assert(result.text:find('Review findings:',1,true),name..' returned job metadata as the answer')
end
print('Job tools return results to the model instead of ending the task: PASS')
