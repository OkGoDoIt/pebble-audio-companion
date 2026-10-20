# The server's connect page, opened by "Open Setup in Safari". Same tokens as the app, and one copy
# set for both widths: the iPhone page differs only where the device does (how a copied command gets
# to the Mac).
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from logos import brand_tile  # noqa: E402
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOST = "pebbleaudio.okgodoit.com"
KEY = "pa_k7QmX2v9LrT4wH8nJc3B"
CMD = (f"echo 'export PEBBLE_AUDIO_KEY={KEY}' &gt;&gt; ~/.zshrc\n"
       f"codex mcp add pebble-audio \\\n  --url https://{HOST}/mcp \\\n  --bearer-token-env-var PEBBLE_AUDIO_KEY")
cmd_html = CMD.replace(KEY, f'<span class="k">{KEY}</span>')

COPY = {
    "lede": "{tool} gets its own access key, so it can read your conversations.",
    "shown_once": "The access key is shown once. Leave this page and you'll get a new one.",
    "waiting": "Waiting for {tool}. It shows up here and in Pebble Audio once it reads.",
    "footer": "Each app has its own access key. Removing one stops only that app.",
    "shown_once_button": "The access key in this button works once. Leave this page and you'll get a new one.",
    "handoff": "Copied on this iPhone, it pastes on a Mac signed in to the same Apple Account.",
}

SHARED_CSS = """
.brand{display:flex;align-items:center;gap:10px;font:var(--f-headline)}
.brand .itile{width:30px;height:30px;border-radius:8px}
.brand .host{font:var(--f-footnote);color:var(--tertiary)}
.cmd{font:12.5px/19px var(--mono);background:var(--code-bg);border-radius:10px;padding:12px;color:var(--label);white-space:pre-wrap;overflow-wrap:break-word;margin:0}
.cmd .k{color:var(--tint);font-weight:600}
.note{font:var(--f-footnote);color:var(--tertiary)}
.wait{display:flex;align-items:flex-start;gap:10px}.wait .spinner{margin-top:1px}
.stepn{display:flex;gap:14px;align-items:flex-start;padding:14px 0}
.stepn + .stepn{border-top:.5px solid var(--hairline)}
.stepn .n{flex:0 0 26px;height:26px;border-radius:13px;background:var(--tint-fill-12);color:var(--tint);font:600 14px/26px var(--font);text-align:center}
.stepn .g{flex:1;display:flex;flex-direction:column;gap:10px;min-width:0}
.stepn .t{font:var(--f-headline);padding-top:2px}
"""


def seg(on):
    return ('<div class="seg" role="radiogroup" aria-label="App">' + "".join(
        f'<span class="{"on" if t == on else ""}" role="radio" aria-checked="{str(t == on).lower()}">{t}</span>'
        for t in ("Codex", "Claude Code", "Cursor")) + "</div>")


def steps(tool, iphone, btn_cls=""):
    w = COPY["waiting"].format(tool=tool)
    if tool == "Cursor":
        one = (f'<div class="stepn"><span class="n">1</span><div class="g"><span class="t">Click Add to Cursor</span>'
               f'<button class="btn filled {btn_cls}"><i data-i="external"></i>Add to Cursor</button>'
               f'<span class="note">{COPY["shown_once_button"]}</span></div></div>')
        two = '<div class="stepn"><span class="n">2</span><div class="g"><span class="t">Confirm in Cursor</span></div></div>'
    else:
        one = (f'<div class="stepn"><span class="n">1</span><div class="g"><span class="t">Copy this command</span>'
               f'<pre class="cmd">{cmd_html}</pre>'
               f'<button class="btn filled {btn_cls}"><i data-i="copy"></i>Copy Command</button>'
               f'<span class="note">{COPY["shown_once"]}</span></div></div>')
        hand = f'<span class="note">{COPY["handoff"]}</span>' if iphone else ""
        two = (f'<div class="stepn"><span class="n">2</span><div class="g"><span class="t">Paste it into Terminal on your Mac and press Return</span>'
               f'{hand}</div></div>')
    three = (f'<div class="stepn"><span class="n">3</span><div class="g"><span class="t">Ask {tool} about your conversations</span>'
             f'<div class="wait"><span class="spinner"></span><span class="note">{w}</span></div></div></div>')
    return one + two + three


BRAND = (f'<div class="brand"><span class="itile own"><i data-i="wave"></i></span><div style="display:flex;flex-direction:column">'
         f'<span>Pebble Audio</span><span class="host">{HOST}</span></div></div>')

phone = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=390">
<title>Connect Codex</title><link rel="stylesheet" href="tokens.css">
<style>{SHARED_CSS}
.content{{padding-bottom:120px}}
.safari{{position:fixed;left:12px;right:12px;bottom:26px;height:52px;display:flex;align-items:center;gap:8px;z-index:10}}
.safari .glass-btn{{width:48px;height:48px;border-radius:24px}}
.safari .url{{flex:1;height:48px;border-radius:24px;background:var(--glass);box-shadow:var(--shadow-float);border:.5px solid var(--glass-edge);display:flex;align-items:center;justify-content:center;gap:6px;font:500 15px/20px var(--font);color:var(--label);-webkit-backdrop-filter:blur(16px);backdrop-filter:blur(16px)}}
.safari .url svg{{width:13px;height:13px;color:var(--tertiary)}}
.card.steps-card{{padding:2px 16px}}
.stepn .cmd{{margin-left:-40px;font-size:12px;line-height:19px}}
</style></head>
<body><div class="phone"><div class="statusbar"></div>
<div class="content" style="padding-top:10px">
  {BRAND}
  <h1 class="screen-title" style="margin-top:8px">Connect Codex</h1>
  <p class="lede">{COPY["lede"].format(tool="Codex")}</p>
  {seg("Codex")}
  <div class="card steps-card">{steps("Codex", True)}</div>
  <p class="footer" style="margin-top:0">{COPY["footer"]}</p>
