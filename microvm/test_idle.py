import unittest
from unittest.mock import patch
from handoff import ensure_awake
class WakeTests(unittest.TestCase):
 def test_wait_suspend_then_resume_once(self):
  states=iter(['SUSPENDING','SUSPENDED','SUSPENDED','RUNNING']);calls=[]
  def aws(cfg,cmd,*args):
   calls.append(cmd)
   return {'state':next(states)} if cmd=='get-microvm' else {}
  with patch('handoff.aws',side_effect=aws),patch('handoff.time.sleep'):
   ensure_awake({}, {'microvmId':'test'})
  self.assertEqual(calls.count('resume-microvm'),1)
 def test_expired_does_not_relaunch(self):
  with patch('handoff.aws',return_value={'state':'TERMINATED'}) as aws:
   with self.assertRaisesRegex(RuntimeError,'terminated.*lca recover'):ensure_awake({}, {'microvmId':'test'})
   self.assertEqual(aws.call_count,1)
 def test_running_needs_no_resume(self):
  with patch('handoff.aws',return_value={'state':'RUNNING'}) as aws:
   ensure_awake({}, {'microvmId':'test'});self.assertEqual(aws.call_count,1)

class ForegroundTests(unittest.TestCase):
 def test_prompt_saved_before_failed_wake(self):
  import io,json,tempfile
  from pathlib import Path
  from handoff import fg
  class Link:
   def __init__(self,*args):
    if getattr(self,'initialized',False):raise TimeoutError('wake failed')
    self.initialized=True
   def __enter__(self):return self
   def __exit__(self,*args):pass
   def close(self):pass
   def _get(self,path):return b'{"phase":"suspending"}'
  link=Link()
  with tempfile.TemporaryDirectory() as temp:
   marker=Path(temp)/'marker.json';rec={'phase':'remote','vm':{'microvmId':'test'}}
   with patch('handoff.wait_for_suspension'),patch('handoff.connection',return_value=link),patch('handoff.sys.stdin',io.StringIO('preserve my prompt\n')),patch('handoff.select.select',return_value=([True],[],[])):
    with self.assertRaises(TimeoutError):fg({},marker,rec)
   self.assertEqual(json.loads(marker.read_text())['outbox']['item']['text'],'preserve my prompt')

class SuspendTransitionTests(unittest.TestCase):
 def test_waits_without_reopening_ingress(self):
  from handoff import wait_for_suspension
  states=iter([{'state':'RUNNING'},{'state':'SUSPENDING'}])
  with patch('handoff.aws',side_effect=lambda *args:next(states)) as aws,patch('handoff.time.sleep'):
   wait_for_suspension({}, {'microvmId':'test'})
   self.assertEqual(aws.call_count,2)
   self.assertTrue(all(c.args[1]=='get-microvm' for c in aws.call_args_list))
 def test_expiry_during_suspend(self):
  from handoff import wait_for_suspension
  with patch('handoff.aws',return_value={'state':'TERMINATED'}):
   with self.assertRaisesRegex(RuntimeError,'expired'):wait_for_suspension({}, {'microvmId':'test'})

class PublicationWakeTests(unittest.TestCase):
 def test_gate_held_briefly_after_resume_does_not_wait_for_another_suspend(self):
  from handoff import Link,GateBusy,REMOTE
  link=object.__new__(Link);calls=[]
  def command(text):
   calls.append(text)
   if 'publish.lua' in text and sum('publish.lua' in c for c in calls)==1:raise GateBusy('busy')
   return b'RESUMED' if 'resumed.json' in text else b''
  link.command=command
  with patch('handoff.wait_for_suspension') as wait,patch('handoff.time.sleep'):
   link._put(REMOTE+'/inbox/test.json',b'{}')
   wait.assert_not_called()
  self.assertEqual(sum('publish.lua' in c for c in calls),2)
