# Builds the three Connect screens from one template so they cannot drift apart.
import sys
HEAD = '''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=390">
<title>{title}</title>
<link rel="stylesheet" href="tokens.css">
<style>
  .addr .row {{ padding: 10px 0; }}
  .addr .t {{ font: var(--f-row-title); }}
  .who > .rowgroup {{ padding: 0; }}
  .who .head {{ min-height: 60px; }}
  .who .head .chevx {{ width: 18px; height: 18px; color: var(--meta); flex: 0 0 auto; }}
  .who .head .s.ok {{ color: var(--meta-ink); }}
  .open-steps {{ display: flex; flex-direction: column; gap: 10px; padding: 0 0 14px 44px; }}
  .open-steps .btn {{ margin-left: -44px; width: calc(100% + 44px); }}
  .open-steps ol {{ margin: 0; padding: 0; list-style: none; display: flex; flex-direction: column; gap: 8px; counter-reset: s; }}
  .open-steps li {{ counter-increment: s; display: flex; gap: 10px; font: var(--f-caption); color: var(--secondary-body); align-items: flex-start; }}
  .open-steps li::before {{ content: counter(s); flex: 0 0 20px; height: 20px; border-radius: 10px; background: var(--tint-fill-12); color: var(--tint); font: 600 12px/20px var(--font); text-align: center; margin-top: -1px; }}
  .open-steps li b {{ font-weight: 600; color: var(--label); }}
  .alt {{ font: var(--f-footnote); color: var(--meta-ink); margin: 0; }}
  .alt b {{ font-weight: 600; color: var(--secondary-body); }}
  .waiting {{ display: flex; align-items: center; gap: 8px; font: var(--f-footnote); color: var(--meta-ink); min-height: 24px; }}
  .tile.plus {{ width: 32px; height: 32px; border-radius: 8px; background: var(--gray-chip); color: var(--tertiary); }}
  .tile.plus svg {{ width: 18px; height: 18px; }}
  .cmd {{ font: 12px/17px ui-monospace, "SF Mono", Menlo, monospace; background: var(--ground); border-radius: 8px; padding: 9px 10px; color: var(--secondary-body); }}
</style></head>
<body><div class="phone">
  <div class="statusbar"></div>
  <div class="navbar"><button class="glass-btn" aria-label="Back"><i data-i="chevL"></i></button><span class="spacer"></span><button class="glass-pill" style="font-weight:600">Done</button></div>
  <div class="content no-tabbar">
    <div class="steps" aria-label="Step 3 of 3">
      <div class="step done"><div class="bar"></div><span class="lbl"><i data-i="check" style="width:12px;height:12px"></i>Link</span></div>
      <div class="step done"><div class="bar"></div><span class="lbl"><i data-i="check" style="width:12px;height:12px"></i>Choose</span></div>
      <div class="step now"><div class="bar"></div><span class="lbl">Connect</span></div>
    </div>
    <div style="display:flex;flex-direction:column;gap:6px;margin-top:6px">
      <h1 class="screen-title">Connect your assistants</h1>
      <p class="lede">Connect each one in its own app. It shows up here by name once it's connected.</p>
    </div>
    <div class="list-card addr">
      <div class="row"><div class="grow"><span class="s">Your server address</span><span class="t">pebbleaudio.okgodoit.com</span></div><button class="btn bordered small" style="padding:0 14px"><i data-i="copy" style="width:16px;height:16px"></i>Copy</button></div>
    </div>
    <div class="list-card who">
{rows}
    </div>
  </div>
</div>
<script src="chrome.js"></script>
</body></html>
'''

def head(mark, name, sub, state):
    # state: 'closed' | 'open' | 'connected'
    icon = '<span class="mark" data-m="%s"></span>' % mark if mark else '<span class="tile plus"><i data-i="plus"></i></span>'
    if state == 'connected':
        right = '<span class="check-badge" aria-label="Connected"><i data-i="check"></i></span>'
        subc = 's ok'
    else:
        right = '<i data-i="%s" class="chevx"></i>' % ('chevU' if state == 'open' else 'chevD')
        subc = 's'
    return ('<div class="row head" role="button"><span>%s</span><div class="grow"><span class="t strong">%s</span>'
            '<span class="%s">%s</span></div>%s</div>') % (icon, name, subc, sub, right)

def group(h, body=''):
    return '      <div class="rowgroup">%s%s</div>' % (h, body)

CHATGPT_OPEN = '''<div class="open-steps">
  <ol>
    <li><span>In ChatGPT, open <b>Plugins</b> and tap <b>Add</b>.</span></li>
    <li><span>Add a custom server and paste your server address.</span></li>
    <li><span>Sign in with your passkey.</span></li>
  </ol>
  <button class="btn filled">Copy Address and Open ChatGPT</button>
</div>'''

CLAUDE_OPEN = '''<div class="open-steps">
  <ol>
    <li><span>Open Claude from here. Your server is already filled in.</span></li>
    <li><span>Sign in with your passkey.</span></li>
  </ol>
  <button class="btn filled"><i data-i="external" style="width:18px;height:18px"></i>Open Claude</button>
  <p class="alt">Or in Claude, go to <b>Settings</b>, <b>Connectors</b>, then <b>Add custom connector</b>, and paste your server address.</p>
  <div class="waiting"><span class="spinner"></span>Waiting for Claude…</div>
</div>'''

MAC_OPEN = '''<div class="open-steps">
  <ol>
    <li><span>On your server's admin page, open <b>Connect an app</b> and pick the app.</span></li>
    <li><span>Copy what it shows and paste it into that app on your Mac.</span></li>
  </ol>
</div>'''

screens = {
 '05a-connect-chatgpt': ('Connect ChatGPT', [
    group(head('chatgpt', 'ChatGPT', 'Not connected', 'open'), CHATGPT_OPEN),
    group(head('claude', 'Claude', 'Not connected', 'closed')),
    group(head('codex', 'Codex, Claude Code, or Cursor', 'On your Mac', 'closed')),
    group(head(None, 'Another assistant', 'Gemini, Meta Muse, and others', 'closed')),
 ]),
 '05b-connect-claude': ('Connect Claude', [
    group(head('chatgpt', 'ChatGPT', 'Connected just now', 'connected')),
    group(head('claude', 'Claude', 'Not connected', 'open'), CLAUDE_OPEN),
    group(head('codex', 'Codex, Claude Code, or Cursor', 'On your Mac', 'closed')),
    group(head(None, 'Another assistant', 'Gemini, Meta Muse, and others', 'closed')),
 ]),
 '05c-connect-mac': ('Connect a Mac app', [
    group(head('chatgpt', 'ChatGPT', 'Connected · 12 min ago', 'connected')),
    group(head('claude', 'Claude', 'Connected just now', 'connected')),
    group(head('codex', 'Codex, Claude Code, or Cursor', 'On your Mac', 'open'), MAC_OPEN),
    group(head(None, 'Another assistant', 'Gemini, Meta Muse, and others', 'closed')),
 ]),
}
out = sys.argv[1]
for name, (title, rows) in screens.items():
    open('%s/%s.html' % (out, name), 'w').write(HEAD.format(title=title, rows='\n'.join(rows)))
