import json,unittest
from foreground import Foreground
class LiveTransportTests(unittest.TestCase):
 def viewer(self):
  ui=Foreground();ui.process=object();events=[];ui.event=events.append
  return ui,events
 def test_partial_records_and_utf8_resume_by_byte_offset(self):
  ui,events=self.viewer();records=[{'id':'one','seq':1,'kind':'begin','prompt':'café','number':1},{'id':'one','seq':2,'kind':'finish'}]
  blob=b''.join(json.dumps(r,ensure_ascii=False).encode()+b'\n' for r in records)
  split=blob.index('é'.encode())+1;available=split
  state={'capabilities':{'live_events':True},'live':{'id':'one','complete':False},'session':{'messages':[]},'phase':'running'}
  offsets=[]
  def read(path,offset):offsets.append(offset);return blob[offset:available]
  ui.live(state,read);self.assertFalse(any(e['type']=='live' for e in events))
  available=len(blob);state['live']['complete']=True;ui.live(state,read);ui.live(state,read)
  self.assertEqual(offsets,[0,split]);self.assertEqual([e['event']['seq'] for e in events if e['type']=='live'],[1,2])
 def test_completed_initial_attachment_uses_history_without_replay(self):
  ui,events=self.viewer()
  ui.live({'capabilities':{'live_events':True},'live':{'id':'done','complete':True},'session':{'messages':[{'role':'user','text':'task'},{'role':'assistant','text':'answer'}]}},lambda *_:self.fail('must not replay completed journal'))
  self.assertEqual(events[0]['type'],'history')
 def test_byte_truncated_preview_does_not_break_attachment(self):
  ui,events=self.viewer()
  blob=b'{"id":"one","seq":1,"kind":"token","text":"caf\xc3 [display truncated]"}\n'
  ui.live({'capabilities':{'live_events':True},'live':{'id':'one'}},lambda path,offset:blob[offset:])
  self.assertIn('display truncated',events[0]['event']['text'])
 def test_previous_turn_drained_before_switching_to_new_one(self):
  ui,events=self.viewer()
  def row(id,seq,kind):return json.dumps({'id':id,'seq':seq,'kind':kind,'number':1,'prompt':'task'}).encode()+b'\n'
  old=row('old',1,'begin');new=row('new',1,'begin')
  state={'capabilities':{'live_events':True},'live':{'id':'old'},'session':{'messages':[]}}
  def read(path,offset):return (old if 'old' in path else new)[offset:]
  ui.live(state,read);old+=row('old',2,'finish');state['live']={'id':'new'}
  ui.live(state,read)
  self.assertEqual([(e['event']['id'],e['event']['kind']) for e in events if e['type']=='live'],[('old','begin'),('old','finish'),('new','begin')])
 def test_fast_command_completed_between_polls_is_still_displayed(self):
  ui,events=self.viewer();state={'capabilities':{'live_events':True},'session':{'messages':[]}}
  ui.live(state,lambda *_:self.fail('no journal yet'))
  state['live']={'id':'status','complete':True}
  blob=b''.join(json.dumps({'id':'status','seq':i,'kind':kind}).encode()+b'\n' for i,kind in enumerate(['begin','command_output','finish'],1))
  ui.live(state,lambda path,offset:blob[offset:])
  self.assertEqual([e['event']['kind'] for e in events if e['type']=='live'],['begin','command_output','finish'])
 def test_unavailable_journal_falls_back_to_completed_history(self):
  ui,events=self.viewer();state={'capabilities':{'live_events':True},'live':{'id':'missing'},'phase':'running','session':{'messages':[]}}
  def missing(*_):raise RuntimeError('file disappeared')
  ui.live(state,missing)
  self.assertTrue(ui.live_stream['finished']);self.assertTrue(any(e['type']=='live_reset' for e in events))
  state.update(phase='idle',session={'messages':[{'role':'user','text':'task'},{'role':'assistant','text':'done'}]})
  ui.state(state)
  self.assertEqual([e for e in events if e['type']=='history'][-1]['turns'][0]['responses'],['done'])
