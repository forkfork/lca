import json,os,tempfile,unittest
from pathlib import Path
from unittest.mock import MagicMock,patch
import handoff

class CloudTests(unittest.TestCase):
 def test_attach_only_after_successful_handoff(self):
  for attach in (False,True):
   with self.subTest(attach=attach),tempfile.TemporaryDirectory() as tmp:
    previous=os.getcwd();os.chdir(tmp)
    try:
     marker=Path(tmp)/'.lca-handoff.json';handoff.atomic(marker,{'phase':'remote','config':{}})
     argv=['handoff','background','--checkpoint','checkpoint']+(['--attach'] if attach else [])
     with patch('sys.argv',argv),patch('first_run.configure',return_value={}),patch('handoff.background') as bg,patch('image_gc.schedule'),patch('handoff.fg',return_value='local') as fg,patch('handoff.go_local') as local:
      handoff.main();bg.assert_called_once()
      self.assertEqual(fg.call_count,int(attach));self.assertEqual(local.call_count,int(attach))
    finally:os.chdir(previous)
 def test_failed_handoff_never_attaches(self):
  with patch('sys.argv',['handoff','background','--checkpoint','checkpoint','--attach']),patch('first_run.configure',return_value={}),patch('handoff.background',side_effect=RuntimeError('failed')),patch('handoff.fg') as fg:
   with self.assertRaises(RuntimeError):handoff.main()
   fg.assert_not_called()
 def test_remote_background_detaches_without_publishing_input(self):
  for command in ('/bg','/background','/cloud'):
   with self.subTest(command=command):
    ui=MagicMock();ui.readline.side_effect=[command,'/detach']
    link=MagicMock();link._get.side_effect=lambda path:json.dumps({'phase':'idle'}).encode() if path.endswith('state.json') else b''
    with patch('handoff.Foreground') as view,patch('handoff.connection') as connection,patch('handoff.aws') as aws:
     view.return_value.__enter__.return_value=ui;connection.return_value.__enter__.return_value=link
     self.assertIsNone(handoff.fg({},Path('unused'),{'phase':'remote'}))
     link.put.assert_not_called();aws.assert_not_called()
