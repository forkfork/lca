"""One resumable, locked image build on first /bg; prepared images are reused."""
import fcntl,json,os,subprocess,sys,tempfile,time,uuid
from pathlib import Path
from storage_setup import api,setup
from durable import s3

def role(cfg,name,account):
 trust={'Version':'2012-10-17','Statement':[{'Effect':'Allow','Principal':{'Service':'lambda.amazonaws.com'},'Action':['sts:AssumeRole','sts:TagSession'],'Condition':{'StringEquals':{'aws:SourceAccount':account}}}]}
 try:return api(cfg,'iam','get-role','--role-name',name)['Role']['Arn']
 except RuntimeError as error:
  if 'NoSuchEntity' not in str(error):raise
 return api(cfg,'iam','create-role','--role-name',name,'--assume-role-policy-document',json.dumps(trust))['Role']['Arn']

def configure(path,emit=lambda text:print(text,flush=True)):
 from handoff import atomic,aws
 path=Path(path);path.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
 fd=os.open(str(path)+'.setup.lock',os.O_CREAT|os.O_RDWR,0o600)
 with os.fdopen(fd,'w') as lock:
  fcntl.flock(lock,fcntl.LOCK_EX)
  cfg=json.loads(path.read_text()) if path.exists() else {}
  if cfg.get('image_arn'):
   updated=setup(cfg)
   if updated!=cfg:atomic(path,updated)
   return updated
  emit('First cloud handoff: preparing your reusable LCA image. This can take several minutes; future handoffs reuse it and are much faster.')
  cfg.setdefault('region',os.getenv('AWS_REGION') or os.getenv('AWS_DEFAULT_REGION') or 'ap-southeast-2')
  cfg.setdefault('setup_id',uuid.uuid4().hex[:12]);atomic(path,cfg)
  identity=api(cfg,'sts','get-caller-identity');account=identity['Account']
  partition=identity['Arn'].split(':')[1];region=cfg['region']
  name='lca-'+cfg['setup_id'];cfg.setdefault('image_name',name)
  # Random persisted names prevent accidentally taking over unrelated IAM roles.
  if not cfg.get('execution_role_arn'):
   cfg['execution_role_arn']=role(cfg,name+'-run',account);atomic(path,cfg)
  if not cfg.get('build_role_arn'):
   cfg['build_role_arn']=role(cfg,name+'-build',account);atomic(path,cfg)
  cfg=setup(cfg);atomic(path,cfg)
  bucket=cfg['checkpoint_bucket'];base='arn:'+partition
  build_policy={'Version':'2012-10-17','Statement':[
   {'Effect':'Allow','Action':['s3:GetObject'],'Resource':base+':s3:::'+bucket+'/images/*'},
   {'Effect':'Allow','Action':['logs:CreateLogGroup','logs:CreateLogStream','logs:PutLogEvents'],'Resource':base+':logs:'+region+':'+account+':log-group:/aws/lambda/microvms/'+cfg['image_name']+'*'}]}
  api(cfg,'iam','put-role-policy','--role-name',cfg['build_role_arn'].rsplit('/',1)[-1],'--policy-name','lca-image-build','--policy-document',json.dumps(build_policy))
  suspend={'Version':'2012-10-17','Statement':[{'Effect':'Allow','Action':['lambda:SuspendMicrovm'],'Resource':base+':lambda:'+region+':'+account+':microvm-image:'+cfg['image_name']}]}
  api(cfg,'iam','put-role-policy','--role-name',cfg['execution_role_arn'].rsplit('/',1)[-1],'--policy-name','lca-idle-suspend','--policy-document',json.dumps(suspend))
  if not cfg.get('image_build_request'):
   with tempfile.TemporaryDirectory(prefix='lca-image-') as tmp:
    context=Path(tmp)/'context'
    subprocess.run([sys.executable,str(Path(__file__).with_name('package.py')),str(context)],check=True,stdout=subprocess.DEVNULL)
    key='images/'+cfg['setup_id']+'/context.zip'
    s3(cfg,'put-object','--bucket',bucket,'--key',key,'--body',str(context)+'.zip','--server-side-encryption','AES256')
   cfg['image_build_request']={'name':cfg['image_name'],'clientToken':uuid.uuid4().hex,
    'codeArtifact':{'uri':'s3://'+bucket+'/'+key},'buildRoleArn':cfg['build_role_arn'],
    'logging':{'cloudWatch':{'logGroup':'/aws/lambda/microvms/'+cfg['image_name']}},
    'baseImageArn':base+':lambda:'+region+':aws:microvm-image:al2023-1',
    'cpuConfigurations':[{'architecture':'ARM_64'}],'resources':[{'minimumMemoryInMiB':512}],
    'hooks':{'port':9000,'microvmHooks':{'resume':'ENABLED','resumeTimeoutInSeconds':15},'microvmImageHooks':{'ready':'ENABLED','readyTimeoutInSeconds':60}}}
   atomic(path,cfg)
  if not cfg.get('pending_image'):
   # Retry only role-propagation failures with the identical idempotent request.
   for attempt in range(12):
    try:
     built=aws(cfg,'create-microvm-image','--cli-input-json',json.dumps(cfg['image_build_request']));break
    except RuntimeError as error:
     if attempt==11 or not any(x in str(error).lower() for x in ('cannot be assumed','unable to assume','not authorized to assume')):raise
     time.sleep(5)
   cfg['pending_image']={'arn':built['imageArn'],'version':built.get('imageVersion','1.0')};atomic(path,cfg)
  pending=cfg['pending_image'];deadline=time.monotonic()+1800;notice=0
  while time.monotonic()<deadline:
   state=aws(cfg,'get-microvm-image-version','--image-identifier',pending['arn'],'--image-version',pending['version'])
   if state['state']=='SUCCESSFUL' and state.get('status')=='ACTIVE':break
   if 'FAIL' in state['state']:
    diagnostic=Path(str(path)+'.build-failure.json')
    details=aws(cfg,'list-microvm-image-builds','--image-identifier',pending['arn'],'--image-version',pending['version'])
    atomic(diagnostic,{'image':state,'builds':details})
    reasons=sorted({item.get('stateReason','Build failed') for item in details.get('items',[])})
    raise RuntimeError('First image build failed: '+('; '.join(reasons) or state['state'])+'. Details: '+str(diagnostic))
   if time.monotonic()>=notice:
    emit('Preparing first image: '+state['state']+'…');notice=time.monotonic()+30
   time.sleep(5)
  else:raise RuntimeError('Image is still building. Run /bg again to continue waiting; it will reuse this build.')
  cfg['image_arn']=pending['arn'];cfg['image_version']=pending['version']
  cfg['image_gc']={'image_arn':pending['arn'],'rollback_version':pending['version'],'automatic':True}
  cfg.pop('pending_image');cfg.pop('image_build_request');atomic(path,cfg)
  emit('Reusable image ready. Continuing your handoff.')
  return cfg