</div>
<div class="safari"><button class="glass-btn" aria-label="Back"><i data-i="chevL"></i></button><div class="url"><i data-i="lock"></i>{HOST}</div><button class="glass-btn" aria-label="More"><i data-i="dots"></i></button></div>
</div><script src="chrome.js"></script></body></html>
"""
open(os.path.join(ROOT, "06a-server-iphone.html"), "w").write(phone)

MAC_CSS = """
html,body{background:#D9D9DE}
.win{position:absolute;inset:0;background:var(--ground);display:flex;flex-direction:column;overflow:hidden}
.toolbar{height:52px;flex:0 0 52px;background:var(--surface);border-bottom:.5px solid var(--hairline);display:flex;align-items:center;padding:0 16px;gap:14px;color:var(--tertiary)}
.lights{display:flex;gap:8px;margin-right:12px}.lights i{width:12px;height:12px;border-radius:6px;display:block}
.toolbar svg{width:18px;height:18px}
.addr{flex:0 0 520px;margin:0 auto;height:34px;border-radius:10px;background:var(--pill-fill);display:flex;align-items:center;justify-content:center;gap:6px;font:500 13.5px/1 var(--font);color:var(--label)}
.addr svg{width:12px;height:12px;color:var(--tertiary)}
.body{flex:1;display:flex;min-height:0}
.side{width:248px;flex:0 0 248px;padding:22px 14px;display:flex;flex-direction:column;gap:4px;border-right:.5px solid var(--hairline)}
.side .brand{padding:0 10px 18px}
.nav{height:40px;border-radius:10px;display:flex;align-items:center;gap:10px;padding:0 12px;font:var(--f-callout);color:var(--label)}
.nav svg{width:18px;height:18px;color:var(--tertiary)}
.nav.on{background:var(--tint-fill-12);color:var(--tint);font-weight:600}.nav.on svg{color:var(--tint)}
.side .who{margin-top:auto;padding:0 12px;font:var(--f-footnote);color:var(--tertiary)}
.main{flex:1;padding:36px 48px;display:flex;gap:28px;align-items:flex-start;overflow:hidden}
.col{flex:1;max-width:660px;display:flex;flex-direction:column;gap:14px}
.aside{width:300px;flex:0 0 300px;display:flex;flex-direction:column;gap:10px;margin-top:94px}
.seg{max-width:420px}
.cmd{font-size:13.5px;line-height:21px;padding:14px 16px}
.btn.inline{width:auto;align-self:flex-start;padding:0 20px}
"""


def mac(tool, slug, name):
    who_last = (f'<div class="row">{brand_tile("cursor" if tool == "Cursor" else "codex")}<div class="grow">'
                f'<span class="t strong">{tool}</span><span class="s">Waiting to connect</span></div><span class="spinner"></span></div>')
    page = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=1280">
<title>Connect {tool} (Mac)</title><link rel="stylesheet" href="tokens.css">
<style>{SHARED_CSS}{MAC_CSS}</style></head>
<body><div class="win">
<div class="toolbar"><div class="lights"><i style="background:#FF5F57"></i><i style="background:#FEBC2E"></i><i style="background:#28C840"></i></div>
  <i data-i="tabs"></i><i data-i="chevL"></i>
  <div class="addr"><i data-i="lock"></i>{HOST}/connect/{slug}</div>
  <i data-i="share"></i><i data-i="plus"></i></div>
<div class="body">
  <div class="side">
    {BRAND}
    <div class="nav"><i data-i="doc"></i>Conversations</div>
    <div class="nav"><i data-i="key"></i>Who can read</div>
    <div class="nav on"><i data-i="plus"></i>Connect an app</div>
    <div class="nav"><i data-i="camera"></i>Link a phone</div>
    <div class="who">Signed in with your passkey</div>
  </div>
  <div class="main">
    <div class="col">
      <h1 class="screen-title">Connect {tool}</h1>
      <p class="lede" style="margin:0">{COPY["lede"].format(tool=tool)}</p>
      {seg(tool)}
      <div class="card" style="padding:4px 20px">{steps(tool, False, "inline")}</div>
    </div>
    <div class="aside">
      <div class="section-header" style="padding-top:0">Who can read</div>
      <div class="list-card">
        <div class="row">{brand_tile("chatgpt")}<div class="grow"><span class="t strong">ChatGPT</span><span class="s">Connected Oct 12</span></div></div>
        <div class="row">{brand_tile("claude")}<div class="grow"><span class="t strong">Claude</span><span class="s">Connected Oct 14</span></div></div>
        {who_last}
      </div>
      <p class="footer">{COPY["footer"]}</p>
    </div>
  </div>
</div></div>
<script src="chrome.js"></script></body></html>
"""
    open(os.path.join(ROOT, name + ".html"), "w").write(page)


mac("Codex", "codex", "06b-server-mac")
mac("Cursor", "cursor", "06c-server-mac-cursor")
print("ok")
