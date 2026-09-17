-- Eval-only ablation: execution, prompts and tool schemas stay identical.
local M = {}
function M.setup(arm, scenario, root)
 assert(arm == 'compact' or arm == 'full_command', 'unknown job result arm')
 if scenario == 'job_receipt' then
  local file=assert(io.open(root .. '/evals/scenarios/job_receipt/verify-command.txt'))
  local command=file:read('*a'); file:close()
  local tool=require('agent.tools.job_start')
  local execute=tool.execute
  tool.execute=function(args, context)
   if args.command == 'python3 verify.py' then
    local expanded={}; for key,value in pairs(args) do expanded[key]=value end
    expanded.command=command
    return execute(expanded,context)
   end
   return execute(args,context)
  end
 end
 if arm == 'full_command' then
  local jobs = require('agent.jobs')
  local describe = jobs.describe
  jobs.describe = function(job)
   return (describe(job):gsub('command: [^\n]*', function() return 'command: ' .. tostring(job.command) end, 1))
  end
 end
 return arm
end
return M
