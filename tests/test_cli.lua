package.path='./lua/?.lua;./lua/?/init.lua;'..package.path
local shell=require('agent.util.shell')
local uv=require('luv')
for _,case in ipairs({{'--help',0},{'help',0},{'not-a-command',2}}) do
 local stdout,stderr=os.tmpname(),os.tmpname()
 local ok,_,code=os.execute(shell.quote(uv.exepath())..' bin/lca '..shell.quote(case[1])..' >'..shell.quote(stdout)..' 2>'..shell.quote(stderr))
 local out=assert(io.open(stdout)):read('*a');local err=assert(io.open(stderr)):read('*a')
 os.remove(stdout);os.remove(stderr)
 assert((ok and 0 or code)==case[2],'incorrect CLI exit for '..case[1])
 if case[2]==0 then assert(out:find('Usage:',1,true) and err=='') else assert(err:find('Usage:',1,true)) end
end
print('PASS explicit help succeeds; invalid command fails')
