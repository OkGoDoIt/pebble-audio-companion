#!/usr/bin/env python3
"""Local widget review with illustrative data, no archive or credentials.
Run: python3 server/tools/preview-widgets.py [--port 5099] [--before /path/to/wwwroot]
"""
import argparse
import json
import io
import wave
import re
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

ROOT = Path(__file__).resolve().parents[1] / 'src/PebbleAudio.Server/wwwroot'
OVERVIEW = ('The speaker asked for careful review of database optimization tradeoffs, logs, recent functionality, '
            'battery use, and reliability issues, and requested a smart alarm for about 11 AM. They also asked '
            'about recent heart-rate and walking data and requested nightly walking updates.')
# The visible portion of Roger's screenshot, paraphrased to end naturally; the hidden text is not known.
C = dict(found=True, id='preview', day='2026-10-21', title='App Review and Pebble Feature Follow-Ups',
         startedAt='2026-10-21T03:40:00+07:00', endedAt='2026-10-21T04:12:00+07:00', minutes=32,
         timeZone='Asia/Ho_Chi_Minh', overview=OVERVIEW, tags=['health', 'Pebble Watch', 'reminders', 'software'],
         people=[], followUps=[], quietMinutes=19, lostMinutes=.4, url='https://example.invalid/conversation',
         gaps=[dict(kind='quiet', startedAt=f'2026-10-21T{a}:00+07:00', endedAt=f'2026-10-21T{b}:00+07:00')
               for a,b in [('03:40','03:41'), ('03:42','03:45'), ('03:49','04:02'), ('04:06','04:08')]] )
C['gaps'].append(dict(kind='lost', startedAt='2026-10-21T04:05:00+07:00', endedAt='2026-10-21T04:05:24+07:00', minutes=.4))
LONG = OVERVIEW + '\n\n' + ('This is illustrative long-summary text for checking expansion, wrapping, and keyboard access. ' * 14)
SECOND = dict(C, id='preview-2', title='Choosing a weekend walking route', overview=LONG[:399]+'…',
              startedAt='2026-10-21T08:20:00+07:00', endedAt='2026-10-21T08:45:00+07:00', minutes=25, lostMinutes=0)
DAY = dict(found=True, day=C['day'], timeZone=C['timeZone'], weekday='Wednesday', recap=dict(headline='App ideas and plans for the week'),
           conversations=[dict(C, overview=LONG[:399]+'…'), SECOND], url='https://example.invalid/day',
           coverage=dict(recordedMinutes=38, lostMinutes=.4, spans=[dict(kind='recorded', startedAt=C['startedAt'], endedAt=C['endedAt']),
             dict(kind='off', startedAt=C['endedAt'], endedAt=SECOND['startedAt']),
             dict(kind='recorded', startedAt=SECOND['startedAt'], endedAt=SECOND['endedAt'])]))
DAYS = dict(from_='2026-10-15', to='2026-10-21', days=[dict(day=f'2026-10-{n}', headline='Plans and conversations',
            lineSummary=OVERVIEW, conversationCount=4, recordedMinutes=65+n, quietMinutes=14, lostMinutes=.4 if n==21 else 0,
            url='https://example.invalid/day') for n in range(15,22)])
DAYS['from']=DAYS.pop('from_')
CLIP = dict(status='requested', conversationId='preview', title=C['title'], startedAt=C['startedAt'],
            endedAt=C['endedAt'], timeZone=C['timeZone'], url=C['url'])

def compose(root, name):
    def include(match):
        path=match[1]
        text=(root/path).read_text()
        if path.endswith('.js'):
            text=re.sub(r'^import[^\n]*;\s*\n', '', text, flags=re.M)
            text=re.sub(r'^export\s+(?=(?:async\s+)?(?:function|const|let|class)\b)', '', text, flags=re.M)
        return text
    return re.sub(r'^[ \t]*(?:/\*|//)[ \t]*@include[ \t]+([\w./-]+)[ \t]*(?:\*/)?[ \t]*$', include,
                  (root/'widgets'/f'{name}.html').read_text(), flags=re.M)

