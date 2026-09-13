"""Local animated view consuming the guest's display journal over shell ingress."""
import json, os, re, select, subprocess, sys, tempfile, time
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
  stream=getattr(self,'live_stream',None)
  if not stream or stream['finished']:self.history(state)
  self.event({'type':'state','phase':state['phase'],'active':state.get('active'),
              'live_events':bool(state.get('capabilities',{}).get('live_events') and state.get('live') and not state['live'].get('error'))})
 def history(self,state):
  if self.process and isinstance(state.get('session'),dict):
   turns=recent_turns(state['session'])
   if turns!=getattr(self,'last_turns',None):
    self.event({'type':'history','turns':turns,'session_id':state['session'].get('id','lca')})
    self.last_turns=turns
 def live(self,state,read):
  if not self.process or not state.get('capabilities',{}).get('live_events'):return
  initial=not getattr(self,'live_initialized',False)
  self.live_initialized=True
  meta=state.get('live')
  if not isinstance(meta,dict) or not re.fullmatch(r'[A-Za-z0-9-]+',meta.get('id','')):return
  stream=getattr(self,'live_stream',None)
  def drain(stream):
   chunk=read('/tmp/lca-handoff/events/'+stream['id']+'.jsonl',stream['offset'])
   stream['offset']+=len(chunk);stream['buffer']+=chunk
   while b'\n' in stream['buffer']:
    line,stream['buffer']=stream['buffer'].split(b'\n',1)
    # Guest display previews are byte-bounded and may end inside a UTF-8 glyph.
    item=json.loads(line.decode('utf-8',errors='replace'))
    if item['id']!=stream['id']:raise RuntimeError('Remote event journal identity changed')
    self.event({'type':'live','event':item})
    if item['kind']=='finish':stream['finished']=True
   if len(stream['buffer'])>262144:raise RuntimeError('Remote display event exceeds size limit')
   return bool(chunk)
  if stream and stream['id']!=meta['id'] and not stream['finished']:
   try:drain(stream)
   except (RuntimeError,ValueError):
    self.event({'type':'live_reset'});self.notice('Older live activity is unavailable; restoring completed history.');stream['finished']=True
   if not stream['finished']:return
  if not stream or stream['id']!=meta['id']:
   if initial:self.history(state)
   stream={'id':meta['id'],'offset':0,'buffer':b'','finished':initial and bool(meta.get('complete'))}
   self.live_stream=stream
  if not stream['finished']:
   try:more=drain(stream)
   except (RuntimeError,ValueError):
    self.event({'type':'live_reset'});self.notice('Live activity is unavailable; completed history will still appear.');stream['finished']=True;return
   if not more and meta.get('complete') and not stream['finished']:
    self.event({'type':'live_reset'});self.notice('Live display interrupted; restoring completed history.');stream['finished']=True
 def readline(self,timeout=1):
  if not self.process:
   return sys.stdin.readline() if select.select([sys.stdin],[],[],timeout)[0] else None
  until=time.monotonic()+timeout
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
