import sys, html
out = sys.argv[1]
SCREENS = [
 ('Where it lives when off', [
   ('01a-ask-entry', 'Ask tab', 'One quiet line under Recent. Tapping it opens the introduction.'),
   ('01b-settings-entry', 'Settings', 'An Assistants row reading Off, beside Privacy.'),
 ]),
 ('Introduction', [
   ('02-intro', 'What it does', 'The assistants first, then a sample answer that links back to the moment. Off until set up.'),
 ]),
 ('Link', [
   ('03a-link', 'Scan or enter the code', 'Scanning is the main path; the code is the fallback.'),
   ('03b-link-expired', 'Code expired', 'An attention heading plus one line, next to the code.'),
 ]),
 ('Choose', [
   ('04-choices', 'What assistants can do', 'Reading is the feature. Clips and writing back are off by default.'),
 ]),
 ('Connect (the heart)', [
   ('05a-connect-chatgpt', 'ChatGPT', 'Each assistant gets its own short steps and one button that copies and opens.'),
   ('05b-connect-claude', 'ChatGPT connected, Claude next', 'Connected ones turn into a green check by name. Waiting shows a spinner.'),
   ('05b-connect-claude#dark', 'ChatGPT connected, Claude next, dark', ''),
   ('05c-connect-mac', 'Mac apps', 'Codex, Claude Code, and Cursor are set up from your server.'),
 ]),
 ('Linked, in Settings', [
   ('06a-assistants-linked', 'Assistants', 'Status and pause first, then who can read, what they may do, and unlink.'),
   ('06a-assistants-linked#dark', 'Assistants, dark', ''),
   ('06b-assistant-detail', 'One assistant', 'What ChatGPT read or added, by day, and Disconnect.'),
 ]),
 ('Privacy', [
   ('07a-privacy-local', 'Nothing leaves', 'Today’s screen plus one row: Assistants can see, Off.'),
   ('07b-privacy-server', 'Text to your server', 'A three-node path: the hollow node says nobody reads it yet.'),
   ('07c-privacy-assistants', 'ChatGPT and Claude read it', 'The headline names who reads, and the path fills in.'),
 ]),
]
STATEMENT = ("Assistant-first starts where people already ask questions. A quiet line on Ask and an "
 "Assistants row in Settings lead to an introduction that opens with the assistants and a sample answer "
 "linking back to the moment it came from. Setup is three visible steps: link, choose, connect. The server "
 "is named once, as the Pebble Audio server you run, and after that is simply \u201cyour server.\u201d "
 "Connecting is the heart: one card per assistant with its own short steps and a button that copies and "
 "opens, each turning into a green check by name once the server sees it. Settings answers who can read, "
 "what they read, and how to stop. Privacy gains one row and one path diagram.")
DECISIONS = [
 "Off is one calm line on Ask and the value “Off” in Settings, never a banner.",
 "Nothing is shared until setup finishes. Audio clips and assistants writing follow-ups and notes start off.",
 "A three-part bar shows where you are in setup, so progress reads as position, not text.",
 "Assistants appear by name with a green check only once the server confirms them. Until then the row shows a spinner, not a check.",
 "Privacy adds “Assistants can see” next to “Siri & Spotlight can see,” plus a phone, server, and assistants path whose filled or hollow nodes pass the squint test.",
 "The hard facts are stated where they apply: text stays on the server after Keep audio removes a recording, unlinking leaves the server’s copy, and what an assistant already read is governed by its maker.",
]
cards = []
for sec, items in SCREENS:
    figs = []
    for f, t, c in items:
        src = f.replace('#dark', '.html#dark') if '#dark' in f else f + '.html'
        png = 'png/' + (f.replace('#dark', '-dark')) + '.png'
        figs.append('<figure class="shot"><a href="%s" class="frame"><iframe src="%s" title="%s" loading="lazy" tabindex="-1"></iframe></a>'
                    '<figcaption><b>%s</b>%s<span class="files"><a href="%s">HTML</a> · <a href="%s">PNG</a></span></figcaption></figure>'
                    % (src, src, html.escape(t), html.escape(t), ('<span>%s</span>' % html.escape(c)) if c else '', src, png))
    cards.append('<section><h2>%s</h2><div class="row">%s</div></section>' % (html.escape(sec), ''.join(figs)))
