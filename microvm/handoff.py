#!/usr/bin/env python3
"""Experimental whole-session handoff over AWS shell ingress. Host Python only."""
import argparse, base64, json, os, select, shlex, subprocess, sys, tarfile, tempfile, time, uuid
from pathlib import Path
from websockets.sync.client import connect
from websockets.exceptions import ConnectionClosed
from workspace import snapshot, extract_proof
from foreground import Foreground

REMOTE='/tmp/lca-handoff'
DEFAULT_DURATION=8*60*60
MAX_DURATION=8*60*60

def duration(cfg):
    seconds=cfg.get('maximum_duration',DEFAULT_DURATION)
    if not isinstance(seconds,int) or isinstance(seconds,bool) or not 1<=seconds<=MAX_DURATION:
        raise ValueError('AWS MicroVM lifetime must be 1–28800 seconds (8 hours); 24 hours is not supported')
    return seconds

def expiry(rec):
    if not rec.get('expires_at'):return 'Expiry not recorded for this older session.'
    left=max(0,int(rec['expires_at']-time.time()))
    return 'VM expires in %dh %dm; bring it local before expiry.'%(left//3600,(left%3600)//60)

def atomic(path,data):
    path=Path(path)
    fd,name=tempfile.mkstemp(prefix='.'+path.name+'-',dir=path.parent)
    try:
        with os.fdopen(fd,'w') as out:
            json.dump(data,out);out.flush();os.fsync(out.fileno())
        os.replace(name,path)
        directory=os.open(path.parent,os.O_RDONLY)
        try:os.fsync(directory)
        finally:os.close(directory)
    finally:
        if os.path.exists(name):os.unlink(name)
def aws(cfg,*args):
    r=subprocess.run([cfg.get('aws_cli','aws'),'lambda-microvms',*args,'--region',cfg.get('region','ap-southeast-2'),'--output','json','--no-cli-pager'],capture_output=True,text=True,timeout=60)
    if r.returncode:raise RuntimeError(r.stderr)
    return json.loads(r.stdout) if r.stdout.strip() else {}
def ensure_awake(cfg,vm):
    deadline=time.monotonic()+90
    requested=False
    while time.monotonic()<deadline:
        details=aws(cfg,'get-microvm','--microvm-identifier',vm['microvmId']);state=details['state']
        if state=='RUNNING':return
        if state in ('TERMINATING','TERMINATED'):
            raise RuntimeError('MicroVM '+state.lower()+': '+str(details.get('stateReason','reason unavailable'))+'. Run lca recover to inspect saved recovery state.')
        if state=='SUSPENDED' and not requested:
            print('Waking MicroVM…',flush=True)
            aws(cfg,'resume-microvm','--microvm-identifier',vm['microvmId']);requested=True
        time.sleep(.5)
    raise RuntimeError('MicroVM did not resume; retry without resubmitting work')

def wait_for_suspension(cfg,vm):
    # Do not reopen shell ingress while the worker's suspend request is draining it.
    deadline=time.monotonic()+60
    while time.monotonic()<deadline:
        state=aws(cfg,'get-microvm','--microvm-identifier',vm['microvmId'])['state']
        if state in ('SUSPENDING','SUSPENDED'):return
        if state in ('TERMINATING','TERMINATED'):raise RuntimeError('MicroVM expired during suspension')
        time.sleep(.5)
    raise RuntimeError('Suspension did not complete; pending input is retained. Retry lca fg to inspect the worker.')

class GateBusy(RuntimeError):pass

class Link:
    def __init__(self,cfg,vm):
        self.cfg=cfg;self.vm=vm
        for attempt in range(3):
            ensure_awake(cfg,vm)
            try:
                token=aws(cfg,'create-microvm-shell-auth-token','--microvm-identifier',vm['microvmId'],'--expiration-in-minutes','15')['authToken']['X-aws-proxy-auth']
                self.ws=connect('wss://'+vm['endpoint']+'/shell',subprotocols=['lambda-microvms.authentication.'+token,'lambda-microvms','lambda-microvms.port.8022'],compression=None,max_size=16*1024*1024,open_timeout=15)
                self.until(b'$ ',timeout=15)
                self.command('export HISTFILE=/dev/null; set +o history; stty -echo')
                self.command('if test -d '+REMOTE+'; then touch '+REMOTE+'/activity; fi')
                return
            except (ConnectionClosed,TimeoutError,OSError):
                if hasattr(self,'ws'):self.ws.close()
                if attempt==2:raise
                time.sleep(.5)
    def until(self,marker,timeout=60):
        data=b'';deadline=time.monotonic()+timeout
        while marker not in data:
            chunk=self.ws.recv(timeout=max(.01,deadline-time.monotonic()))
            data+=chunk.encode() if isinstance(chunk,str) else chunk
        return data
    def command(self,command,timeout=60):
        tag=('LCA_'+uuid.uuid4().hex).encode()
        # Marker is emitted on its own line; command echo can never satisfy it.
        self.ws.send((command+"; _lca_rc=$?; printf '\\n"+tag.decode()+":%s\\n' \"$_lca_rc\"\r").encode())
        data=self.until(b'\r\n'+tag+b':',timeout)
        while b'\r\n' not in data.split(b'\r\n'+tag+b':',1)[1]:
            chunk=self.ws.recv(timeout=5);data+=chunk.encode() if isinstance(chunk,str) else chunk
        output,tail=data.split(b'\r\n'+tag+b':',1);code=int(tail.split(b'\r\n',1)[0])
        if code==75:raise GateBusy('MicroVM is entering suspension')
        if code:raise RuntimeError('remote command failed (%d): %s'%(code,output.decode(errors='replace')[-1500:]))
        return output
    def put(self,path,data):
        # File publication is atomic and stable-ID submissions are idempotent.
        for attempt in range(3):
            try:return self._put(path,data)
            except (ConnectionClosed,TimeoutError,OSError):
                self.close()
                if attempt==2:raise
                self.__init__(self.cfg,self.vm)
    def _put(self,path,data):
        target=shlex.quote(path);tmp=shlex.quote(path+'.upload')
        self.command('umask 077; : > '+tmp)
        encoded=base64.b64encode(data).decode()
        for i in range(0,len(encoded),24000):self.command("printf '%s' '"+encoded[i:i+24000]+"' >> "+tmp)
        self.command('base64 -d '+tmp+' > '+target+'.new && rm '+tmp)
        if path.startswith(REMOTE+'/inbox/') or path==REMOTE+'/stop':
            for _ in range(30):
                try:
                    self.command('if test -f /opt/lca-microvm/publish.lua; then lua5.5 /opt/lca-microvm/publish.lua '+shlex.quote(REMOTE)+' '+target+'.new '+target+'; else mv '+target+'.new '+target+'; fi')
                    break
                except GateBusy:
                    resumed=self.command('if test -f '+REMOTE+'/resumed.json; then echo RESUMED; fi')
                    if b'RESUMED' in resumed:
                        time.sleep(.1) # Resume hook ran; let the worker release its gate.
                    else:
                        self.close();wait_for_suspension(self.cfg,self.vm);self.__init__(self.cfg,self.vm)
            else:raise RuntimeError('Suspension gate stayed closed; input remains in local outbox, retry lca fg')
        else:self.command('mv '+target+'.new '+target)
    def get(self,path):
        for attempt in range(3):
            try:return self._get(path)
            except (ConnectionClosed,TimeoutError,OSError):
                self.close()
                if attempt==2:raise
                self.__init__(self.cfg,self.vm)
    def _get(self,path):
        tag='DATA_'+uuid.uuid4().hex
        out=self.command("printf '\\n"+tag+"\\n'; base64 -w0 "+shlex.quote(path)+"; _lca_data_rc=$?; printf '\\nEND_"+tag+"\\n'; test \"$_lca_data_rc\" = 0")
        return base64.b64decode(out.split((tag+'\r\n').encode(),1)[1].split(('\r\nEND_'+tag).encode(),1)[0],validate=True)
    def state(self):return json.loads(self.get(REMOTE+'/state.json'))
    def close(self):self.ws.close()
    def __enter__(self):return self
    def __exit__(self,*_):self.close()
def credentials(link,path):
    data=json.loads(Path(path).expanduser().read_text());data=data.get('providers',{}).get('codex',data)
    assert data.get('access') and data.get('accountId'),'current Codex access credentials required'
    data={k:data[k] for k in ['access','accountId','expires','expiresAt','expiresAtMs'] if k in data};data['provider']='codex'
    link.put(REMOTE+'/credentials.json',json.dumps(data).encode())
def record(project):
    path=Path(project)/'.lca-handoff.json'
    return path,json.loads(path.read_text())
def connection(cfg,rec):return Link(cfg,rec['vm'])
def background(cfg,checkpoint,attach=False):
    lifetime=duration(cfg)
    idle=cfg.get('idle_suspend_seconds',300)
    if not isinstance(idle,int) or isinstance(idle,bool) or idle<1:raise ValueError('idle_suspend_seconds must be a positive integer')
    data=json.loads(Path(checkpoint).read_text());root=Path(data['cwd']).resolve()
    marker,rec=record(root)
    assert rec['phase']=='prepared' and rec['checkpoint']==str(checkpoint) and rec['session_id']==data['id']
    assert cfg.get('image_arn') and cfg.get('execution_role_arn'),'configure image_arn and execution_role_arn'
    # A stable package and manifest are created before provisioning.
    artifact=Path(checkpoint).with_suffix('.workspace')
    snapshot(root,artifact,cfg.get('max_transfer_bytes',100*1024*1024))
    rec['artifact']=str(artifact);rec['config']=cfg;atomic(marker,rec)
    from durable import initial
    rec['durable']=initial(cfg,rec,data,artifact);atomic(marker,rec)
    image=aws(cfg,'get-microvm-image-version','--image-identifier',cfg['image_arn'],'--image-version',cfg.get('image_version','1.0'))
    assert image['state']=='SUCCESSFUL' and image['status']=='ACTIVE','image is not ready'
    assert image.get('hooks',{}).get('microvmHooks',{}).get('resume')=='ENABLED','rebuild the prepared image with the resume hook enabled before backgrounding'
    region=cfg.get('region','ap-southeast-2')
    rec['phase']='launching';atomic(marker,rec)
    vm=aws(cfg,'run-microvm','--client-token',data['id']+'-'+Path(checkpoint).stem[-20:], '--image-identifier',cfg['image_arn'],'--image-version',cfg.get('image_version','1.0'),'--execution-role-arn',cfg['execution_role_arn'],'--ingress-network-connectors',f'arn:aws:lambda:{region}:aws:network-connector:aws-network-connector:SHELL_INGRESS','--egress-network-connectors',f'arn:aws:lambda:{region}:aws:network-connector:aws-network-connector:INTERNET_EGRESS','--maximum-duration-in-seconds',str(lifetime))
    rec['vm']=vm;rec['expires_at']=time.time()+lifetime;rec['phase']='transferring';atomic(marker,rec)
    print('Launched',vm['microvmId'],flush=True)
    with connection(cfg,rec) as link:
        link.command('umask 077; mkdir -p '+REMOTE+'/inbox')
        # No credentials enter the workspace archive or image.
        data['credentials_path']=REMOTE+'/credentials.json'
        link.put(REMOTE+'/checkpoint.json',json.dumps(data).encode())
        with tempfile.NamedTemporaryFile(suffix='.tar') as out:
            with tarfile.open(out.name,'w:gz') as t:
                for name in ['repo.bundle','index.patch','files.tar','manifest.json']:t.add(artifact/name,arcname=name)
            link.put(REMOTE+'/workspace.tgz',Path(out.name).read_bytes())
        manifest=json.loads((artifact/'manifest.json').read_text())
        # Clone only the supplied bundle; no hooks or source Git config are installed.
        link.command('cd '+REMOTE+' && tar xzf workspace.tgz && git clone -q repo.bundle project && cd project && git remote remove origin && git checkout -q --detach '+shlex.quote(manifest['head']))
        if manifest.get('branch'):link.command('cd '+REMOTE+'/project && git checkout -q -B '+shlex.quote(manifest['branch']))
        if (artifact/'index.patch').stat().st_size:link.command('cd '+REMOTE+'/project && git apply --cached ../index.patch')
        deletes=[n for n,e in manifest['files'].items() if e.get('deleted')]
        for n in deletes:link.command('rm -f -- '+shlex.quote(REMOTE+'/project/'+n))
        link.command('cd '+REMOTE+'/project && tar xf ../files.tar')
        # Verify transferred content, including deletions and symlinks, before granting ownership.
        checks=[]
        for n,e in manifest['files'].items():
            f=shlex.quote(n)
            if e.get('deleted'):checks.append('test ! -e '+f+' && test ! -L '+f)
            elif 'link' in e:checks.append('test "$(readlink -- '+f+')" = '+shlex.quote(e['link']))
            else:
                checks.append('test "$(sha256sum < '+f+' | cut -d " " -f1)" = '+shlex.quote(e['sha256']))
                checks.append(('test -x ' if e['executable'] else 'test ! -x ')+f)
        # Script is transferred as data; large workspaces do not exceed a command line.
        link.put(REMOTE+'/verify.sh',('set -e\ncd '+REMOTE+'/project\n'+'\n'.join(checks)+'\n').encode())
        link.command('bash '+REMOTE+'/verify.sh')
        credentials(link,json.loads(Path(checkpoint).read_text())['credentials_path'])
        link.command('test -f /opt/lca-microvm/lifecycle.lua && test -f /opt/lca-microvm/publish.lua')
        link.put(REMOTE+'/storage.json',json.dumps(rec['durable']).encode())
        link.put(REMOTE+'/lifecycle.json',json.dumps({'vm_id':vm['microvmId'],'region':region,'idle_seconds':idle}).encode())
        link.command('test -f /opt/lca-microvm/worker.lua && (nohup timeout '+str(lifetime)+' lua5.5 /opt/lca-microvm/worker.lua '+REMOTE+' > '+REMOTE+'/output.log 2>&1 < /dev/null &)')
        for _ in range(60):
            try:
                state=link.state()
                if state['phase']=='ready':
                    assert state['session_id']==data['id'],'restored wrong session'
                    atomic(artifact/'remote-ready.json',state)
                    break
            except RuntimeError:pass
            time.sleep(.5)
        else:raise RuntimeError('remote worker did not acknowledge restore; use recover')
        assert state.get('capabilities',{}).get('durable_checkpoints'),'prepared image lacks durable backups; update it and use lca recover'
        if any(text.startswith('!') for text in data.get('pending_inputs',[])):
            assert state.get('capabilities',{}).get('shell_commands'),'prepared image predates !command support; update it and use lca recover'
        # Fail closed: local execution is fenced BEFORE the worker can start.
        rec['phase']='remote';atomic(marker,rec)
        link.put(REMOTE+'/commit',b'committed\n')
    print('Session moved to the cloud. Attaching…' if attach else 'Session backgrounded. Use lca fg to reconnect; /local brings it home. '+expiry(rec))
def fg(cfg,marker,rec):
    assert rec['phase']=='remote','session is not remote'
    with Foreground() as ui, connection(cfg,rec) as link:
        cursor=0;dormant=False;state={}
        pending=rec.get('outbox')
        if pending:
            from durable import submit
            submit(cfg,rec,pending)
            link.put(REMOTE+'/inbox/'+pending['name'],json.dumps(pending['item']).encode());rec.pop('outbox');atomic(marker,rec)
        ui.notice('Attached. /local brings this session home; Ctrl-D detaches. '+expiry(rec))
        while True:
            if not dormant:
                try:
                    state=json.loads(link._get(REMOTE+'/state.json'));ui.state(state)
                    if state['phase']=='suspending':dormant=True
                    else:
                        data=link._get(REMOTE+'/output.log')
                        ui.output(data[cursor:].decode(errors='replace'));cursor=len(data)
                        if state['phase'] in ['failed','stopped']:ui.notice('Worker: '+state['phase']+' '+state.get('error',''));return
                except (ConnectionClosed,TimeoutError,OSError):
                    vm_state=aws(cfg,'get-microvm','--microvm-identifier',rec['vm']['microvmId'])['state']
                    if vm_state in ('SUSPENDING','SUSPENDED'):dormant=True
                    else:ui.state({'phase':'reconnecting'});ui.notice('Reconnecting…');link.close();link.__init__(cfg,rec['vm']);continue
                if dormant:
                    link.close() # Release ingress before AWS finishes suspension.
                    ui.state({'phase':'suspending'})
                    ui.notice('MicroVM is sleeping. Enter a prompt to wake it, /local to return, or /detach.')
            line=ui.readline()
            if line is not None:
                if not line or line.strip() in ('/detach','/bg','/background'):ui.notice(expiry(rec));return
                if line.strip()=='/cloud':ui.notice('Already attached to the cloud session.');continue
                if line.strip()=='/local':
                    if dormant:wait_for_suspension(cfg,rec['vm'])
                    return 'local'
                if not line.strip():continue
                if line.startswith('!') and not state.get('capabilities',{}).get('shell_commands'):
                    ui.notice('This VM predates !command support. Use /local, then /bg with the updated image.');continue
                ident=uuid.uuid4().hex;pending={'name':str(time.time_ns())+'-'+ident+'.json','item':{'id':ident,'text':line.rstrip('\n')}}
                rec['outbox']=pending;atomic(marker,rec)
                from durable import submit
                submit(cfg,rec,pending)
                if dormant:ui.state({'phase':'waking'});ui.notice('Waking MicroVM…');link.close();wait_for_suspension(cfg,rec['vm']);link.__init__(cfg,rec['vm']);dormant=False
                link.put(REMOTE+'/inbox/'+pending['name'],json.dumps(pending['item']).encode())
                rec.pop('outbox');atomic(marker,rec)
def collect(cfg,marker,rec,directory):
    assert rec['phase']=='remote','session is not remote'
    assert not Path(directory).exists(),'collect into a new directory; local edits are never overwritten'
    with connection(cfg,rec) as link:
        pending=rec.get('outbox')
        if pending:
            from durable import submit
            submit(cfg,rec,pending)
            link.put(REMOTE+'/inbox/'+pending['name'],json.dumps(pending['item']).encode())
            rec.pop('outbox');atomic(marker,rec)
        link.put(REMOTE+'/stop',b'stop\n')
        for _ in range(600):
            state=link.state()
            if state['phase'] in ['stopped','failed']:break
            time.sleep(1)
        else:raise RuntimeError('worker still busy; collect again later')
        link.command('cd '+REMOTE+' && tar czf proof.tgz project state.json output.log agent.log agent.log.jsonl inbox')
        blob=link.get(REMOTE+'/proof.tgz')
    dest=Path(directory).resolve()
    dest.parent.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory(dir=dest.parent,prefix='.lca-download-') as staging:
        with tempfile.NamedTemporaryFile() as f:
            f.write(blob);f.flush();extract_proof(f.name,Path(staging)/'return')
        os.rename(Path(staging)/'return',dest)
    state=json.loads((dest/'state.json').read_text())
    saved=state['session'];saved['cwd']=str(dest/'project');saved['credentials_path']=json.loads(Path(rec['checkpoint']).read_text())['credentials_path'];saved['system_prompt']=None
    saved['pending_inputs']=[json.loads(f.read_text())['text'] for f in sorted((dest/'inbox').glob('*.json')) if json.loads(f.read_text())['id'] not in state['completed']]
    if state['phase']=='failed':saved['pending_inputs']=[] # Uncertain started work must not replay automatically.
    atomic(dest/'project/.lca-session.json',saved)
    # Keep original owner fenced: resume the returned copy, not the stale local tree.
    rec['phase']='collected';rec['collected']=str(dest);atomic(marker,rec)
    print('Downloaded to',dest,'; resume from its project directory. Original project unchanged.')
def go_local(cfg,marker,rec,resume=True):
    from reconcile import plan, apply, Conflict
    root=marker.parent.resolve()
    returning=Path(rec['checkpoint']).with_suffix('.return')
    transaction=Path(rec['checkpoint']).with_suffix('.return-plan.json')
    if rec['phase']=='remote':
        print('Bringing session home: waiting for the current turn, then downloading…',flush=True)
        if returning.exists():returning=returning.with_name(returning.name+'-'+uuid.uuid4().hex)
        collect(cfg,marker,rec,returning)
    if rec['phase'] in ('collected','conflict'):
        state=json.loads((Path(rec['collected'])/'state.json').read_text())
        if state['phase']=='failed':raise RuntimeError('Remote work failed with an uncertain active input; inspect '+rec['collected']+' before resuming')
        try:
            plan(root,Path(rec['collected'])/'project',rec['artifact'],transaction)
        except Conflict as e:
            rec['phase']='conflict';rec['conflicts']=str(e);atomic(marker,rec)
            raise RuntimeError('Return paused; no local files were changed. '+str(e)+'\nRemote copy: '+rec['collected']+'\nResolve the conflicting local edits, then run lca local again.') from e
        rec['phase']='applying';atomic(marker,rec)
    if rec['phase']=='applying':
        apply(root,json.loads(transaction.read_text()))
        saved=json.loads((Path(rec['collected'])/'project/.lca-session.json').read_text())
        saved['cwd']=str(root);saved['system_prompt']=None
        atomic(root/'.lca-session.json',saved)
        atomic(root/'.lca-queue.json',{'session_id':saved['id'],'inputs':saved.get('pending_inputs',[])})
        rec['phase']='local_ready';atomic(marker,rec)
    if rec['phase']=='local_ready':
        aws(cfg,'terminate-microvm','--microvm-identifier',rec['vm']['microvmId'])
        for _ in range(60):
            if aws(cfg,'get-microvm','--microvm-identifier',rec['vm']['microvmId'])['state']=='TERMINATED':break
            time.sleep(1)
        else:raise RuntimeError('Files are safely local, but VM termination is not confirmed; retry lca local')
        rec['phase']='returned';atomic(marker,rec)
    assert rec['phase']=='returned','session is not ready to return locally'
    atomic(Path(rec['checkpoint']).with_suffix('.completed.json'),rec)
    marker.unlink()
    print('Session is local. Changes reconciled; remote VM terminated.',flush=True)
    if resume:
        saved=json.loads((root/'.lca-session.json').read_text())
        os.chdir(root)
        os.execvp('lca',['lca','--resume',str(root/'.lca-session.json'),'--credentials',saved['credentials_path']])

def stop(cfg,marker,rec,discard=False):
    assert rec['phase']=='collected' or discard,'collect results first, or explicitly use --discard'
    aws(cfg,'terminate-microvm','--microvm-identifier',rec['vm']['microvmId'])
    rec['phase']='terminated';atomic(marker,rec);print('VM termination requested')
def recover(cfg,marker,rec,merge=False):
    if rec['phase'] in ('remote','terminated'):
        from durable import archive_dead,restore
        assert rec.get('vm'),'VM identity missing; reconcile AWS state before recovery'
        vm=aws(cfg,'get-microvm','--microvm-identifier',rec['vm']['microvmId'])
        assert vm['state']=='TERMINATED','VM is not terminated; use lca local to bring it home safely'
        if rec.get('durable'):
            dest,uncertain=restore(cfg,rec,Path(rec['checkpoint']).with_suffix('.recovered-'+uuid.uuid4().hex[:8]))
            print('Recovered workspace and session: '+str(dest/'project'))
            print('Inputs with uncertain effects held for review: '+str(len(uncertain))+'; see '+str(dest/'uncertain-inputs.json'))
            print('Continue there with lca --resume .lca-session.json; /bg can then move the recovered session to a new VM.')
            if merge:
                current=marker.parent/'.lca-session.json'
                assert not current.exists() or json.loads(current.read_text()).get('id')==rec['session_id'],'A newer local conversation exists; use the isolated recovered copy instead of overwriting it'
                rec['phase']='collected';rec['collected']=str(dest);atomic(marker,rec)
                go_local(cfg,marker,rec,resume=False);return
        else:print('This older VM had no durable remote backup. Keeping the surviving local files and session; remote-only changes cannot be restored.')
        archive=archive_dead(marker,rec,vm)
        print('Dead handoff archived at '+str(archive)+'. Local session can continue; no uncertain inputs were replayed.')
        return
    assert rec['phase'] in ['prepared','launching','transferring'],'remote ownership was committed; collect results instead of replaying local work'
    if rec.get('vm'):
        aws(cfg,'terminate-microvm','--microvm-identifier',rec['vm']['microvmId'])
        for _ in range(60):
            if aws(cfg,'get-microvm','--microvm-identifier',rec['vm']['microvmId'])['state']=='TERMINATED':break
            time.sleep(1)
        else:raise RuntimeError('termination not confirmed; local session stays fenced')
    elif rec['phase']=='launching':raise RuntimeError('launch outcome unknown; resolve AWS run request before recovery')
    data=json.loads(Path(rec['checkpoint']).read_text());atomic(marker.parent/'.lca-session.json',data)
    atomic(marker.parent/'.lca-queue.json',{'session_id':data['id'],'inputs':data.get('pending_inputs',[])})
    marker.unlink();print('Local checkpoint restored. Use /resume in LCA.')
def main():
    os.umask(0o077)
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('command',choices=['background','fg','local','collect','stop','recover','gc']);p.add_argument('directory',nargs='?');p.add_argument('--checkpoint');p.add_argument('--attach',action='store_true');p.add_argument('--discard',action='store_true');p.add_argument('--apply',action='store_true');p.add_argument('--merge',action='store_true');p.add_argument('--config',default=os.getenv('LCA_MICROVM_CONFIG',str(Path.home()/'.config/lca/microvm.json')))
    args=p.parse_args()
    if args.command=='gc':
        from image_gc import run as gc
        gc(aws,args.config,apply=args.apply);return
    if args.command=='background':
        from first_run import configure
        try:cfg=configure(args.config)
        except Exception:
            data=json.loads(Path(args.checkpoint).read_text())
            marker,rec=record(Path(data['cwd']))
            if rec['phase']=='prepared' and not rec.get('vm'):recover({},marker,rec)
            raise
        background(cfg,args.checkpoint,attach=args.attach)
        from image_gc import schedule
        schedule(args.config)
        if not args.attach:return
        args.command='fg'
    if args.command=='fg':
        from image_gc import schedule
        schedule(args.config)
    marker,rec=record(Path.cwd());cfg=rec['config'] if 'config' in rec else json.loads(Path(args.config).read_text())
    # One controller at a time; no duplicate concurrent foreground writers/collectors.
    import fcntl
    with open(str(marker)+'.lock','w') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        marker,rec=record(Path.cwd());cfg=rec.get('config',cfg)
        if args.command=='fg':
            if fg(cfg,marker,rec)=='local':go_local(cfg,marker,rec)
        elif args.command=='local':go_local(cfg,marker,rec)
        elif args.command=='collect':collect(cfg,marker,rec,args.directory or 'lca-returned')
        elif args.command=='stop':stop(cfg,marker,rec,args.discard)
        elif args.command=='recover':recover(cfg,marker,rec,merge=args.merge)
if __name__=='__main__':
    try:main()
    except Exception as e:
        # WebSocket handshake diagnostics can contain auth protocols; never print them.
        print('Handoff failed: '+(str(e) if isinstance(e,(AssertionError,ValueError,RuntimeError,FileNotFoundError)) else type(e).__name__),file=sys.stderr);sys.exit(1)
