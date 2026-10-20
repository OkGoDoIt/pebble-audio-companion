# Writes index.html (live gallery in phone frames) and _tools/sheet.html (contact sheet of the PNGs).
import os, html
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SECTIONS = [
 ("Where it lives while off", [
   ("01-settings", "01-settings", "Settings", "One row, Not set up, beside Muse. Nothing on Ask."),
 ]),
 ("Introduction", [
   ("02-intro", "02-intro", "What it does", "Muse's pattern: what it does, what you need, then the state card. Off, and what goes to your server, before the first button."),
   ("02-intro#dark", "02-intro-dark", "What it does, dark", ""),
 ]),
 ("Link", [
   ("03a-link", "03a-link", "Scan or enter the code", "The camera is live on the screen. The code is the fallback."),
   ("03b-link-expired", "03b-link-expired", "Code expired", "A heading plus one line, and Scan New Code as the next step."),
 ]),
 ("Choose", [
   ("04a-choose", "04a-choose", "All conversations (default)", "Three scopes with counts the phone knows. Clips and edits start off. Nothing sends until Start Syncing."),
   ("04b-choose-rolling", "04b-choose-rolling", "The last 90 days", "A picker for 7, 30, 90, 180, or 365 days, and one line that says the window rolls."),
 ]),
 ("Connect", [
   ("05a-connect-chatgpt", "05a-connect-chatgpt", "ChatGPT", "ChatGPT's own menu labels, quoted exactly, so they can be found."),
   ("05b-connect-claude", "05b-connect-claude", "Claude", "Open in Claude arrives with the server filled in."),
   ("05c-connect-mac", "05c-connect-mac", "Codex, Claude Code, or Cursor", "Pick the app, then Open Setup in Safari, straight to its page on your server, or open it on the Mac."),
   ("05e-connect-cursor", "05e-connect-cursor", "Cursor", "Cursor is set up from a button on the Mac, not Terminal, so its steps say so."),
   ("05d-connect-another", "05d-connect-another", "Another assistant", "Any assistant that can add a server by its address."),
 ]),
 ("Your server's setup page", [
   ("06a-server-iphone", "06a-server-iphone", "In Safari on iPhone", "Three numbered steps, the whole command with its fresh access key, and a waiting state."),
   ("06b-server-mac", "06b-server-mac", "In Safari on a Mac", "The same page and the same words at desktop width, with who can read beside it."),
   ("06c-server-mac-cursor", "06c-server-mac-cursor", "Cursor, on a Mac", "Add to Cursor carries the access key; the steps are Cursor's own."),
 ]),
 ("Linked", [
   ("07a-linked", "07a-linked", "AI Assistants", "Status and Sync, who can read, what goes to the server (as Muse keeps What goes to Meta), the same two switches as Choose, then Unlink and Delete from Server."),
   ("07e-linked-paused", "07e-linked-paused", "Sync is paused", "Sync off: nothing new goes, and assistants can still read what the server has."),
   ("07b-scope-shorter", "07b-scope-shorter", "A shorter window", "Changing 90 days to 30 says what is removed now, and that it stays on this phone."),
   ("07d-scope-from-date", "07d-scope-from-date", "From October 21 on", "Switching to a start date later is treated like a shorter window."),
   ("07c-unlink-confirm", "07c-unlink-confirm", "Unlink and delete", "Deleted from the server, every assistant loses access, nothing here changes."),
   ("08-assistant-detail", "08-assistant-detail", "One assistant", "What ChatGPT read and searched, by day, then Disconnect."),
 ]),
 ("Privacy", [
   ("09a-privacy-local", "09a-privacy-local", "(a) Everything on this phone", "The stance, Siri & Spotlight, and the five commitments. AI Assistants is a row here too."),
   ("09b-privacy-server", "09b-privacy-server", "(b) Text to your server", "One destination, named. No assistant is connected yet."),
   ("09c-privacy-assistants", "09c-privacy-assistants", "(c) ChatGPT and Claude read", "Three places: your server under Where it goes, then ChatGPT and Claude, once, under Who can read your archive."),
   ("09d-privacy-full", "09d-privacy-full", "(d) Everything on", "Soniox, your server with clips, three assistants, and Muse. Six places, each listed once."),
   ("09d-privacy-full#dark", "09d-privacy-full-dark", "(d) Everything on, dark", ""),
 ]),
]
STATEMENT = (
 "Round 2 keeps assistant-first's shape, Link, Choose, and Connect with a card per assistant, and gives "
 "it the calm of settings-native and the Muse screens. Brand marks give way to neutral "
 "initials tiles, and nothing promotes the feature on Ask. The intro and the linked screen use Muse's "
 "pattern, a state card with its next step and a “What goes to …” block before the button "
 "that starts anything. Choose now asks which conversations sync: all of them, those from a dated start, or a rolling "
 "window of the last 7 to 365 days, each with counts the phone knows. The Mac tools open your server's "
 "setup page in Safari, which shows the command with a fresh access key. Unlinking deletes the text from "
 "the server and says so. Privacy follows the shared model: one stance, one row per place your data goes, "
 "who can read your archive, and commitments derived from what is on.")
