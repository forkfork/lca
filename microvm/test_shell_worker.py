import json,os,subprocess,tempfile,time,unittest
from pathlib import Path
class ShellWorkerTests(unittest.TestCase):
 def test_real_worker_runs_bang_queue_without_model(self):
  worker=Path(__file__).with_name('worker.lua').resolve()
  with tempfile.TemporaryDirectory() as tmp:
   root=Path(tmp);(root/'project').mkdir();(root/'inbox').mkdir();(root/'commit').touch()
   # No model credentials: the complete worker loop must handle both commands directly.
   checkpoint={'id':'shell-test','cwd':str(root/'project'),'model':'gpt-6-astra','messages':[],
    'pending_inputs':['!printf first > marker; exit 7','!cat marker; printf second >> marker']}
   (root/'checkpoint.json').write_text(json.dumps(checkpoint))
   with (root/'log').open('w') as log:
    process=subprocess.Popen(['lua5.5',str(worker),str(root)],stdout=log,stderr=log)
    try:
     deadline=time.monotonic()+15;state={}
     while time.monotonic()<deadline and process.poll() is None:
      try:state=json.loads((root/'state.json').read_text())
      except FileNotFoundError:pass
      if len(state.get('completed',{}))==2:break
      time.sleep(.05)
     self.assertEqual(len(state.get('completed',{})),2,(root/'log').read_text())
     self.assertTrue(state['capabilities']['shell_commands'])
     self.assertEqual((root/'project'/'marker').read_text(),'firstsecond')
     self.assertIn('exit 7',(root/'log').read_text())
     self.assertEqual(sum(bool(m.get('shell_result')) for m in state['session']['messages']),2)
     (root/'stop').touch();process.wait(timeout=5);self.assertEqual(process.returncode,0)
    finally:
     if process.poll() is None:process.kill();process.wait()

 def test_old_worker_rejects_bang_before_submission(self):
  from unittest.mock import patch,MagicMock
  from handoff import fg
  ui=MagicMock();ui.readline.side_effect=['!ls\n','/detach\n']
  link=MagicMock();link._get.side_effect=lambda p:b'{"phase":"idle"}' if p.endswith('state.json') else b''
  with tempfile.TemporaryDirectory() as tmp:
   with patch('handoff.Foreground') as view,patch('handoff.connection') as connection:
    view.return_value.__enter__.return_value=ui;connection.return_value.__enter__.return_value=link
    fg({},Path(tmp)/'marker',{'phase':'remote','vm':{}})
   link.put.assert_not_called()
   self.assertTrue(any('predates' in c.args[0] for c in ui.notice.call_args_list))

 def test_shell_history_is_rendered_as_command_result(self):
  from foreground import recent_turns
  turns=recent_turns({'messages':[{'role':'user','text':'!ls'},
   {'role':'user','shell_result':True,'text':'marker\nexit 0'}]})
  self.assertEqual(len(turns),1);self.assertTrue(turns[0]['shell'])
  self.assertEqual(turns[0]['responses'],['marker\nexit 0'])
