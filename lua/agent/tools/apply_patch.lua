-- OpenAI V4A function adapter. Generate and validate the complete candidate before writing.
local fs = require('agent.util.fs')
local path = require('agent.util.path')
local shell = require('agent.util.shell')
local diff_parser = require('agent.patch_diff')
local uv = require('luv')
local lint = require('agent.lint')
local validation = require('agent.patch_validation')
local M = {}
local function failure(message)
 return { is_error = true, content = tostring(message), summary = 'patch failed' }
end
function M.execute(args, context)
  if type(args.path) ~= 'string' or args.path == '' then return failure('path is required') end
  if args.type ~= 'create_file' and args.type ~= 'update_file' and args.type ~= 'delete_file' then
   return failure('unknown patch operation')
  end
  local target = path.resolve(args.path, context.cwd)
  local stat, stat_error, stat_code = uv.fs_lstat(target)
  if not stat and stat_code ~= 'ENOENT' then return failure(stat_error) end
  local exists = stat ~= nil
  if args.type == 'create_file' and exists then return failure('create_file target already exists') end
  if args.type ~= 'create_file' and not exists then return failure(stat_error) end
  local original = ''
  if args.type == 'update_file' then
   local readable, content = pcall(fs.read_file, target)
   if not readable or type(content) ~= 'string' then return failure(content or 'cannot read target') end
   original = content
  end
  if args.type == 'delete_file' then
   local ok, err = os.remove(target)
   if not ok then return failure(err) end
   return { is_error = false, content = 'Deleted ' .. args.path, summary = 'deleted ' .. args.path }
  end
  if type(args.diff) ~= 'string' then return failure('diff must be a string') end
  local ok, content = pcall(diff_parser.apply, original, args.diff,
   args.type == 'create_file' and 'create' or 'default')
  if not ok then return failure(content) end
  local candidate = { content = content }
  if args.type == 'create_file' then
   local content = candidate.content
   if content ~= '' and content:sub(-1) ~= '\n' then content = content .. '\n' end
   local lint_error = lint.check_content(target, content)
   if lint_error then return failure('BLOCKED: patch would produce syntax errors, file NOT modified.\n' .. lint_error) end
   local made, mkdir_error = pcall(shell.capture, 'mkdir -p ' .. shell.quote(target:match('^(.*)/[^/]*$')), context.executor)
   if not made then return failure(mkdir_error) end
   -- Exclusive creation also rejects dangling symlinks and targets appearing during validation.
   local fd, open_error = uv.fs_open(target, 'wx', 438) -- 0666, filtered by the process umask
   if not fd then return failure('File changed or cannot be created: ' .. tostring(open_error)) end
   local written, write_error = pcall(function()
    local offset = 0
    while offset < #content do
     local count, err = uv.fs_write(fd, content:sub(offset + 1), offset)
     assert(count and count > 0, err or 'short write')
     offset = offset + count
    end
   end)
   local closed, close_error = uv.fs_close(fd)
   if not written then return failure(write_error) end
   if not closed then return failure(close_error) end
   return { is_error = false, content = 'Created ' .. args.path, summary = 'created ' .. args.path }
  end
  local lint_error = validation.check_candidate(target, original, candidate.content)
  if lint_error then return failure('BLOCKED: patch would produce syntax errors, file NOT modified.\n' .. lint_error) end
  -- Check after potentially slow syntax validation, immediately before the write.
  -- This detects intervening changes; it is not a filesystem compare-and-swap.
  local readable, current = pcall(fs.read_file, target)
  if not readable or current ~= original then
   return failure('File changed or became unreadable while preparing patch; inspect it again before retrying')
  end
  local written, err = pcall(fs.write_file, target, candidate.content)
  if not written then return failure(err) end
  return { is_error = false, content = 'Patched ' .. args.path, summary = 'patched ' .. args.path }
end
return M