NOTES = [
 "Settings shows “Not set up”, matching the Muse row right above it, rather than “Off”.",
 "Where it goes lists what the phone sends. The assistants that read your server appear once, under Who can read your archive, and the stance counts both.",
 "ChatGPT's labels (Plugins, Add, Add custom MCP server, OAuth, Create as a plugin) are quoted as ChatGPT shows them. Those are the only places MCP and OAuth appear.",
 "“Access key” appears only on the server page, where the person copies the command.",
 "The Codex command and Cursor's Add to Cursor link are illustrative. Check each tool's current setup, and its labels, before the server ships its setup pages.",
 "Round-2 review fixes are listed in CHANGES.md, with the decisions that need Roger.",
 "Small gray text uses Tokens.tertiary. Destructive text uses a darker red that passes AA on white.",
]

def frame(src, w=390, h=844, scale=1.0):
    return (f'<div class="frame" style="width:{w*scale:.0f}px;height:{h*scale:.0f}px">'
            f'<iframe src="{src}" title="{html.escape(src)}" loading="lazy" style="width:{w}px;height:{h}px;transform:scale({scale});transform-origin:0 0"></iframe></div>')

parts = []
for sec, items in SECTIONS:
    cards = []
    for src, png, cap, note in items:
        mac = png.startswith("06b") or png.startswith("06c")
        f = frame(src + ("" if "#" in src else ".html") if "#" not in src else src.replace("#", ".html#"),
                  1280 if mac else 390, 800 if mac else 844, 0.62 if mac else 0.8)
        cards.append(f'<figure class="{"wide" if mac else ""}">{f}<figcaption><b>{html.escape(cap)}</b>'
                     f'{f"<span>{html.escape(note)}</span>" if note else ""}<a href="png/{png}.png">PNG</a></figcaption></figure>')
    parts.append(f'<section><h2>{html.escape(sec)}</h2><div class="row">{"".join(cards)}</div></section>')

index = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>AI Assistants, round 2</title>
<style>
:root{{--ground:#F2F2F7;--surface:#fff;--label:#1C1C1E;--sec:#3C3C43;--ter:#6E6E73;--tint:#5B5BD6;--hair:rgba(60,60,67,.18);
--font:-apple-system,"SF Pro Text",system-ui,"Helvetica Neue",sans-serif;color-scheme:light}}
@media (prefers-color-scheme:dark){{:root:not([data-theme="light"]){{--ground:#000;--surface:#1C1C1E;--label:#F2F2F7;--sec:#D1D1D6;--ter:#AEAEB2;--tint:#7D7DE8;--hair:rgba(84,84,88,.4);color-scheme:dark}}}}
:root[data-theme="dark"]{{--ground:#000;--surface:#1C1C1E;--label:#F2F2F7;--sec:#D1D1D6;--ter:#AEAEB2;--tint:#7D7DE8;--hair:rgba(84,84,88,.4);color-scheme:dark}}
*{{box-sizing:border-box}}body{{margin:0;background:var(--ground);color:var(--label);font:400 16px/1.45 var(--font)}}
header{{max-width:1180px;margin:0 auto;padding:40px 16px 8px}}
h1{{font:700 34px/41px var(--font);margin:0 0 6px}}.sub{{color:var(--ter);margin:0 0 18px}}
.statement{{background:var(--surface);border-radius:14px;padding:18px 20px;max-width:760px;color:var(--sec)}}
.notes{{max-width:760px;color:var(--sec);font-size:14px;padding-left:20px}}.notes li{{margin:4px 0}}
section{{max-width:1180px;margin:0 auto;padding:22px 16px 6px}}
h2{{font:700 20px/25px var(--font);margin:0 0 14px}}
.row{{display:flex;flex-wrap:wrap;gap:26px}}
figure{{margin:0;width:312px}}figure.wide{{width:794px;max-width:100%}}
.frame{{border-radius:36px;overflow:hidden;box-shadow:0 0 0 6px #1C1C1E,0 10px 30px rgba(0,0,0,.18);background:#F2F2F7}}
figure.wide .frame{{border-radius:12px;box-shadow:0 0 0 1px var(--hair),0 10px 30px rgba(0,0,0,.14);max-width:100%}}
iframe{{border:0;display:block}}
figcaption{{margin-top:14px;display:flex;flex-direction:column;gap:2px;font-size:14px;color:var(--sec)}}
figcaption b{{font-size:15px;color:var(--label)}}figcaption a{{color:var(--tint);font-size:13px;min-height:24px}}
footer{{max-width:1180px;margin:0 auto;padding:30px 16px 60px;color:var(--ter);font-size:14px}}
@media (max-width:420px){{figure{{width:100%}}.frame{{transform-origin:0 0}}}}
</style></head><body>
<header><h1>AI Assistants, round 2</h1><p class="sub">Pebble Audio · built from assistant-first with the owner's changes · iPhone 390 × 844 · synthetic data</p>
<p class="statement">{html.escape(STATEMENT)}</p>
<ul class="notes">{"".join(f"<li>{html.escape(n)}</li>" for n in NOTES)}</ul>
<p class="sub" style="margin-top:12px"><a href="sheet.png" style="color:var(--tint)">Contact sheet (PNG)</a></p></header>
{"".join(parts)}
<footer>Every screen is plain HTML on tokens.css, which is lifted from Tokens.swift and AppFont. Each frame scrolls.</footer>
</body></html>
"""
open(os.path.join(ROOT, "index.html"), "w").write(index)

# Contact sheet
cells = []
for sec, items in SECTIONS:
    for src, png, cap, note in items:
        cls = "mac" if (png.startswith("06b") or png.startswith("06c")) else ""
        cells.append(f'<figure class="{cls}"><img src="../png/{png}.png" alt=""><figcaption>{html.escape(cap)}</figcaption></figure>')
sheet = f"""<!doctype html><html><head><meta charset="utf-8"><title>Sheet</title><style>
body{{margin:0;background:#E5E5EA;font:600 15px/1.3 -apple-system,system-ui,sans-serif;color:#1C1C1E;width:2140px}}
.h{{padding:30px 34px 0;font-size:26px;font-weight:700}}.h span{{font-weight:400;color:#6E6E73;font-size:17px;margin-left:12px}}
.g{{display:grid;grid-template-columns:repeat(8,234px);padding:24px 34px 36px;column-gap:28px;row-gap:30px}}
figure{{margin:0}}img{{width:234px;height:506px;border-radius:26px;display:block;box-shadow:0 0 0 5px #1C1C1E}}
figure.mac{{grid-column:span 3}}figure.mac img{{width:758px;height:474px;border-radius:10px;box-shadow:0 0 0 1px rgba(0,0,0,.15)}}
figcaption{{margin-top:12px;text-align:center;font-size:14px}}</style></head><body>
<div class="h">AI Assistants · round 2<span>{len(cells)} screens · iPhone 390 × 844 and Mac 1280 × 800 · synthetic data</span></div>
<div class="g">{"".join(cells)}</div></body></html>"""
open(os.path.join(ROOT, "_tools", "sheet.html"), "w").write(sheet)
print(len(cells))