page = '''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Assistant Access Mockups</title>
<style>
  :root { --ink:#1C1C1E; --sub:#3C3C43; --meta:#6E6E73; --ground:#ECECF1; --card:#fff; --tint:#5B5BD6; --edge:rgba(60,60,67,.18); }
  @media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) { --ink:#F2F2F7; --sub:#D1D1D6; --meta:#98989D; --ground:#111113; --card:#1C1C1E; --tint:#9F9FF0; --edge:rgba(84,84,88,.5); } }
  :root[data-theme="dark"] { --ink:#F2F2F7; --sub:#D1D1D6; --meta:#98989D; --ground:#111113; --card:#1C1C1E; --tint:#9F9FF0; --edge:rgba(84,84,88,.5); }
  * { box-sizing: border-box; }
  body { margin:0; background:var(--ground); color:var(--ink); font:15px/1.5 -apple-system, "SF Pro Text", system-ui, sans-serif; -webkit-font-smoothing:antialiased; }
  header { max-width: 980px; margin: 0 auto; padding: 40px 16px 8px; }
  h1 { font-size: 30px; line-height: 1.15; margin: 0 0 4px; }
  .kicker { color: var(--meta); font-size: 13px; letter-spacing: .4px; text-transform: uppercase; font-weight: 600; margin: 0 0 12px; }
  .statement { font-size: 17px; line-height: 1.55; color: var(--sub); max-width: 760px; margin: 0 0 18px; }
  ul.decisions { margin: 0; padding: 0 0 0 18px; color: var(--sub); max-width: 760px; display: grid; gap: 6px; }
  main { padding: 8px 0 60px; }
  section { padding: 24px 16px 0; max-width: 100%; }
  h2 { font-size: 13px; letter-spacing: .4px; text-transform: uppercase; color: var(--meta); margin: 0 0 12px; max-width: 1600px; }
  section .row { display: flex; gap: 28px; overflow-x: auto; padding-bottom: 8px; }
  .shot { margin: 0; flex: 0 0 auto; width: 273px; }
  .frame { display: block; width: 273px; height: 591px; border-radius: 34px; overflow: hidden; background: #000; box-shadow: 0 0 0 8px #1C1C1E, 0 12px 30px rgba(0,0,0,.18); margin: 8px; }
  .frame iframe { width: 390px; height: 844px; border: 0; transform: scale(.7); transform-origin: 0 0; pointer-events: none; display: block; }
  figcaption { margin: 18px 8px 0; font-size: 13px; color: var(--meta); display: flex; flex-direction: column; gap: 2px; }
  figcaption b { color: var(--ink); font-size: 14px; }
  .files a { color: var(--tint); }
  .sheet { display: inline-block; margin-top: 14px; color: var(--tint); }
  @media (max-width: 600px) { header { padding-top: 24px; } h1 { font-size: 24px; } }
</style></head>
<body>
<header>
  <p class="kicker">Pebble Audio · assistant access · direction</p>
  <h1>Assistant-first</h1>
  <p class="statement">@@S@@</p>
  <ul class="decisions">@@D@@</ul>
  <a class="sheet" href="sheet.png">Contact sheet (PNG)</a>
</header>
<main>@@C@@</main>
</body></html>'''.replace('@@S@@', html.escape(STATEMENT)).replace('@@D@@', ''.join('<li>%s</li>' % html.escape(d) for d in DECISIONS)).replace('@@C@@', ''.join(cards))
open(out + '/index.html', 'w').write(page)

# Contact sheet: every PNG in one grid, light first then the dark pair.
flat = [(f, t) for _, items in SCREENS for f, t, _ in items]
tiles = ''.join('<figure><img src="../png/%s.png" alt=""><figcaption>%s</figcaption></figure>' % (f.replace('#dark', '-dark'), html.escape(t)) for f, t in flat)
sheet = '''<!doctype html><html><head><meta charset="utf-8"><title>Assistant-first contact sheet</title>
<style>body{margin:0;background:#E5E5EA;font:600 15px/1.3 -apple-system,system-ui,sans-serif;color:#1C1C1E}
.h{padding:28px 32px 0;font-size:24px;font-weight:700}.h span{font-weight:400;color:#6E6E73;font-size:16px;margin-left:10px}
.g{display:grid;grid-template-columns:repeat(8,234px);gap:26px 22px;padding:22px 32px 32px}
figure{margin:0}img{width:234px;height:506px;border-radius:24px;display:block;box-shadow:0 0 0 5px #1C1C1E}
figcaption{margin-top:12px;text-align:center}</style></head><body>
<div class="h">Assistant access · assistant-first<span>15 screens, iPhone 390 × 844</span></div><div class="g">@@T@@</div></body></html>'''.replace('@@T@@', tiles)
open(out + '/_tools/sheet.html', 'w').write(sheet)
