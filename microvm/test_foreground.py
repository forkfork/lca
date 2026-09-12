import fcntl,json,os,pty,select,subprocess,tempfile,termios,time,unittest
from pathlib import Path

class TerminalTests(unittest.TestCase):
 def test_local_animation_input_and_terminal_restore(self):
  master,slave=pty.openpty()
  before=termios.tcgetattr(slave)
  with tempfile.TemporaryDirectory() as tmp:
   commands=Path(tmp)/'commands';commands.touch()
   def terminal():
    os.setsid();fcntl.ioctl(slave,termios.TIOCSCTTY,0)
   read_fd,write_fd=os.pipe();events=os.fdopen(write_fd,'w')
   process=subprocess.Popen(['lua5.5',str(Path(__file__).with_name('foreground.lua').resolve()),str(commands),str(read_fd)],stdin=slave,stdout=slave,stderr=slave,preexec_fn=terminal,pass_fds=(read_fd,),env={**os.environ,'TERM':'xterm-256color'})
   os.close(read_fd)
   output=bytearray()
   def drain(seconds):
    until=time.monotonic()+seconds
    while time.monotonic()<until:
     if select.select([master],[],[],.05)[0]:output.extend(os.read(master,65536))
   try:
    events.write(json.dumps({'type':'state','phase':'running','active':'one'})+'\n');events.flush()
    drain(.5)
    size=len(output);drain(.3)
    self.assertGreater(len(output),size,'local frames continue without remote events: '+output.decode(errors='replace'))
    events.write(json.dumps({'type':'state','phase':'suspending','active':None})+'\n');events.flush()
    os.write(master,b'/status\r');drain(.4)
    self.assertIn('/status',[json.loads(line)['text'] for line in commands.read_text().splitlines()])
    os.write(master,b'/local\r');drain(.4)
    process.wait(timeout=5)
    self.assertEqual(process.returncode,0,output.decode(errors='replace')[-3000:])
    self.assertIn('/local',[json.loads(line)['text'] for line in commands.read_text().splitlines()])
    self.assertEqual(termios.tcgetattr(slave),before,'raw terminal mode must be restored')
   finally:
    if process.poll() is None:process.kill();process.wait()
    events.close();os.close(master);os.close(slave)

 def test_foreground_transport_uses_local_tui(self):
  master,slave=pty.openpty();before=termios.tcgetattr(slave)
  with tempfile.TemporaryDirectory() as tmp:
   code='''
import handoff,json
from pathlib import Path
class Link:
 def __enter__(self):return self
 def __exit__(self,*args):pass
 def _get(self,path):
  return json.dumps({'phase':'idle','session':{'id':'test','messages':[{'role':'user','text':'build it'},{'role':'assistant','text':'recent reply','provider_items':[{'type':'function_call','name':'run'}]}]}}).encode() if path.endswith('state.json') else b'remote output\\n'
handoff.connection=lambda *args:Link()
result=handoff.fg({},Path('marker.json'),{'phase':'remote','vm':{}})
assert result=='local'
print('RETURNED_LOCAL')
'''
   def terminal():os.setsid();fcntl.ioctl(slave,termios.TIOCSCTTY,0)
   process=subprocess.Popen(['python3','-c',code],cwd=tmp,stdin=slave,stdout=slave,stderr=slave,preexec_fn=terminal,
    env={**os.environ,'TERM':'xterm-256color','PYTHONPATH':str(Path(__file__).resolve().parent)})
   output=bytearray();sent=False;deadline=time.monotonic()+8
   try:
    while time.monotonic()<deadline and process.poll() is None:
     if select.select([master],[],[],.1)[0]:output.extend(os.read(master,65536))
     if b'restored history' in output and not sent:os.write(master,b'/local\r');sent=True
    process.wait(timeout=2)
    self.assertEqual(process.returncode,0,output.decode(errors='replace')[-2000:])
    self.assertTrue(sent,'restored river must reach the real terminal')
    self.assertIn(b'recent reply',output)
    self.assertNotIn('☁'.encode(),output)
    self.assertIn(b'remote',output)
    self.assertNotIn(b'remote output',output)
    self.assertEqual(termios.tcgetattr(slave),before)
   finally:
    if process.poll() is None:process.kill();process.wait()
    os.close(master);os.close(slave)

class HistoryTests(unittest.TestCase):
 def test_recent_turns_preserve_tools_but_exclude_internal_messages(self):
  from foreground import recent_turns
  messages=[]
  for n in range(5):
   messages.extend([{'role':'user','text':'task '+str(n)},
    {'role':'assistant','text':'working','provider_items':[{'type':'function_call','name':'run'}]},
    {'role':'user','tool_name':'run','text':'private tool output'},
    {'role':'user','operational_snapshot':True,'text':'internal machine context'},
    {'role':'assistant','text':'done'}])
  turns=recent_turns({'messages':messages,'credentials_path':'not for display'})
  self.assertEqual([t['number'] for t in turns],[3,4,5])
  self.assertEqual(turns[-1]['calls'],1)
  self.assertEqual(turns[-1]['responses'],['working','done'])
  self.assertNotIn('private',json.dumps(turns));self.assertNotIn('internal',json.dumps(turns))
