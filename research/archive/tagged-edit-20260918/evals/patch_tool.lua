-- Eval-only adapter for OpenAI apply_patch operation objects. Diff parsing is the
-- unmodified OpenAI Agents SDK parser; writes share tagged edit's syntax policy.
local fs = require('agent.util.fs')
local path = require('agent.util.path')
local shell = require('agent.util.shell')
local json = require('agent.util.json')
local edit = require('agent.tools.edit')
local M = {}
local function failure(message)
 return { is_error = true, content = tostring(message), summary = 'patch failed' }
end
function M.new(root)
 return { execute = function(args, context)
  if type(args.path) ~= 'string' or args.path == '' then return failure('path is required') end
  if args.type ~= 'create_file' and args.type ~= 'update_file' and args.type ~= 'delete_file' then
   return failure('unknown patch operation')
  end
  local target = path.resolve(args.path, context.cwd)
  local exists, original = pcall(fs.read_file, target)
  if args.type == 'create_file' and exists then return failure('create_file target already exists') end
  if args.type ~= 'create_file' and not exists then return failure(original) end
  if args.type == 'delete_file' then
   local ok, err = os.remove(target)
   if not ok then return failure(err) end
   return { content = 'Deleted ' .. args.path, summary = 'deleted ' .. args.path }
  end
  if type(args.diff) ~= 'string' then return failure('diff must be a string') end
  local input = os.tmpname()
  local ok, result = pcall(function()
   fs.write_file(input, json.encode({ input = exists and original or '', diff = args.diff, type = args.type }))
   return (context.executor or shell):run('python3 -B ' .. shell.quote(root .. '/evals/apply_patch_diff.py') .. ' ' .. shell.quote(input),
    { cwd = context.cwd, timeout = 5000 })
  end)
  os.remove(input)
  if not ok then return failure(result) end
  if result.code ~= 0 then return failure(result.output or result.error or 'diff parser failed') end
  local decoded_ok, candidate = pcall(json.decode, result.output)
  if not decoded_ok or type(candidate) ~= 'table' then return failure('invalid diff parser response') end
  if candidate.error then return failure(candidate.error) end
  if type(candidate.content) ~= 'string' then return failure('missing diff candidate') end
  if args.type == 'create_file' then
   return require('agent.tools.write').execute({ path = args.path, content = candidate.content }, context)
  end
  local lint_error = edit.check_candidate(target, original, candidate.content)
  if lint_error then return failure('BLOCKED: patch would produce syntax errors, file NOT modified.\n' .. lint_error) end
  local written, err = pcall(fs.write_file, target, candidate.content)
  if not written then return failure(err) end
  return { content = 'Patched ' .. args.path, summary = 'patched ' .. args.path }
 end }
end
return M
