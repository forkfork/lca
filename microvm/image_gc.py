"""GC for one explicitly managed image. No workspace, VM or S3 deletion."""
import json,time
from pathlib import Path
from datetime import datetime

def pages(aws,cfg,command,*args):
 items=[];token=None;seen=set()
 while True:
  page=aws(cfg,command,*args,*(['--next-token',token,'--no-paginate'] if token else ['--no-paginate']))
  items.extend(page.get('items',[]));token=page.get('nextToken')
  if not token:return items
  if token in seen:raise RuntimeError('AWS repeated a pagination token; GC stopped')
  seen.add(token)

def scope(cfg):
 policy=cfg.get('image_gc',{})
 if not cfg.get('image_arn') or policy.get('image_arn')!=cfg['image_arn']:
  raise ValueError('GC requires image_gc.image_arn explicitly identifying the LCA-managed image')
 default=cfg.get('image_version');rollback=policy.get('rollback_version')
 if not default or not rollback:raise ValueError('GC requires a prepared default and an explicitly validated rollback_version')
 return cfg['image_arn'],{default,rollback}

def used(aws,cfg,arn):
 return {v['imageVersion'] for v in pages(aws,cfg,'list-microvms','--image-identifier',arn) if v.get('state')!='TERMINATED'}

def plan(aws,cfg):
 arn,protected=scope(cfg)
 versions=pages(aws,cfg,'list-microvm-image-versions','--image-identifier',arn)
 by_version={v['imageVersion']:v for v in versions}
 for version in protected:
  if version not in by_version or by_version[version]['state']!='SUCCESSFUL' or by_version[version]['status']!='ACTIVE':
   raise ValueError('default and rollback must be successful, active versions; refusing GC')
 cutoff=datetime.fromisoformat(by_version[cfg['image_version']]['createdAt'])
 in_use=used(aws,cfg,arn);keep={};candidates=[]
 for v in versions:
  number=v['imageVersion']
  if v['state']=='DELETED':continue
  reason=('default/rollback' if number in protected else 'in use' if number in in_use else
   'build/deletion in progress or unknown state' if v['state'] not in ('SUCCESSFUL','FAILED') else
   'newer than prepared default' if datetime.fromisoformat(v['createdAt'])>=cutoff else None)
  if reason:keep[number]=reason
  else:candidates.append(number)
 return {'image_arn':arn,'keep':keep,'candidates':candidates}

def collect(aws,cfg,apply=False,emit=print,reload_config=None):
 report=plan(aws,cfg);report['deleted']=[];report['skipped']=[]
 emit(json.dumps(report,indent=2))
 if not apply:return report
 arn=report['image_arn']
 for version in report['candidates']:
  fresh=reload_config() if reload_config else cfg
  if scope(fresh)[0]!=arn:raise RuntimeError('managed image changed during GC; stopped')
  # Replan before each mutation; protect newly selected defaults and new VM users.
  if version not in plan(aws,fresh)['candidates']:
   report['skipped'].append(version);continue
  current=aws(fresh,'get-microvm-image-version','--image-identifier',arn,'--image-version',version)
  was_active=current['status']=='ACTIVE'
  if was_active:
   aws(fresh,'update-microvm-image-version','--image-identifier',arn,'--image-version',version,'--status','INACTIVE')
  # Inactive versions cannot accept new launches. Confirm retirement before checking users again.
  current=aws(fresh,'get-microvm-image-version','--image-identifier',arn,'--image-version',version)
  if current['status']!='INACTIVE':raise RuntimeError('retirement not confirmed; no deletion: '+version)
  fresh=reload_config() if reload_config else cfg
  if scope(fresh)[0]!=arn:raise RuntimeError('managed image changed during GC; stopped with candidate inactive')
  if version in scope(fresh)[1] or version in used(aws,fresh,arn):
   if was_active:aws(fresh,'update-microvm-image-version','--image-identifier',arn,'--image-version',version,'--status','ACTIVE')
   report['skipped'].append(version);emit('Kept '+version+' after usage/config recheck');continue
  aws(fresh,'delete-microvm-image-version','--image-identifier',arn,'--image-version',version)
  deadline=time.monotonic()+120
  while True:
   try:current=aws(fresh,'get-microvm-image-version','--image-identifier',arn,'--image-version',version)
   except RuntimeError as error:
    if '(ResourceNotFoundException)' in str(error):break
    raise
   if current['state']=='DELETED':break
   if current['state']=='DELETE_FAILED' or time.monotonic()>=deadline:
    raise RuntimeError('deletion not confirmed for '+version+'; inspect AWS before retrying')
   time.sleep(1)
  report['deleted'].append(version);emit('Deleted '+version)
 return report

