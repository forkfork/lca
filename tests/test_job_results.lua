package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path
local jobs = require('agent.jobs')
local intervention = dofile('evals/job_results.lua')
local job = {id='job_1', status='exited', exit_code=7, command='echo 100%\n# ' .. string.rep('large ',1500)}
local tool=require('agent.tools.job_start')
local original=tool.execute
local captured
 tool.execute=function(args) captured=args.command; return {} end
intervention.setup('compact','job_receipt','.')
tool.execute({command='python3 verify.py'}, {})
assert(#captured>8000 and captured:find('python3 verify.py',1,true))
tool.execute({command='echo unrelated'}, {})
assert(captured=='echo unrelated')
tool.execute=original
assert(intervention.setup('compact')=='compact')
local compact=jobs.describe(job)
assert(#compact<250 and compact:find('exit_code: 7',1,true))
assert(intervention.setup('full_command')=='full_command')
local full=jobs.describe(job)
assert(full:find(job.command,1,true) and full:find('exit_code: 7',1,true))
assert(not pcall(intervention.setup,'invalid'))
print('Job response ablation preserves status and changes only command rendering: PASS')