PAGE='''<!doctype html><html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Pebble Audio · Widget review</title><style>
body{font:15px/1.5 system-ui;margin:0;background:#f5f5f7;color:#202024}header{padding:20px 24px}h1{font-size:22px;margin:0}p{margin:4px 0 16px;color:#626269}
nav{display:flex;gap:12px;flex-wrap:wrap}label{display:grid;gap:4px;font-size:13px}select{padding:8px;font:inherit}main{padding:0 20px 30px;overflow:auto}
iframe{border:0;display:block;margin:0 auto;min-height:150px}#status{font-size:13px;margin:10px 0}body.dark{background:#121214;color:#eee}body.dark p{color:#aaa}
</style><header><h1>Pebble Audio · Widget review</h1><p>Current widget code with a simulated host. “Local saved result” uses private captured data; other samples are illustrative.</p>
<nav><label>Widget<select id="widget"><option value="conversation-card">Conversation</option><option value="day-timeline">Day timeline</option><option value="clip-player">Clip player</option></select></label>
<label>Width<select id="width"><option>375</option><option selected>768</option><option>1100</option><option>320</option></select></label>
<label>Theme<select id="theme"><option>light</option><option>dark</option></select></label>
<label>Content<select id="scenario"><option value="normal">Typical</option><option value="long">Long summary</option><option value="days">Several days</option><option value="dense">Dense day coverage</option><option value="live">Local saved result</option><option value="legacy">Legacy transcript result</option><option value="empty">Empty</option><option value="error">Tool unavailable</option><option value="ready">Ready clip (silent sample)</option></select></label>
<label>Version<select id="version"><option value="current">Proposed</option><option value="before">Before</option></select></label></nav><div id="status" role="status">Ready</div></header><main><iframe title="Widget preview"></iframe></main>
<script>
const frame=document.querySelector('iframe');
function refresh(){const params=new URLSearchParams();document.querySelectorAll('select').forEach(s=>params.set(s.id,s.value));frame.style.width=document.querySelector('#width').value+'px';document.body.classList.toggle('dark',document.querySelector('#theme').value==='dark');frame.src='/widget?'+params;}
document.querySelectorAll('select').forEach(s=>s.addEventListener('change',refresh));
window.addEventListener('message',e=>{if(e.source!==frame.contentWindow)return;const m=e.data;if(m.method==='ui/notifications/size-changed')frame.style.height=m.params.height+'px';if(m.previewOpen)document.querySelector('#status').textContent='Open link: '+m.previewOpen;if(m.previewError)document.querySelector('#status').textContent='ERROR: '+m.previewError;if(m.method==='ui/initialize')frame.contentWindow.postMessage({jsonrpc:'2.0',id:m.id,result:{hostContext:{theme:document.querySelector('#theme').value}}},'*');});refresh();
</script></html>'''

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        u=urlparse(self.path)
        if u.path=='/sample.wav':
            buffer=io.BytesIO()
            with wave.open(buffer, 'wb') as audio:
                audio.setnchannels(1); audio.setsampwidth(2); audio.setframerate(8000); audio.writeframes(bytes(30*8000*2))
            self.send_response(200); self.send_header('Content-Type','audio/wav'); self.end_headers(); self.wfile.write(buffer.getvalue()); return
        if u.path=='/favicon.ico': self.send_response(204); self.end_headers(); return
        if u.path=='/': body=PAGE if args.before else PAGE.replace('<option value="before">Before</option>', '')
        elif u.path=='/widget':
            q={k:v[0] for k,v in parse_qs(u.query).items()}
            name=q.get('widget','conversation-card')
            if name not in ('conversation-card','day-timeline','clip-player'): self.send_error(404); return
            root=Path(args.before) if q.get('version')=='before' and args.before else ROOT
            data={'conversation-card':C,'day-timeline':DAY,'clip-player':CLIP}[name].copy()
            scenario=q.get('scenario')
            meta={}
            fixtures=json.loads(Path(args.fixtures).read_text()) if args.fixtures else {}
            if scenario in ('live','legacy'): data=fixtures.get(name,data).copy()
            if scenario=='legacy': data.pop('overview',None)
            if scenario=='ready' and name=='clip-player':
                data=dict(CLIP, status='ready', title='Preview clip · silent sample', endedAt='2026-10-21T03:40:30+07:00')
                meta={'pebbleaudio/audio':{'url':'http://localhost:'+str(args.port)+'/sample.wav'}}
            if scenario=='long': data['overview']=LONG
            if scenario=='days' and name=='day-timeline': data=DAYS
            if scenario=='dense' and name=='day-timeline': data=dict(DAY, coverage=dict(DAY['coverage'], spans=[], spansOmitted=True), truncated=True)
            if scenario=='empty': data=dict(found=False, status='unavailable', reason='notFound', summary='No conversation was found.', day=C['day'])
            if scenario=='empty' and name=='day-timeline': data=dict(DAY, recap=None, conversations=[], coverage={'spans':[]})
            boot='''<script>
window.addEventListener('error',e=>parent.postMessage({previewError:e.message},'*'));
window.addEventListener('unhandledrejection',e=>parent.postMessage({previewError:String(e.reason)},'*'));
window.openai={toolOutput:DATA,toolResponseMetadata:META,theme:THEME,notifyIntrinsicHeight:h=>parent.postMessage({method:'ui/notifications/size-changed',params:{height:h}},'*'),openExternal:({href})=>parent.postMessage({previewOpen:href},'*'),callTool:async(name)=>{if(ERROR)throw Error('Preview unavailable');if(name==='get_audio')return {structuredContent:CLIP};return {structuredContent:{found:true,overview:OVERVIEW_RESULT,transcript:{items:[{kind:'turn',at:'2026-10-21T03:40:00+07:00',speaker:'1',text:'Could we make the summary easier to read?'},{kind:'turn',at:'2026-10-21T03:40:10+07:00',speaker:'2',text:'Yes. Give the description more room and label the times.'},{kind:'turn',at:'2026-10-21T03:40:20+07:00',speaker:'1',text:'Keep the recording details quiet and secondary.'}]}}};}};
</script>'''.replace('DATA',json.dumps(data)).replace('META',json.dumps(meta)).replace('THEME',json.dumps(q.get('theme','light'))).replace('ERROR',str(scenario=='error').lower()).replace('CLIP',json.dumps(CLIP)).replace('OVERVIEW_RESULT',json.dumps(fixtures.get('conversation-card',{}).get('overview',LONG) if scenario in ('live','legacy') else LONG))
            body=compose(root,name).replace('<script type="module">',boot+'<script type="module">')
        else: self.send_error(404); return
        self.send_response(200); self.send_header('Content-Type','text/html; charset=utf-8'); self.end_headers(); self.wfile.write(body.encode())

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__); parser.add_argument('--port',type=int,default=5099); parser.add_argument('--before'); parser.add_argument('--fixtures',help='Local JSON results for private review; never committed'); args=parser.parse_args()
    print(f'Widget review: http://localhost:{args.port}',flush=True)
    HTTPServer(('127.0.0.1',args.port),Handler).serve_forever()
