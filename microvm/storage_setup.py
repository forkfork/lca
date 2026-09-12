"""Provision private recovery storage on first remote use."""
import json,subprocess
from pathlib import Path
from durable import s3
from retention import ensure

def api(cfg,service,*args):
 r=subprocess.run([cfg.get('aws_cli','aws'),service,*args,'--region',cfg.get('region','ap-southeast-2'),'--output','json','--no-cli-pager'],capture_output=True,text=True,timeout=120)
 if r.returncode:raise RuntimeError('Recovery setup: '+r.stderr)
 return json.loads(r.stdout) if r.stdout.strip() else {}

def setup(cfg):
 if cfg.get('checkpoint_bucket'):return cfg
 account=api(cfg,'sts','get-caller-identity')['Account']
 region=cfg.get('region','ap-southeast-2')
 bucket='lca-recovery-'+account+'-'+region
 try:s3(cfg,'head-bucket','--bucket',bucket,'--expected-bucket-owner',account)
 except RuntimeError as error:
  if '404' not in str(error) and 'NoSuchBucket' not in str(error):raise
  args=['--bucket',bucket]
  if region!='us-east-1':args+=['--create-bucket-configuration',json.dumps({'LocationConstraint':region})]
  try:s3(cfg,'create-bucket',*args)
  except RuntimeError as create_error:
   if 'BucketAlreadyOwnedByYou' not in str(create_error):raise
  s3(cfg,'head-bucket','--bucket',bucket,'--expected-bucket-owner',account)
 s3(cfg,'put-public-access-block','--bucket',bucket,'--public-access-block-configuration',json.dumps({k:True for k in ('BlockPublicAcls','IgnorePublicAcls','BlockPublicPolicy','RestrictPublicBuckets')}))
 s3(cfg,'put-bucket-encryption','--bucket',bucket,'--server-side-encryption-configuration',json.dumps({'Rules':[{'ApplyServerSideEncryptionByDefault':{'SSEAlgorithm':'AES256'}}]}))
 ensure(cfg,bucket)
 role=cfg['execution_role_arn']
 parts=role.split(':',5)
 if len(parts)!=6 or parts[4]!=account or not parts[5].startswith('role/'):
  raise ValueError('Recovery execution role must belong to the current AWS account')
 resource='arn:'+parts[1]+':s3:::'+bucket+'/recovery/'
 policy={'Version':'2012-10-17','Statement':[
  {'Effect':'Allow','Action':['s3:GetObject','s3:PutObject'],'Resource':resource+'*'},
  {'Effect':'Allow','Action':['s3:DeleteObject'],'Resource':resource+'*/snapshots/*'}]}
 api(cfg,'iam','put-role-policy','--role-name',role.rsplit('/',1)[-1],'--policy-name','lca-recovery-storage','--policy-document',json.dumps(policy))
 return {**cfg,'checkpoint_bucket':bucket}

def configure(path):
 from handoff import atomic
 path=Path(path);cfg=json.loads(path.read_text());updated=setup(cfg)
 if updated!=cfg:atomic(path,updated)
 return updated
