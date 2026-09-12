local script_dir=arg[0]:match('^(.*)/[^/]+$') or '.'
package.path=script_dir..'/../lua/?.lua;'..package.path
pcall(require,'luarocks.loader')
local uv=require('luv')
local bg=require('agent.background')
local sessions=require('agent.session')
local tui=require('agent.tui')
local shell=require('agent.util.shell')
local root=os.tmpname()..'-handoff';assert(uv.fs_mkdir(root,448))
local s=sessions.create({model='gpt-6-astra'});s.cwd=root
local function rejected(message)
    local previous=s.pending_inputs
    local ok,err=pcall(bg.checkpoint,s,{'must not transfer'})
    assert(not ok and tostring(err):find(message,1,true),tostring(err))
    assert(not uv.fs_stat(s.cwd..'/.lca-handoff.json'),'preflight must not fence the session')
    assert(s.pending_inputs==previous,'preflight must not replace queued input')
    assert(pcall(bg.assert_local,s),'session must remain usable locally')
end
local function checkpoint_and_restore()
    local path=bg.checkpoint(s,{})
    assert(uv.fs_unlink(path));assert(uv.fs_unlink(root..'/.lca-handoff.json'))
end
local config_path=root..'/microvm.json'
local function preflight_rejected(config)
    if config then bg.atomic(config_path,config) end
    local ok,err=pcall(bg.preflight,config_path)
    assert(not ok and tostring(err):find('session remains local',1,true))
    assert(not uv.fs_stat(root..'/.lca-handoff.json'))
end
preflight_rejected()
bg.atomic(config_path,{image_arn='image',execution_role_arn='role'})
assert(pcall(bg.preflight,config_path),'bucket selection must be automatic')
bg.atomic(config_path,{image_arn='image',execution_role_arn='role',checkpoint_bucket='bucket'})
assert(pcall(bg.preflight,config_path))
assert(uv.fs_unlink(config_path))
local f=assert(io.open(root..'/project.txt','w'));f:write('project');f:close()
checkpoint_and_restore()
local git='git -C '..shell.quote(root)
assert(shell.capture(git..' ls-tree -r --name-only HEAD')=='','initial commit must be empty')
assert(shell.capture(git..' ls-files --others --exclude-standard'):find('project.txt',1,true))
local head=shell.capture(git..' rev-parse HEAD')
checkpoint_and_restore()
assert(shell.capture(git..' rev-parse HEAD')==head,'existing history must not change')
-- Also preserve staging when the user already initialized Git without committing.
assert(os.execute('rm -rf '..shell.quote(root..'/.git')))
assert(os.execute(git..' init -q && '..git..' add project.txt'))
checkpoint_and_restore()
assert(shell.capture(git..' ls-tree -r --name-only HEAD')=='','staged files must not enter initial commit')
assert(shell.capture(git..' diff --cached --name-only')=='project.txt\n','staging must survive')
assert(uv.fs_mkdir(root..'/nested',448));s.cwd=root..'/nested'
rejected('Git repository root');s.cwd=root
s.pending_inputs={'first','/test true','third'};s.plan={{step='finish',status='pending'}}
s.compaction_summary='remember the migration marker'
assert(s:save(root..'/session.json'))
local restored=sessions.create({model=s.model});restored.cwd=root
assert(restored:load(root..'/session.json'))
assert(restored.pending_inputs[2]=='/test true' and restored.plan[1].step=='finish')
assert(restored.compaction_summary==s.compaction_summary)
bg.save_queue(s,s.pending_inputs);assert(bg.load_queue(s)[3]=='third')
bg.atomic(root..'/.lca-handoff.json',{session_id=s.id,phase='remote'})
assert(not pcall(bg.assert_local,s),'old owner must be fenced')
assert(not pcall(function() restored:load(root..'/session.json') end),'resuming old checkpoint must be fenced')
local other=sessions.create({});other.cwd=root;assert(pcall(bg.assert_local,other),'independent local sessions remain possible')
local app=tui.App.new({})
app.busy=true
app:_handle_action({type='submit',text='first'})
app:_handle_action({type='submit',text='second'})
app:_handle_action({type='submit',text='/background'})
assert(app:next_submission()=='/background','handoff must precede already queued work')
assert(app.submitted[1]=='first' and app.submitted[2]=='second','queued work must not be consumed by handoff')
assert(uv.fs_unlink(root..'/.lca-handoff.json'))
local checkpoint=bg.checkpoint(s,s.pending_inputs)
assert(uv.fs_stat(checkpoint),'valid Git workspace can checkpoint')
assert(not pcall(bg.assert_local,s),'successful checkpoint fences the session')
assert(uv.fs_unlink(checkpoint))
os.execute('rm -rf '..shell.quote(root))
print('background boundary, queue, memory and ownership tests passed')
