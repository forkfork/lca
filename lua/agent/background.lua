-- Portable session checkpoint boundary. Deployment belongs to an external command.
local uv = require('luv')
local json = require('cjson')
local M = {}
local function read(path)
    local f=io.open(path); if not f then return nil end
    local bytes=f:read('*a');f:close()
    local ok,value=pcall(json.decode,bytes);assert(ok,'invalid background state: '..path)
    return value
end
function M.atomic(path,value)
    local tmp=path..'.tmp.'..uv.getpid()..'-'..uv.hrtime()
    local fd=assert(uv.fs_open(tmp,'wx',384))
    local bytes=json.encode(value);local offset=0
    while offset<#bytes do local n=assert(uv.fs_write(fd,bytes:sub(offset+1),offset));assert(n>0);offset=offset+n end
    assert(uv.fs_fsync(fd));assert(uv.fs_close(fd))
    assert(uv.fs_rename(tmp,path))
    local directory=assert(uv.fs_open(path:match("^(.*)/") or ".", "r", 0))
    assert(uv.fs_fsync(directory));assert(uv.fs_close(directory))
end
function M.assert_local(session)
    local state=read(session.cwd..'/.lca-handoff.json')
    assert(not state or state.session_id~=session.id or state.phase=='returned',
        'session is paused or owned remotely; use lca fg, collect, or recover before resuming')
end
function M.save_queue(session,queue)
    M.atomic(session.cwd..'/.lca-queue.json',{session_id=session.id,inputs=queue})
end
function M.load_queue(session)
    local data=read(session.cwd..'/.lca-queue.json')
    return data and data.session_id==session.id and data.inputs or session.pending_inputs or {}
end
function M.command()
    if os.getenv('LCA_BACKGROUND_COMMAND') then return os.getenv('LCA_BACKGROUND_COMMAND') end
    local dir=(arg[0] or ''):match('^(.*)/[^/]+$')
    if dir then
        for _,name in ipairs({'background.lua','lca-background'}) do
            local path=dir..'/'..name;local f=io.open(path)
            if f then f:close();return 'lua5.5 '..require('agent.util.shell').quote(path) end
        end
    end
    return 'lca-background'
end
function M.preflight(config_path)
    config_path = config_path or os.getenv('LCA_MICROVM_CONFIG')
        or ((os.getenv('HOME') or '.')..'/.config/lca/microvm.json')
    local cfg = read(config_path)
    if not (cfg and cfg.image_arn and cfg.execution_role_arn) then
        error('MicroVM mode is not configured; session remains local',0)
    end
end
function M.checkpoint(session,queue)
    M.assert_local(session)
    assert(not read(session.cwd..'/.lca-handoff.json'),'this project already has a handoff; collect or recover it first')
    for _,job in ipairs(require('agent.jobs').list(session.cwd)) do
        assert(job.status~='starting' and not job.alive,'finish or stop background job '..tostring(job.id)..' before handoff')
    end
    local shell=require('agent.util.shell')
    local git='git -C '..shell.quote(session.cwd)
    local pipe=assert(io.popen(git..' rev-parse --show-toplevel 2>/dev/null'))
    local top=pipe:read('*a'):gsub('\n$','');local ok=pipe:close()
    if not ok or top=='' then
        assert(not uv.fs_lstat(session.cwd..'/.git')
            and not os.execute(git..' rev-parse --git-dir >/dev/null 2>&1'),
            'cannot initialize an invalid or bare Git workspace; session remains local')
        assert(os.execute(git..' init -q'), 'could not initialize Git; session remains local')
        top=session.cwd
    end
    assert(uv.fs_realpath(top)==uv.fs_realpath(session.cwd),
        'backgrounding requires starting LCA at the Git repository root; session remains local')
    if not os.execute(git..' rev-parse --verify HEAD >/dev/null 2>&1') then
        -- --only leaves even an existing staged index out of this baseline.
        -- Identity and hook/signing overrides apply only to this synthetic commit.
        assert(os.execute(git..' -c user.name=LCA -c user.email=lca@localhost'
            ..' -c core.hooksPath=/dev/null -c commit.gpgSign=false commit -q'
            ..' --allow-empty --only -m '..shell.quote('Initialize workspace for LCA handoff')),
            'could not create the initial Git commit; session remains local')
    end
    -- A terminal command may only checkpoint between completed agent turns.
    for _,line in ipairs(queue) do assert(type(line)=='string','invalid queued input') end
    session.pending_inputs=queue
    local root=(os.getenv('XDG_STATE_HOME') or ((os.getenv('HOME') or '.')..'/.local/state'))..'/lca/handoffs'
    assert(os.execute('umask 077; mkdir -p '..shell.quote(root)))
    local path=root..'/'..session.id..'-'..tostring(uv.hrtime())..'.json'
    local data=session:serialize();data.version=1
    M.atomic(path,data)
    M.atomic(session.cwd..'/.lca-handoff.json',{session_id=session.id,phase='prepared',checkpoint=path})
    return path
end
return M
