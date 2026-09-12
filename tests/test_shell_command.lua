package.path='lua/?.lua;lua/?/init.lua;'..package.path
local uv=require('luv');local shell=require('agent.util.shell')
local session=require('agent.session').create({model='gpt-6-astra'})
local root=os.tmpname();os.remove(root);assert(uv.fs_mkdir(root,448));session.cwd=root
session.test_command='make test'
local output={};local errors={}
local ui={block=function(text) output[#output+1]=text end,error=function(err) errors[#errors+1]=err end}
local commands=require('agent.commands')
assert(commands.dispatch("!printf hello > marker; cat marker; printf problem >&2; exit 7",session,ui)==false)
local text=table.concat(output,'\n')
assert(text:find('hello',1,true) and text:find('problem',1,true) and text:find('exit 7',1,true),text)
assert(session.test_command=='make test','bang must not replace /test')
assert(#session.messages==2 and session.messages[2].shell_result)
assert(session.messages[2].text:find('exit 7',1,true))
assert(uv.fs_stat(root..'/marker'),'command must run in session cwd')
assert(session:save(root..'/saved.json'))
local restored=require('agent.session').create({});assert(restored:load(root..'/saved.json'))
assert(restored.messages[2].shell_result and restored.messages[2].text:find('hello',1,true))
commands.dispatch('!   ',session,ui);assert(#errors==1 and #session.messages==2,'empty command must not execute')
os.execute('rm -rf '..shell.quote(root))
print('shell output, nonzero exit, cwd, history and test-setting preservation passed')
