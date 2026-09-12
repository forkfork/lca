"""Local animated view for the existing shell transport; no guest changes."""
import json, os, select, subprocess, sys, tempfile, time
from pathlib import Path

def recent_turns(session):
 """Display-only projection: never transfer credentials or execute saved tools."""
 turns=[];current=None
 for message in session.get('messages',[]):
  if message.get('operational_snapshot') or message.get('tool_name'):continue
  if message.get('shell_result'):
   if current is not None:current['shell']=True;current['responses'].append(message.get('text',''))
   continue
  if message.get('role')=='user':
   current={'number':len(turns)+1,'prompt':message.get('text',''),'responses':[],'calls':0}
   turns.append(current)
  elif message.get('role')=='assistant' and current is not None:
   current['calls']+=sum(item.get('type')=='function_call' for item in message.get('provider_items',[]))
   if message.get('text'):current['responses'].append(message['text'])
 return turns[-3:]

class Foreground:
 def __enter__(self):
  self.process=None
  if sys.stdin.isatty() and sys.stdout.isatty() and os.getenv('LCA_REMOTE_PLAIN')!='1' and os.getenv('TERM')!='dumb':
   self.temp=tempfile.TemporaryDirectory(prefix='lca-foreground-')
   path=Path(self.temp.name)/'commands.jsonl';path.touch(mode=0o600)
   self.commands=path.open()
   read_fd,write_fd=os.pipe()
   self.events=os.fdopen(write_fd,'w')
   try:
    self.process=subprocess.Popen(['lua5.5',str(Path(__file__).with_suffix('.lua')),str(path),str(read_fd)],pass_fds=(read_fd,))
   except BaseException:
    self.events.close();self.commands.close();self.temp.cleanup();raise
   finally:os.close(read_fd)
  return self
 def event(self,event):
  if self.process:
   if self.process.poll() is not None:return
   try:self.events.write(json.dumps(event)+'\n');self.events.flush()
   except BrokenPipeError:pass
  elif event['type'] in ('output','notice'):
   print(event['text'],end='' if event['type']=='output' else '\n',flush=True)
 def notice(self,text):self.event({'type':'notice','text':text})
 def output(self,text):self.event({'type':'output','text':text})
 def state(self,state):
  backup=state.get('checkpoint',{})
  if backup.get('saved_at') and backup['saved_at']!=getattr(self,'last_backup',None):
   self.notice('Remote checkpoint saved '+time.strftime('%H:%M:%S',time.localtime(backup['saved_at'])))
   self.last_backup=backup['saved_at']
  if state.get('checkpoint_error') and state['checkpoint_error']!=getattr(self,'backup_error',None):
   self.notice('Backup failed; further work paused. '+state['checkpoint_error'])
  self.backup_error=state.get('checkpoint_error')
  if self.process and isinstance(state.get('session'),dict):
   turns=recent_turns(state['session'])
   if turns!=getattr(self,'last_turns',None):
    self.event({'type':'history','turns':turns,'session_id':state['session'].get('id','lca')})
    self.last_turns=turns
  self.event({'type':'state','phase':state['phase'],'active':state.get('active')})
 def readline(self):
  if not self.process:
   return sys.stdin.readline() if select.select([sys.stdin],[],[],1)[0] else None
  until=time.monotonic()+1
  while True:
   offset=self.commands.tell();line=self.commands.readline()
   if line and not line.endswith('\n'):self.commands.seek(offset);line=''
   if line:return json.loads(line)['text']+'\n'
   if self.process.poll() is not None:
    if self.process.returncode:raise RuntimeError('Local remote-session display failed; session remains remote')
    return ''
   if time.monotonic()>=until:return None
   time.sleep(.05)
 def __exit__(self,*args):
  if self.process:
   try:
    try:self.events.close()
    except BrokenPipeError:pass
    self.process.wait(timeout=5)
   finally:
    if self.process.poll() is None:self.process.terminate();self.process.wait()
    self.commands.close();self.temp.cleanup()
