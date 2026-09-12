"""S3 recovery objects. Only complete immutable archives become latest checkpoints."""
import hashlib,json,os,shutil,subprocess,tarfile,tempfile,uuid
from pathlib import Path
from workspace import extract_proof

def s3(cfg,op,*args):
 r=subprocess.run([cfg.get('aws_cli','aws'),'s3api',op,*args,'--region',cfg.get('region','ap-southeast-2'),'--output','json','--no-cli-pager'],capture_output=True,text=True,timeout=120)
 if r.returncode:raise RuntimeError('Checkpoint storage: '+r.stderr)
 return json.loads(r.stdout) if r.stdout.strip() else {}
def put(cfg,store,key,data):
 with tempfile.NamedTemporaryFile() as f:
  f.write(data);f.flush()
  s3(cfg,'put-object','--bucket',store['bucket'],'--key',store['prefix']+'/'+key,'--body',f.name,'--server-side-encryption','AES256')
def get(cfg,store,key):
 with tempfile.NamedTemporaryFile() as f:
  s3(cfg,'get-object','--bucket',store['bucket'],'--key',store['prefix']+'/'+key,f.name)
  return Path(f.name).read_bytes()
def initial(cfg,rec,data,artifact):
 bucket=cfg.get('checkpoint_bucket')
 if not bucket:raise ValueError('Configure checkpoint_bucket before backgrounding; remote sessions require durable backups')
 store={'bucket':bucket,'prefix':'recovery/'+uuid.uuid4().hex,'region':cfg.get('region','ap-southeast-2')}
 from retention import ensure
 ensure(cfg,bucket)
 with tempfile.NamedTemporaryFile() as f:
  with tarfile.open(f.name,'w:gz') as archive:
   for name in ('repo.bundle','index.patch','files.tar','manifest.json'):archive.add(Path(artifact)/name,arcname=name)
  blob=Path(f.name).read_bytes()
 put(cfg,store,'initial.tgz',blob)
 saved=dict(data);saved.pop('credentials_path',None)
 pointer={'format':'initial','key':'initial.tgz','sha256':hashlib.sha256(blob).hexdigest(),'session':saved,'completed':{},'saved_at':__import__('time').time()}
 put(cfg,store,'latest.json',json.dumps(pointer).encode())
 for i,text in enumerate(data.get('pending_inputs',[]),1):
  item={'id':'initial-'+str(i),'text':text};name='000-%06d.json'%i
  put(cfg,store,'inputs/'+name,json.dumps(item).encode())
 return store

def submit(cfg,rec,pending):
 if rec.get('durable'):put(cfg,rec['durable'],'inputs/'+pending['name'],json.dumps(pending['item']).encode())

def archive_dead(marker,rec,vm):
 from handoff import atomic
 root=marker.parent
 archive=Path(rec['checkpoint']).with_suffix('.dead-'+uuid.uuid4().hex[:8]);archive.mkdir(mode=0o700)
 for name in ('.lca-handoff.json','.lca-session.json','.lca-queue.json'):
  if (root/name).exists():shutil.copy2(root/name,archive/name)
 atomic(archive/'termination.json',vm)
 shutil.copy2(rec['checkpoint'],archive/'original-checkpoint.json')
 saved=json.loads((root/'.lca-session.json').read_text()) if (root/'.lca-session.json').exists() else None
 # A newer local conversation belongs to the user; never overwrite it.
 if saved is None or saved.get('id')==rec['session_id']:
  saved=saved or json.loads(Path(rec['checkpoint']).read_text())
  saved['pending_inputs']=[]
  atomic(root/'.lca-session.json',saved)
  atomic(root/'.lca-queue.json',{'session_id':saved['id'],'inputs':[]})
 marker.unlink()
 return archive

def restore(cfg,rec,destination):
 from handoff import atomic
 store=rec['durable'];pointer=json.loads(get(cfg,store,'latest.json'))
 key=pointer['key']
 if not (key=='initial.tgz' or __import__('re').fullmatch(r'snapshots/[A-Za-z0-9-]+\.tgz',key)):raise ValueError('invalid checkpoint object key')
 blob=get(cfg,store,key)
 if hashlib.sha256(blob).hexdigest()!=pointer['sha256']:raise ValueError('checkpoint checksum mismatch')
 dest=Path(destination)
 with tempfile.NamedTemporaryFile() as f:
  f.write(blob);f.flush();extract_proof(f.name,dest)
 if pointer['format']=='initial':
  project=dest/'project'
  subprocess.run(['git','clone','-q',str(dest/'repo.bundle'),str(project)],check=True,capture_output=True)
  subprocess.run(['git','-C',str(project),'remote','remove','origin'],check=True)
  manifest=json.loads((dest/'manifest.json').read_text())
  if manifest.get('branch'):subprocess.run(['git','-C',str(project),'checkout','-q','-B',manifest['branch']],check=True)
  if (dest/'index.patch').stat().st_size:subprocess.run(['git','-C',str(project),'apply','--cached',str(dest/'index.patch')],check=True)
  for name,value in manifest['files'].items():
   if value.get('deleted'):(project/name).unlink(missing_ok=True)
  with tarfile.open(dest/'files.tar') as archive:archive.extractall(project,filter='data')
  state={'session':pointer['session'],'completed':{}}
 else:state=json.loads((dest/'state.json').read_text())
 # Every accepted input has an immutable ID. An attempt marker means uncertain
 # effects unless this checkpoint already includes completion. Never replay it.
 items=s3(cfg,'list-objects-v2','--bucket',store['bucket'],'--prefix',store['prefix']+'/')
 keys={x['Key'] for x in items.get('Contents',[])}
 pending=[];uncertain=[]
 for key in sorted(keys):
  prefix=store['prefix']+'/inputs/'
  if not key.startswith(prefix):continue
  item=json.loads(get(cfg,store,key[len(store['prefix'])+1:]))
  if item['id'] in state.get('completed',{}):continue
  if store['prefix']+'/attempts/'+item['id']+'.json' in keys:uncertain.append(item)
  else:pending.append(item['text'])
 saved=state['session'];saved['cwd']=str((dest/'project').resolve());saved['pending_inputs']=pending;saved['system_prompt']=None
 saved['credentials_path']=json.loads(Path(rec['checkpoint']).read_text()).get('credentials_path')
 state['phase']='stopped';atomic(dest/'state.json',state)
 atomic(dest/'project/.lca-session.json',saved)
 atomic(dest/'project/.lca-queue.json',{'session_id':saved['id'],'inputs':pending})
 atomic(dest/'uncertain-inputs.json',uncertain);atomic(dest/'recovery.json',pointer)
 return dest,uncertain
