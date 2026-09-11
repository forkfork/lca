-- Eval-only file-tool ablation and tool-neutral filesystem evidence.
local json = require('agent.util.json')
local uv = require('luv')
local registry = require('agent.tool_registry')
local M = {}
local allowed = {run=true, job_start=true, job_output=true, job_status=true,
    job_wait=true, job_stop=true, update_plan=true}
local function read(path)
    local f = assert(io.open(path, 'rb')); local s = f:read('*a'); f:close(); return s
end
local function save(path, value)
    local f = assert(io.open(path, 'w')); f:write(json.encode(value), '\n'); f:close()
end
function M.apply(mode, session, root, directory)
    assert(mode == 'native' or mode == 'shell', 'unsupported file tools')
    assert(session.tool_scope == 'local_only', 'file ablation requires local_only')
    local baseline = session:get_system_prompt()
    local effective = baseline
    local tools = registry.native_tools()
    for _, t in ipairs(tools) do assert(not t.name:match('^mcp__'), 'external tools not allowed') end
    if mode == 'shell' then
        local mapping = json.decode(read(root .. '/evals/file_tools_prompt.json'))
        for old, replacement in pairs(mapping) do
            local a, b = assert(effective:find(old, 1, true), 'missing prompt seam'), nil
            b = a + #old - 1
            assert(not effective:find(old, b + 1, true), 'duplicate prompt seam')
            effective = effective:sub(1,a-1) .. replacement .. effective:sub(b+1)
        end
        local original_tools, original_execute = registry.native_tools, registry.execute
        registry.native_tools = function()
            local selected = {}
            for _, t in ipairs(original_tools()) do
                if allowed[t.name] then selected[#selected+1] = t end
            end
            return selected
        end
        registry.execute = function(name, args, context)
            assert(allowed[name], 'file ablation blocked tool: ' .. tostring(name))
            return original_execute(name, args, context)
        end
    end
    session.system_prompt = effective
    save(directory .. '/file-tools.json', {mode=mode, baseline=baseline, effective=effective, tools=tools})
    local function snapshot()
        local files = {}
        local function scan(dir, prefix)
            local handle = assert(uv.fs_scandir(dir))
            while true do
                local name, kind = uv.fs_scandir_next(handle)
                if not name then break end
                if name ~= '__pycache__' and name ~= '.pytest_cache' and name ~= '.git' then
                    local relative = prefix .. name
                    if kind == 'directory' then scan(dir .. '/' .. name, relative .. '/')
                    elseif kind == 'file' then files[relative] = read(dir .. '/' .. name) end
                end
            end
        end
        scan(session.cwd, '')
        return files
    end
    local previous, index = snapshot(), 0
    save(directory .. '/file-boundary-0000.json', previous)
    return function(event)
        if not event.result then return end
        index = index + 1
        local current, changed = snapshot(), {}
        for path, body in pairs(previous) do if current[path] ~= body then changed[#changed+1] = path end end
        for path in pairs(current) do if previous[path] == nil then changed[#changed+1] = path end end
        table.sort(changed)
        event.file_changes = changed
        event.file_boundary = index
        save(directory .. string.format('/file-boundary-%04d.json', index), current)
        previous = current
    end
end
return M
