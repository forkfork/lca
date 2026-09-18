-- The experiment changes only the edit declaration and its operating instructions.
local M = {}
local substitutions = {
 {'- For edits, inspect the target with read or tagged grep evidence first, then use its exact line numbers and four-character tags. Make the smallest coherent change and run focused verification.',
  '- For edits, inspect the target with read or grep first, then use apply_patch with contextual diff hunks. Read/grep line numbers and four-character tags are display labels: omit them from patch content. Make the smallest coherent change and run focused verification.'},
 {'- Batch independent inspection calls when useful. Do not call read and edit/write for the same file in parallel.',
  '- Batch independent inspection calls when useful. Do not call read and apply_patch/write for the same file in parallel.'},
 {'- After inspection, batch non-overlapping tagged edits whose replacements are all known.',
  '- After inspection, combine known non-overlapping changes in one file into one apply_patch operation with multiple contextual hunks.'},
 {'- Group known import and body replacements against the same inspected file version. An earlier insertion can shift later line numbers: do not submit a later edit using tags from before that insertion. Batch independent replacements together; re-read before a dependent edit.',
  '- Group known import and body replacements against the same inspected file version. Use unchanged context to locate each hunk; re-read before a dependent edit when its context is uncertain.'},
}
function M.setup(session, arm, root, directory)
 assert(arm == 'tagged' or arm == 'openai_patch_fixed_tests', 'unknown edit interface')
 local registry = require('agent.tool_registry')
 local baseline = session:get_system_prompt()
 local tools = registry.native_tools()
 if arm == 'openai_patch_fixed_tests' then
  assert(not registry.multi_edit_enabled(), 'patch comparison requires default single tagged edit')
  local effective = baseline
  for _, pair in ipairs(substitutions) do
   local first, last = effective:find(pair[1], 1, true)
   assert(first, 'missing edit instruction')
   effective = effective:sub(1, first - 1) .. pair[2] .. effective:sub(last + 1)
  end
  session.system_prompt = effective
  local tool = dofile(root .. '/evals/patch_tool.lua').new(root)
  local get, names = registry.get, registry.names
  registry.get = function(name)
   if name == 'apply_patch' then return tool end
   if name == 'edit' or name == 'multi_edit' then return nil end
   return get(name)
  end
  registry.names = function()
   local out = {}
   for _, name in ipairs(names()) do out[#out + 1] = name == 'edit' and 'apply_patch' or name end
   return out
  end
  -- Build from the captured baseline: native() consults registry.names dynamically.
  registry.native_tools = function()
   local out = {}
   for _, spec in ipairs(tools) do out[#out + 1] = spec.name == 'edit' and { type = 'function', name = 'apply_patch', strict = false,
    description = 'Apply an OpenAI V4A contextual diff. Use update_file for existing files (diff with @@ hunks, space context, - removals, + additions); create_file uses + lines; delete_file needs only path. Do not include Begin/End Patch wrappers or read/grep display labels. Multiple hunks in one file are applied together and checked for syntax before writing.',
    parameters = { type = 'object', properties = { type = { type = 'string', enum = { 'create_file', 'update_file', 'delete_file' } }, path = { type = 'string' }, diff = { type = 'string' } }, required = { 'type', 'path' }, additionalProperties = false } } or spec end
   return out
  end
 end
 require('agent.util.fs').write_file(directory .. '/edit-interface.json', require('agent.util.json').encode({
  profile = arm, baseline_prompt = baseline, effective_prompt = session:get_system_prompt(),
  baseline_tools = tools, effective_tools = registry.native_tools(),
 }))
end
return M