def _run(aws,path,apply,emit):
 if not path.exists():
  emit('GC skipped: MicroVM mode is not configured.');return
 def config():return json.loads(path.read_text())
 cfg=config()
 if not cfg.get('image_gc'):
  emit('GC skipped: image cleanup is not configured.');return
 # Check access before any retirement/deletion. Errors after mutations still fail
 # visibly, so a partial cleanup is never presented as a successful no-op.
 try:plan(aws,cfg)
 except FileNotFoundError:
  emit('GC skipped: AWS CLI is not installed. Local LCA is unaffected.');return
 except RuntimeError as error:
  if any(text in str(error) for text in ('Unable to locate credentials','ExpiredToken','InvalidClientTokenId','UnrecognizedClientException','SSO session','Token has expired','Error loading SSO Token','Partial credentials')):
   emit('GC skipped: AWS credentials are unavailable or expired. Local LCA is unaffected.');return
  raise
 return collect(aws,cfg,apply,emit,reload_config=config)

def run(aws,config_path,apply=False,emit=print,automatic=False):
 import fcntl,os
 path=Path(config_path)
 if not path.exists():return _run(aws,path,apply,emit)
 cfg=json.loads(path.read_text());policy=cfg.get('image_gc',{})
 if not policy:return _run(aws,path,apply,emit)
 if automatic and policy.get('automatic',True) is False:return
 fd=os.open(str(path)+'.gc.lock',os.O_CREAT|os.O_RDWR,0o600)
 with os.fdopen(fd,'w') as lock:
  try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
  except BlockingIOError:
   emit('GC skipped: a cleanup is already running.');return
  stamp=Path(str(path)+'.gc-state.json')
  previous=json.loads(stamp.read_text()) if stamp.exists() else {}
  if automatic and time.time()-previous.get('checked_at',0)<86400:return
  # Rate-limit attempts too: unavailable credentials must not cause a retry on
  # every attachment. Manual gc bypasses the cooldown but shares this lock.
  if apply or automatic:
   temp=Path(str(stamp)+'.tmp')
   with open(temp,'w') as out:json.dump({'checked_at':time.time()},out)
   temp.chmod(0o600);os.replace(temp,stamp)
  return _run(aws,path,apply or automatic,emit)

def schedule(config_path):
 """Best-effort host child, only invoked by remote entry points; no daemon."""
 import os,subprocess,sys
 try:
  path=Path(config_path).resolve()
  if not path.exists():return
  cfg=json.loads(path.read_text());policy=cfg.get('image_gc',{})
  if not policy or policy.get('automatic',True) is False:return
  stamp=Path(str(path)+'.gc-state.json')
  if stamp.exists() and time.time()-json.loads(stamp.read_text()).get('checked_at',0)<86400:return
  fd=os.open(str(path)+'.gc.log',os.O_CREAT|os.O_APPEND|os.O_WRONLY,0o600)
  with os.fdopen(fd,'a') as log:
   subprocess.Popen([sys.executable,str(Path(__file__).resolve()),'gc','--automatic','--config',str(path)],
    stdin=subprocess.DEVNULL,stdout=log,stderr=log,start_new_session=True,close_fds=True)
 except (OSError,ValueError):
  pass # Maintenance must not interrupt a session.

if __name__=='__main__':
 import argparse,os,subprocess,sys
 os.umask(0o077)
 parser=argparse.ArgumentParser(description=__doc__)
 parser.add_argument('command',choices=['gc'])
 parser.add_argument('--apply',action='store_true')
 parser.add_argument('--automatic',action='store_true',help=argparse.SUPPRESS)
 parser.add_argument('--config',default=os.getenv('LCA_MICROVM_CONFIG',str(Path.home()/'.config/lca/microvm.json')))
 args=parser.parse_args()
 def aws(cfg,*parts):
  result=subprocess.run([cfg.get('aws_cli','aws'),'lambda-microvms',*parts,'--region',cfg.get('region','ap-southeast-2'),'--output','json','--no-cli-pager'],capture_output=True,text=True,timeout=60)
  if result.returncode:raise RuntimeError(result.stderr)
  return json.loads(result.stdout) if result.stdout.strip() else {}
 try:run(aws,args.config,args.apply,automatic=args.automatic)
 except Exception as error:
  print('Image GC stopped: '+str(error),file=sys.stderr);sys.exit(1)
