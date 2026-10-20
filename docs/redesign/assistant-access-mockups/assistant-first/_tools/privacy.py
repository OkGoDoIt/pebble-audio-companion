# Builds the three Privacy states from one template: same structure, only the derived parts change.
import sys
HEAD = '''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=390">
<title>{title}</title>
<link rel="stylesheet" href="tokens.css">
<style>
  .stance .summary {{ font: var(--f-sub-body); color: var(--secondary-body); margin: 8px 0 0; }}
  .path {{ display: grid; grid-template-columns: 1fr 28px 1fr 28px 1.3fr; align-items: start; margin: 14px 0 2px; }}
  .node {{ display: flex; flex-direction: column; align-items: center; gap: 5px; text-align: center; }}
  .node .lbl {{ font: 600 12px/15px var(--font); color: var(--label); }}
  .node .sub {{ font: 400 11px/13px var(--font); color: var(--meta-ink); }}
  .node .tile {{ width: 40px; height: 40px; border-radius: 10px; }}
  .node .hollow {{ width: 40px; height: 40px; border-radius: 10px; box-shadow: inset 0 0 0 1.5px var(--chevron); background: repeating-linear-gradient(135deg, transparent 0 5px, var(--track) 5px 6px); }}
  .node .marks-stack {{ height: 40px; align-items: center; }}
  .node .marks-stack .mark {{ width: 34px; height: 34px; }}
  .wire {{ height: 2px; margin-top: 19px; border-radius: 1px; background: var(--tint); position: relative; }}
  .wire.off {{ background: none; border-top: 2px dashed var(--chevron); height: 0; }}
  .wire::after {{ content: ""; position: absolute; right: -1px; top: -4px; border: 5px solid transparent; border-left: 6px solid var(--tint); border-right: 0; }}
  .wire.off::after {{ display: none; }}
  .commit .row {{ font: var(--f-footnote); color: var(--secondary-body); padding: 12px 0; }}
</style></head>
<body><div class="phone">
  <div class="statusbar"></div>
  <div class="navbar"><button class="glass-btn" aria-label="Back to Settings"><i data-i="chevL"></i></button><span class="nav-title">Privacy</span></div>
  <div class="content">
    <div class="card stance">
      <div class="state-head"><span class="dot {dot}"></span>{headline}</div>
      <p class="summary">{summary}</p>
      {path}
    </div>
    <div class="list-card">
      <div class="row"><span class="t" style="white-space:nowrap">Siri &amp; Spotlight can see</span><span class="v" style="flex:1;white-space:normal;text-align:right">Titles and summaries</span><i data-i="chevR"></i></div>
      <div class="row"><span class="t" style="flex:1">Assistants can see</span><span class="v">{assistants}</span><i data-i="chevR"></i></div>
    </div>
    {deletion}
    <div class="section-header">Privacy</div>
    <div class="list-card commit">
{commitments}
    </div>
  </div>
  <div class="tabbar" data-on="settings"></div>
</div>
<script src="chrome.js"></script>
</body></html>
'''
PHONE = '<div class="node"><span class="tile good"><i data-i="lockPhone"></i></span><span class="lbl">This iPhone</span><span class="sub">Audio and text</span></div>'
SERVER = '<div class="node"><span class="tile"><i data-i="server"></i></span><span class="lbl">Your server</span><span class="sub">Text only</span></div>'
NOBODY = '<div class="node"><span class="hollow"></span><span class="lbl" style="color:var(--meta-ink)">Assistants</span><span class="sub">None yet</span></div>'
READERS = '<div class="node"><span class="marks-stack"><span class="mark" data-m="chatgpt"></span><span class="mark" data-m="claude"></span></span><span class="lbl">Assistants</span><span class="sub">ChatGPT, Claude</span></div>'
def path(*parts):
    return '<div class="path" aria-hidden="true">' + ''.join(parts) + '</div>'

LOCAL_COMMITS = [
 "This app has no account and no server of its own. Nothing you record, transcribe, or write is sent to its developer, and none of it is used for training, advertising, or profiling.",
 "Your recordings and transcripts are never sold or shared. They go only where this screen says they go.",
 "Diagnostic logs stay on this phone. They hold no audio and no transcript text, and are only ever shared if you send them yourself from Diagnostics.",
 "Recordings, transcripts, and notes are stored in this app on your iPhone, and are included in the iPhone's usual backups.",
]
LINKED_COMMITS = ["Nothing you record, transcribe, or write is sent to this app's developer, and none of it is used for training, advertising, or profiling. Your server holds a copy of the text because you linked it."] + LOCAL_COMMITS[1:]

def footer(t): return '<p class="footer">%s</p>' % t
SIRI = "The search index is kept on this iPhone by iOS, never on a server."

states = {
 '07a-privacy-local': dict(title='Privacy, on this phone', dot='good', headline='Everything stays on this phone',
   summary='Transcription and AI both run on this iPhone. No recording, transcript, or note is sent to any service.',
   path='', assistants='Off', deletion=footer(SIRI), commits=LOCAL_COMMITS),
 '07b-privacy-server': dict(title='Privacy, text to your server', dot='neutral', headline='Text goes to your server',
   summary='Transcription and AI run on this iPhone, and audio stays here. Text is copied to your server, pebbleaudio.okgodoit.com, and no assistant reads it yet.',
   path=path(PHONE, '<div class="wire"></div>', SERVER, '<div class="wire off"></div>', NOBODY), assistants='None yet',
   deletion=footer(SIRI) + footer('Deleting a conversation here deletes it from your server too. When Keep audio removes a recording, its text stays there.'),
   commits=LINKED_COMMITS),
 '07c-privacy-assistants': dict(title='Privacy, assistants read', dot='neutral', headline='ChatGPT and Claude can read your text',
   summary='Transcription and AI run on this iPhone, and audio stays here. Text is copied to your server, pebbleaudio.okgodoit.com, and ChatGPT and Claude read it there.',
   path=path(PHONE, '<div class="wire"></div>', SERVER, '<div class="wire"></div>', READERS), assistants='ChatGPT, Claude',
   deletion=footer(SIRI) + footer('Deleting a conversation here deletes it from your server too. What ChatGPT and Claude already read is up to OpenAI’s and Anthropic’s own policies.'),
   commits=LINKED_COMMITS),
}
out = sys.argv[1]
for name, st in states.items():
    rows = '\n'.join('      <div class="row">%s</div>' % c for c in st['commits'])
    html = HEAD.format(title=st['title'], dot=st['dot'], headline=st['headline'], summary=st['summary'],
                       path=st['path'], assistants=st['assistants'], deletion=st['deletion'], commitments=rows)
    open('%s/%s.html' % (out, name), 'w').write(html)
