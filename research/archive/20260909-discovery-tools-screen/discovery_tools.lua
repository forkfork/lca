-- Eval-only discovery ablation; native tagged reads and edits are unchanged.
local json = require('agent.util.json')
local registry = require('agent.tool_registry')
local M = {}
local removed = {ls=true, find=true, grep=true}
function M.apply(mode, session, root, directory)
    assert(mode == 'native' or mode == 'shell', 'unsupported discovery tools')
    assert(session.tool_scope == 'local_only', 'discovery ablation requires local_only')
    local baseline = session:get_system_prompt()
    local effective, tools = baseline, registry.native_tools()
    for _, tool in ipairs(tools) do assert(not tool.name:match('^mcp__'), 'external tools not allowed') end
    if mode == 'shell' then
        local file = assert(io.open(root .. '/evals/discovery_tools_prompt.json'))
        local mapping = json.decode(file:read('*a')); file:close()
        for old, replacement in pairs(mapping) do
            local a = assert(effective:find(old, 1, true), 'missing prompt seam')
            local b = a + #old - 1
            assert(not effective:find(old, b + 1, true), 'duplicate prompt seam')
            effective = effective:sub(1,a-1) .. replacement .. effective:sub(b+1)
        end
        local original_tools, original_execute = registry.native_tools, registry.execute
        registry.native_tools = function()
            local selected = {}
            for _, tool in ipairs(original_tools()) do
                if not removed[tool.name] then selected[#selected+1] = tool end
            end
            return selected
        end
        registry.execute = function(name, args, context)
            assert(not removed[name], 'discovery ablation blocked tool: ' .. tostring(name))
            return original_execute(name, args, context)
        end
    end
    session.system_prompt = effective
    local file = assert(io.open(directory .. '/discovery-tools.json', 'w'))
    file:write(json.encode({mode=mode, baseline=baseline, effective=effective, tools=tools}), '\n')
    file:close()
end
return M
