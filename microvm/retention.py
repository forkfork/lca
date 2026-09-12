"""S3 owns backup expiry; no client-side session deletion loop."""
import json
from durable import s3

RULES=[
 {'ID':'lca-recovery-expiry','Status':'Enabled','Filter':{'Prefix':'recovery/'},
  'Expiration':{'Days':31},'NoncurrentVersionExpiration':{'NoncurrentDays':1}},
 {'ID':'lca-recovery-delete-markers','Status':'Enabled','Filter':{'Prefix':'recovery/'},
  'Expiration':{'ExpiredObjectDeleteMarker':True}},
]

def ensure(cfg,bucket):
 try:current=s3(cfg,'get-bucket-lifecycle-configuration','--bucket',bucket)
 except RuntimeError as error:
  if 'NoSuchLifecycleConfiguration' not in str(error):raise
  current={}
 existing=current.get('Rules',[])
 owned={r['ID'] for r in RULES}
 if all(rule in existing for rule in RULES):return
 # PutBucketLifecycleConfiguration replaces the entire configuration. Preserve
 # every unrelated rule and the bucket's existing transition-size behavior.
 merged=[r for r in existing if r.get('ID') not in owned]+RULES
 args=['--bucket',bucket,'--lifecycle-configuration',json.dumps({'Rules':merged})]
 if current.get('TransitionDefaultMinimumObjectSize'):
  args+=['--transition-default-minimum-object-size',current['TransitionDefaultMinimumObjectSize']]
 s3(cfg,'put-bucket-lifecycle-configuration',*args)
 verified=s3(cfg,'get-bucket-lifecycle-configuration','--bucket',bucket)
 if not all(rule in verified.get('Rules',[]) for rule in merged):
  raise RuntimeError('Recovery lifecycle configuration was not confirmed')
