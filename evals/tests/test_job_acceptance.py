import hashlib,json,shutil,subprocess,sys,tempfile,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from job_acceptance import grade,ROOT

class AcceptanceGraders(unittest.TestCase):
 def artifact(self,p,name):
  shutil.copytree(ROOT/'scenarios'/name/'fixture',p,dirs_exist_ok=True)
  failure=name=='job_failure_recovery';source='inventory.py' if failure else 'labels.py'
  (p/source).write_text("def available(stock,reserved):\n return max(0,stock-reserved)\n" if failure else "def label(value):\n return 'id: '+value.strip().lower()\n")
  commands=json.loads((ROOT/'scenarios'/name/'commands.json').read_text())
  events=[]
  def job(i,cmd,code):
   d=p/'.lca/jobs'/f'job_{i}';d.mkdir(parents=True)
   (d/'job.json').write_text(json.dumps({'id':f'job_{i}','command':cmd,'status':'exited','exit_code':code}))
  if failure:
   job(1,commands[0],7)
   events.append({'name':'job_wait','args':{'id':'job_1'},'result':{'content':'status: exited\nexit_code: 7\nBUILD ERROR: wrong count'}})
   events.append({'name':'edit','args':{'path':source},'result':{'content':'ok'}})
   job(2,commands[0],0)
   events.append({'name':'job_wait','args':{'id':'job_2'},'result':{'content':'status: exited\nexit_code: 0\nBUILD VERIFIED'}})
   receipts=['.verified.json']
  else:
   for i,cmd in enumerate(commands,1):
    job(i,cmd,0);events.append({'name':'job_start','args':{'command':cmd},'result':{'content':'ok'}})
   events.append({'name':'edit','args':{'path':source},'result':{'content':'ok'}})
   for i,n in enumerate(['alpha','beta'],1):events.append({'name':'job_wait','args':{'id':f'job_{i}'},'result':{'content':f'status: exited\nexit_code: 0\n{n} VERIFIED'}})
   receipts=['.alpha.json','.beta.json']
  for r in receipts:(p/r).write_text(json.dumps({'sha256':hashlib.sha256((p/source).read_bytes()).hexdigest(),'passed':True}))
  return {'events':events},source
 def test_good_and_bad_artifacts(self):
  for name in ['job_failure_recovery','job_overlap_edit']:
   with self.subTest(name=name),tempfile.TemporaryDirectory() as tmp:
    p=Path(tmp);t,source=self.artifact(p,name)
    self.assertTrue(grade(p,t,name)['passed'])
    self.assertFalse(grade(p,{'events':[]},name)['passed'])
    (p/source).write_text('broken syntax !')
    self.assertFalse(grade(p,t,name)['hard_gates']['artifact_correct'])
 def test_rejects_missing_receipt_scope_and_abandoned_job(self):
  with tempfile.TemporaryDirectory() as tmp:
   p=Path(tmp);t,_=self.artifact(p,'job_overlap_edit')
   (p/'.alpha.json').unlink();self.assertFalse(grade(p,t,'job_overlap_edit')['passed'])
   (p/'worker.py').write_text('');self.assertFalse(grade(p,t,'job_overlap_edit')['hard_gates']['scope_preserved'])
   f=p/'.lca/jobs/job_1/job.json';j=json.loads(f.read_text());j['status']='running';f.write_text(json.dumps(j))
   self.assertFalse(grade(p,t,'job_overlap_edit')['hard_gates']['no_abandoned_jobs'])
 def test_workers_execute_and_produce_verifiable_receipts(self):
  for name in ['job_failure_recovery','job_overlap_edit']:
   with self.subTest(name=name),tempfile.TemporaryDirectory() as tmp:
    p=Path(tmp);self.artifact(p,name)
    commands=json.loads((ROOT/'scenarios'/name/'commands.json').read_text())
    if name=='job_overlap_edit':(p/'.ready').touch()
    for cmd in commands:
     r=subprocess.run(cmd,shell=True,cwd=p,capture_output=True,text=True,timeout=10)
     self.assertEqual(r.returncode,0,r.stderr);self.assertIn('VERIFIED',r.stdout)
 def test_fresh_formatter_activation_checks_real_wire_content(self):
  from job_results import audit
  with tempfile.TemporaryDirectory() as tmp:
   p=Path(tmp);command=json.loads((ROOT/'scenarios/job_failure_recovery/commands.json').read_text())[0]
   self.assertGreater(len(command),160)
   (p/'run-config.json').write_text(json.dumps({'scenario':{'id':'job_failure_recovery'}}))
   request=p/'request-0001.json';request.write_text(json.dumps({'system_prompt':'same'}))
   body='started job_1\ncommand: '+command[:157]+'...\ncwd: /tmp/task'
   start={'name':'job_start','args':{'command':command},'result':{'content':body,'job':{'id':'job_1','command':command}}}
   trajectory={'job_results':'compact','events':[start]}
   payload=p/'provider-request-0001.json';payload.write_text(json.dumps({'instructions':'same','tools':[],'input':[{'output':body}]}))
   audit(p,'compact',[request],trajectory)
   payload.write_text(json.dumps({'instructions':'same','tools':[],'input':[]}))
   with self.assertRaisesRegex(ValueError,'absent from provider'):
    audit(p,'compact',[request],trajectory)

if __name__=='__main__':unittest.main()
