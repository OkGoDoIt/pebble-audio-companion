# Builds every round-2 screen from shared parts, so the same sentence is the same sentence on
# every screen it appears on (the privacy model's rule: setup and Privacy derive from one source).
# Synthetic data only: Sam (kitchen renovation), Priya (product launch), Leo (dentist).
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOST = "pebbleaudio.okgodoit.com"


def page(title, body, css=""):
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=390">
<title>{title}</title>
<link rel="stylesheet" href="tokens.css">{('<style>' + css + '</style>') if css else ''}
</head>
<body>{body}
<script src="chrome.js"></script>
</body></html>
"""


def write(name, title, body, css=""):
    with open(os.path.join(ROOT, name + ".html"), "w") as f:
        f.write(page(title, body, css))


BACK = '<div class="navbar"><button class="glass-btn" aria-label="Back"><i data-i="chevL"></i></button></div>'
TAB = '<div class="tabbar" data-on="settings"></div>'
CHEV = '<i data-i="chevR"></i>'


def nav(right=""):
    return ('<div class="navbar"><button class="glass-btn" aria-label="Back"><i data-i="chevL"></i></button>'
            f'<span class="spacer"></span>{right}</div>')


def phone(inner, tab=True):
    return f'<div class="phone"><div class="statusbar"></div>{inner}{TAB if tab else ""}</div>'


def itile(label, cls=""):
    three = " three" if len(label) >= 3 else ""
    return f'<span class="itile{three} {cls}" aria-hidden="true">{label}</span>'


def svc_tile(letter):
    # A service the phone sends to (Soniox, Meta): a circle with one initial.
    return f'<span class="itile svc" aria-hidden="true">{letter}</span>'


def icon_tile(icon, cls=""):
    return f'<span class="itile {cls}" aria-hidden="true"><i data-i="{icon}"></i></span>'


def steps(now):
    names = ["Link", "Choose", "Connect"]
    out = []
    for i, n in enumerate(names):
        state = "done" if i < now else ("now" if i == now else "")
        mark = '<i data-i="check"></i>' if i < now else ""
        out.append(f'<div class="step {state}"><div class="bar"></div><span class="lbl">{mark}{n}</span></div>')
    return f'<div class="steps" role="img" aria-label="Step {now + 1} of 3, {names[now]}">{"".join(out)}</div>'


def toggle(on, label):
    return f'<span class="toggle{" on" if on else ""}" role="switch" aria-checked="{"true" if on else "false"}" aria-label="{label}"></span>'


def row(t, v="", chev=True, sub="", lead="", cls=""):
    grow = f'<div class="grow"><span class="t">{t}</span>{f"<span class=s>{sub}</span>" if sub else ""}</div>'
    return (f'<div class="row {cls}" role="button">{lead}{grow}'
            f'{f"<span class=v>{v}</span>" if v else ""}{CHEV if chev else ""}</div>')


# ─── Shared sentences (one source, as the privacy model asks) ────────────────────────────
GOES_SERVER_INTRO = (
    '<div class="goes"><span class="h">What goes to your server</span>'
    "<p>The text of your conversations: titles, summaries, transcripts, notes, follow-ups, and recaps. "
    "No audio goes to your server unless you allow clips.</p>"
    "<p>Assistants you connect read it there, and it becomes part of your chats with them.</p></div>"
)
ROLLING_LINE = "Always the last {n} days. Older conversations are removed from your server each day."
KEEP_AUDIO_LINE = "Your server keeps the text even after Keep audio clears a recording here."

# ─── 01 Settings root ─────────────────────────────────────────────────────────────────────
write("01-settings", "Settings", phone(f"""
<div class="content">
  <h1 class="large-title" style="margin-top:14px">Settings</h1>
  <div class="list-card">
    <div class="row tall">{icon_tile('watch', 'own')}<div class="grow"><span class="t">Pebble Time 2</span><span class="s" style="color:var(--good-ink)">Recording · connected</span></div>{CHEV}</div>
    <div class="row"><div class="grow"><span class="t">Record from your Pebble</span><span class="s">Capturing audio from your Pebble.</span></div>{toggle(True, 'Record from your Pebble')}</div>
    <div class="row"><span class="t" style="color:var(--tint)">Pause for a while…</span></div>
    <div class="row"><div class="grow"><span class="t">Alert me about missed audio</span><span class="s">Only long gaps, at most one an hour.</span></div>{toggle(False, 'Alert me about missed audio')}</div>
  </div>
  <div class="list-card">
    {row('Transcription &amp; AI', 'Local only')}
    {row('Muse', 'Not set up')}
    {row('AI Assistants', 'Not set up')}
    {row('Storage', '2.1 GB · 383 recordings')}
    {row('Privacy', 'Everything on this phone')}
    {row('About You')}
    {row('Watch firmware')}
    {row('Diagnostics')}
  </div>
  <p class="footer">Recordings and transcripts stay on this phone.</p>
</div>"""), css=".row .v{font:var(--f-body)}")

# ─── 02 Intro (the Muse family: what it does, what you need, then the state card) ─────────
write("02-intro", "AI Assistants", phone(f"""
{BACK}
<div class="content">
  <h1 class="large-title">AI Assistants</h1>
  <div class="card">
    <div class="intro"><span class="circle"><i data-i="chat"></i></span>
      <div><div class="h">Let your assistants read your conversations</div>
      <p>Ask ChatGPT, Claude, or another assistant what you agreed to yesterday, and it answers from your conversations.</p></div></div>
    <div class="need" aria-label="What you need">
      <span class="i"><i data-i="server"></i>A Pebble Audio server of your own</span>
      <span class="i"><i data-i="browser"></i>Your server open in a browser</span></div>
  </div>
  <div class="card">
    <div class="state-head big"><span class="dot neutral"></span>Off</div>
    <p class="state-line">Nothing syncs until you tap Start Syncing.</p>
    {GOES_SERVER_INTRO}
    <button class="btn filled">Link Your Server</button>
  </div>
</div>"""), css=".intro p{font:var(--f-sub-body);color:var(--secondary-body)} .need{gap:6px;margin-top:12px;padding-top:10px}")

# ─── 03 Link ──────────────────────────────────────────────────────────────────────────────
FINDER = ('<div class="finder" role="img" aria-label="Camera, looking for a code"><div class="grain"></div>'
          '<div class="frame"><i class="a"></i><i class="b"></i><i class="c"></i><i class="d"></i></div>'
          '<div class="cap">Looking for a code</div></div>')
write("03a-link", "Link your server", phone(f"""
{BACK}
<div class="content no-tabbar">
  {steps(0)}
  <h1 class="screen-title">Link your server</h1>
  <p class="lede">On your server, open <b>Link a phone</b> and point this camera at its code.</p>
  {FINDER}
  <div class="section-header">Or enter it</div>
  <div class="card" style="display:flex;flex-direction:column;gap:12px">
    <div><p class="field-label">Server</p><div class="field"><span class="ph">{HOST}</span></div></div>
    <div><p class="field-label">Code</p>
      <div class="code-boxes" aria-label="Code, 8 characters"><span class="box cursor"></span><span class="box"></span><span class="box"></span><span class="box"></span><span class="gap"></span><span class="box"></span><span class="box"></span><span class="box"></span><span class="box"></span></div></div>
    <button class="btn bordered disabled">Link This Phone</button>
  </div>
</div>""", tab=False))

write("03b-link-expired", "Code expired", phone(f"""
{BACK}
<div class="content no-tabbar">
  {steps(0)}
  <h1 class="screen-title">Link your server</h1>
  <div class="card">
    <div class="state-head"><span class="dot attention"></span>This code has expired</div>
    <p class="state-line small">Codes last ten minutes. Open Link a phone on your server for a new one.</p>
    <button class="btn filled" style="margin-top:14px"><i data-i="camera"></i>Scan New Code</button>
  </div>
  <div class="section-header">Or enter it</div>
  <div class="card" style="display:flex;flex-direction:column;gap:12px">
    <div><p class="field-label">Server</p><div class="field">{HOST}</div></div>
    <div><p class="field-label">Code</p>
      <div class="code-boxes error" aria-label="Code, expired"><span class="box">K</span><span class="box">7</span><span class="box">Q</span><span class="box">M</span><span class="gap"></span><span class="box">2</span><span class="box">X</span><span class="box">P</span><span class="box">A</span></div></div>
    <button class="btn bordered disabled">Link This Phone</button>
  </div>
</div>""", tab=False))

# ─── 04 Choose ────────────────────────────────────────────────────────────────────────────
LINKED_CHIP = (f'<div style="display:flex;align-items:center;gap:8px;font:var(--f-footnote);color:var(--secondary-body)">'
               f'<span class="dot good" style="width:8px;height:8px"></span>Linked to <b>{HOST}</b></div>')
DAYS = [7, 30, 90, 180, 365]


def seg(sel):
    return ('<div class="seg" role="radiogroup" aria-label="Days">' +
            "".join(f'<span class="{"on" if d == sel else ""}" role="radio" aria-checked="{"true" if d == sel else "false"}">{d}</span>' for d in DAYS) +
            "</div>")


TODAY = "October 21"
COUNTS = {7: ("14", "October 14"), 30: ("57", "September 21"), 90: ("168", "July 23"),
          180: ("287", "April 24"), 365: ("412", "March 4")}


def count_text(n):
    c, d = COUNTS[n]
    return f"{c} conversations, back to {d}."


def scope_cards(sel, n=90, count_line=""):
    radio = lambda on: f'<span class="radio{" on" if on else ""}"></span>'
    all_c = (f'<div class="option{" sel" if sel == "all" else ""}" role="radio" aria-checked="{str(sel == "all").lower()}">'
             f'<div class="grow"><span class="t">All conversations</span><span class="s body">All 412, back to March 4, and every new one.</span>'
             f'{f"<span class=s>{KEEP_AUDIO_LINE}</span>" if sel == "all" else ""}</div>{radio(sel == "all")}</div>')
    # Dated, so "today" can't be misread: it starts at midnight and includes this morning.
    today = (f'<div class="option{" sel" if sel == "today" else ""}" role="radio" aria-checked="{str(sel == "today").lower()}">'
             f'<div class="grow"><span class="t">From {TODAY} on</span><span class="s body">Today\'s 3 conversations, and every new one.</span></div>{radio(sel == "today")}</div>')
    if sel == "days":
        last = (f'<div class="option sel" role="radio" aria-checked="true"><div class="grow"><span class="t">Only the last {n} days</span>'
                f'{seg(n)}<span class="s body">{count_text(n)}</span><span class="s">{ROLLING_LINE.format(n=n)}</span>'
                f'</div>{radio(True)}</div>')
    else:
        last = (f'<div class="option" role="radio" aria-checked="false"><div class="grow"><span class="t">Only the last {n} days</span>'
                f'<span class="s body">{count_text(n)}</span><span class="s">Older ones are removed from your server each day.</span></div>{radio(False)}</div>')
    return f'<div class="opts" role="radiogroup" aria-label="Conversations">{all_c}{today}{last}</div>'


MAY_ALSO = ('<div class="section-header">Assistants may also</div><div class="list-card">'
            f'<div class="row top"><div class="grow"><span class="t">Ask for audio clips</span><span class="s">Only the moment they ask about.</span></div>{toggle(False, "Ask for audio clips")}</div>'
            f'<div class="row top"><div class="grow"><span class="t">Add follow-ups and notes</span><span class="s">Marked with the assistant\'s name.</span></div>{toggle(False, "Add follow-ups and notes")}</div>'
            '</div>')


def choose(name, sel, goes):
    write(name, "Choose what syncs", phone(f"""
{BACK}
<div class="content no-tabbar">
  {steps(1)}
  <h1 class="screen-title">Choose what syncs</h1>
  {scope_cards(sel, 90)}
  {MAY_ALSO}
  <div class="goes solo"><span class="h">What goes to {HOST}</span><p>{goes}</p></div>
  <button class="btn filled">Start Syncing</button>
</div>""", tab=False), css=".content{gap:10px}.option{padding:10px 16px}.goes.solo{background:var(--surface);margin-top:2px}")


choose("04a-choose", "all", "The text of all 412 conversations, and each new one. No audio goes to your server.")
choose("04b-choose-rolling", "days",
       "The text of 168 conversations now, then always the last 90 days. No audio goes to your server.")

# ─── 05 Connect ───────────────────────────────────────────────────────────────────────────
ADDR = (f'<div class="list-card"><div class="row"><div class="grow"><span class="s">Your server address</span>'
        f'<span class="t strong">{HOST}</span></div><button class="btn bordered small"><i data-i="copy" style="width:16px;height:16px"></i>Copy</button></div></div>')


def head(tile, name, sub, state):
    # state: "open", "closed", "done"
    right = ('<span class="check-badge" aria-label="Connected"><i data-i="check"></i></span>' if state == "done"
             else f'<i data-i="{"chevU" if state == "open" else "chevD"}" class="disc"></i>')
    return (f'<div class="row head" role="button" aria-expanded="{str(state == "open").lower()}">{tile}'
            f'<div class="grow"><span class="t strong">{name}</span><span class="s">{sub}</span></div>{right}</div>')


def connect(name, groups):
    write(name, "Connect your assistants", phone(f"""
{nav('<button class="glass-pill">Done</button>')}
<div class="content no-tabbar">
  {steps(2)}
  <h1 class="screen-title">Connect your assistants</h1>
  <p class="lede">Connect each one in its own app. It shows up here once your server sees it.</p>
  {ADDR}
  <div class="list-card who">{''.join(f'<div class="grp">{g}</div>' for g in groups)}</div>
</div>""", tab=False))


G_CHATGPT_OPEN = head(itile("GPT"), "ChatGPT", "Not connected", "open") + """<div class="open-steps"><ol>
  <li><span>In ChatGPT, open <b>Plugins</b> and tap <b>Add</b>.</span></li>
  <li><span>Tap <b>Add custom MCP server</b> and paste your server address.</span></li>
  <li><span>Choose <b>OAuth</b>, then tap <b>Create as a plugin</b>.</span></li>
  <li><span>Sign in to your server with your passkey.</span></li></ol>
  <button class="btn filled">Copy Address and Open ChatGPT</button></div>"""
G_CHATGPT_DONE = head(itile("GPT"), "ChatGPT", "Connected just now", "done")
G_CLAUDE_CLOSED = head(itile("Cl"), "Claude", "Not connected", "closed")
G_CLAUDE_OPEN = head(itile("Cl"), "Claude", "Not connected", "open") + """<div class="open-steps"><ol>
  <li><span>Tap <b>Open in Claude</b>. Your server is already filled in.</span></li>
  <li><span>Sign in to your server with your passkey.</span></li></ol>
  <button class="btn filled"><i data-i="external"></i>Open in Claude</button>
  <p class="alt">Or in Claude, open <b>Settings › Connectors</b>, tap <b>Add custom connector</b>, and paste your server address.</p></div>"""
G_CLAUDE_DONE = head(itile("Cl"), "Claude", "Connected 2 min ago", "done")
G_MAC_CLOSED = head(icon_tile("laptop"), "Codex, Claude Code, or Cursor", "On your Mac", "closed")
def mac_seg(on):
    return ('<div class="seg" role="radiogroup" aria-label="App">' + "".join(
        f'<span class="{"on" if t == on else ""}" role="radio" aria-checked="{str(t == on).lower()}">{t}</span>'
        for t in ("Codex", "Claude Code", "Cursor")) + '</div>')


# Codex and Claude Code are set up from Terminal; Cursor from a button on the Mac. Same server page,
# different steps, so the phone's steps follow the picked app.
G_MAC_OPEN = head(icon_tile("laptop"), "Codex, Claude Code, or Cursor", "On your Mac", "open") + f"""<div class="open-steps">
  {mac_seg("Codex")}
  <ol><li><span>Tap <b>Open Setup in Safari</b>. Your server shows the command for Codex.</span></li>
  <li><span>Copy it, then paste it into Terminal on your Mac.</span></li></ol>
  <button class="btn filled"><i data-i="external"></i>Open Setup in Safari</button>
  <p class="alt" style="text-align:center;margin-left:-46px">Or, on your Mac, open {HOST}/connect.</p></div>"""
G_MAC_CURSOR = head(icon_tile("laptop"), "Codex, Claude Code, or Cursor", "On your Mac", "open") + f"""<div class="open-steps">
  {mac_seg("Cursor")}
  <ol><li><span>Tap <b>Copy Link</b>, then paste it into Safari on your Mac.</span></li>
  <li><span>Click <b>Add to Cursor</b>, then confirm in Cursor.</span></li></ol>
  <button class="btn bordered"><i data-i="copy"></i>Copy Link</button>
  <p class="alt" style="text-align:center;margin-left:-46px">Or, on your Mac, open {HOST}/connect.</p></div>"""
G_CODEX_DONE = head(icon_tile("terminal"), "Codex on Mac", "Connected Oct 18", "done")
G_MAC_REST = head(icon_tile("laptop"), "Claude Code or Cursor", "On your Mac", "closed")
G_OTHER_CLOSED = head(icon_tile("plus"), "Another assistant", "Gemini and others", "closed")
G_OTHER_OPEN = head(icon_tile("plus"), "Another assistant", "Gemini and others", "open") + """<div class="open-steps"><ol>
  <li><span>In that assistant, find where it adds a custom connector or server.</span></li>
  <li><span>Paste your server address.</span></li>
  <li><span>Sign in to your server with your passkey.</span></li></ol>
  <button class="btn bordered"><i data-i="copy"></i>Copy Address</button></div>"""

connect("05a-connect-chatgpt", [G_CHATGPT_OPEN, G_CLAUDE_CLOSED, G_MAC_CLOSED, G_OTHER_CLOSED])
connect("05b-connect-claude", [G_CHATGPT_DONE, G_CLAUDE_OPEN, G_MAC_CLOSED, G_OTHER_CLOSED])
connect("05c-connect-mac", [G_CHATGPT_DONE, G_CLAUDE_DONE, G_MAC_OPEN, G_OTHER_CLOSED])
connect("05e-connect-cursor", [G_CHATGPT_DONE, G_CLAUDE_DONE, G_MAC_CURSOR, G_OTHER_CLOSED])
connect("05d-connect-another", [G_CHATGPT_DONE.replace("Connected just now", "Connected Oct 12"),
                                G_CLAUDE_DONE.replace("Connected 2 min ago", "Connected Oct 14"),
                                G_CODEX_DONE, G_MAC_REST, G_OTHER_OPEN])

# ─── 07 Linked ────────────────────────────────────────────────────────────────────────────
WHO_LINKED = [(itile("GPT"), "ChatGPT", "Can read · Last read 1 hr ago"), (itile("Cl"), "Claude", "Can read · Last read yesterday"),
              (icon_tile("terminal"), "Codex on Mac", "Can read · Last read Oct 18")]


def linked_body(paused=False):
    who = "".join(f'<div class="row tall">{t}<div class="grow"><span class="t strong">{n}</span><span class="s">{s}</span></div>{CHEV}</div>' for t, n, s in WHO_LINKED)
    if paused:
        state = (f'<div class="state-head"><span class="dot neutral"></span>Sync is paused</div>'
                 '<p class="state-line small">Assistants can still read what your server already has.</p>')
        goes = ("Your server has the text of 168 conversations. Nothing new goes to it while Sync is off.")
    else:
        state = (f'<div class="state-head"><span class="dot good"></span>Syncing to {HOST}</div>'
                 '<p class="state-line small">Last synced 2 minutes ago.</p>')
        goes = ("The text of 168 conversations: titles, summaries, transcripts, notes, follow-ups, and recaps. "
                "No audio goes to your server.")
    # The Muse paired screen keeps "What goes to Meta"; this keeps "What goes to" its host, with the
    # scope row inside it, so what syncs is answered once, and the rolling line sits right under it.
    return f"""
{BACK}
<div class="content">
  <h1 class="large-title">AI Assistants</h1>
  <div class="list-card">
    <div style="padding:16px 0 14px">{state}</div>
    <div class="row"><span class="t" style="flex:1">Sync</span>{toggle(not paused, 'Sync')}</div>
  </div>
  <div class="section-header">Who can read</div>
  <div class="list-card">{who}<div class="row tint">{icon_tile('plus', 'own')}<span class="t" style="flex:1">Connect Another Assistant</span></div></div>
  <div class="section-header">What goes to {HOST}</div>
  <div class="list-card">
    <div class="goes-text"><p>{goes}</p>{"" if paused else "<p>Deleting a conversation here deletes it from your server too.</p>"}</div>
    {row('Conversations', 'Last 90 days')}
  </div>
  <p class="footer">{ROLLING_LINE.format(n=90)}</p>
  {MAY_ALSO}
  <div class="list-card" style="margin-top:8px"><div class="row destructive" role="button"><span class="t">Unlink and Delete from Server</span></div></div>
</div>"""


LINKED_CSS = (".goes-text{padding:13px 0 12px;display:flex;flex-direction:column;gap:8px;border-bottom:.5px solid var(--hairline)}"
              ".goes-text p{font:var(--f-sub-body);color:var(--secondary-body)}")
write("07a-linked", "AI Assistants", phone(linked_body()), css=LINKED_CSS)
write("07e-linked-paused", "AI Assistants", phone(linked_body(paused=True)), css=LINKED_CSS)


def confirm(title, body, act, extra=""):
    return f"""
<div class="scrim"></div>
<div class="sheet-confirm" role="alertdialog" aria-label="{title}">
  <div class="h">{title}</div>
  <p>{body}</p>{f"<p>{extra}</p>" if extra else ""}
  <div class="acts"><span class="danger" role="button">{act}</span><span role="button">Cancel</span></div>
</div>"""


# Same bottom confirmation as the other two (and as Forget Watch): red text, neutral pill.
write("07c-unlink-confirm", "Unlink and delete", phone(linked_body()) + confirm(
    "Unlink and delete from your server?",
    f"Deletes the text of 168 conversations from {HOST}. ChatGPT, Claude, and Codex on Mac lose access. Nothing on this phone changes.",
    "Unlink and Delete", "What they already read stays in your chats with them."), css=LINKED_CSS)


def scope_editor(name, sel_cards, title, body, act):
    write(name, "Conversations", phone(f"""
<div class="navbar"><button class="glass-btn" aria-label="Back"><i data-i="chevL"></i></button><span class="nav-title">Conversations</span></div>
<div class="content">
  {sel_cards}
</div>""") + confirm(title, body, act), css=".content{padding-top:10px}")


# Scope edited later: a shorter window, or a start date, says what is removed now.
scope_editor("07b-scope-shorter", scope_cards("days", 30), "Remove 111 conversations from your server?",
             f"Conversations from before September 21 are removed from {HOST} now, and assistants can no longer read them. They stay on this phone.",
             "Remove 111 Conversations")
scope_editor("07d-scope-from-date", scope_cards("today", 90), "Remove 165 conversations from your server?",
             f"Conversations from before October 21 are removed from {HOST} now, and assistants can no longer read them. They stay on this phone.",
             "Remove 165 Conversations")

# ─── 08 One assistant ─────────────────────────────────────────────────────────────────────
ACT_TODAY = [("calendar", "Monday's recap", "Read · 9:42 AM"),
             ("doc", "Kitchen renovation with Sam", "Read · 9:41 AM"),
             ("search", "Searched for “cabinet quote”", "9:40 AM")]
ACT_YDAY = [("doc", "Product launch plan with Priya", "Read · 4:12 PM"),
            ("search", "Searched for “launch date”", "4:11 PM"),
            ("doc", "Leo's dentist appointment", "Read · 10:05 AM")]


def acts(lst):
    # A read opens that conversation; a search has nothing to open, so it has no chevron.
    return "".join(f'<div class="row">{icon_tile(i)}<div class="grow"><span class="t">{t}</span><span class="s">{s}</span></div>{"" if i == "search" else CHEV}</div>' for i, t, s in lst)


write("08-assistant-detail", "ChatGPT", phone(f"""
{BACK}
<div class="content">
  <div style="display:flex;align-items:center;gap:14px;margin:4px 0 4px">{itile('GPT', 'lg')}<h1 class="large-title" style="margin:0">ChatGPT</h1></div>
  <div class="card">
    <div class="state-head"><span class="dot good"></span>Can read your conversations</div>
    <p class="state-line small">Connected October 12. It can't ask for clips or add anything.</p>
  </div>
  <div class="section-header">Today</div>
  <div class="list-card">{acts(ACT_TODAY)}</div>
  <div class="section-header">Yesterday</div>
  <div class="list-card">{acts(ACT_YDAY)}</div>
  <div class="list-card" style="margin-top:8px"><div class="row destructive" role="button"><span class="t">Disconnect ChatGPT</span></div></div>
  <p class="footer">ChatGPT can't read your server after this. What it already read stays in your chats with it.</p>
</div>"""), css=".row .t{font:var(--f-callout)}")

# ─── 09 Privacy, derived from one set of inputs ───────────────────────────────────────────
C_PEBBLE = "The official Pebble app never receives your audio."
C_DIAG = ("Diagnostic logs stay on this phone. They hold no audio and no transcript text, and are only "
          "ever shared if you send them yourself from Diagnostics.")
C_STORE = ("Recordings, transcripts, and notes are stored in this app on your iPhone, and are included in "
           "the iPhone's usual backups.")
C_SPOT = ("Spotlight's index of your recordings is kept on this iPhone by iOS. What goes into it — nothing, "
          "titles and summaries, or everything — is your choice on this screen.")


def privacy(name, *, stt=None, server=None, assistants=(), clips=False, muse=False, scope="All conversations",
            rolling=None, siri="Titles and summaries"):
    receivers = ([stt] if stt else []) + ([server] if server else []) + [a[1] for a in assistants] + (["Meta"] if muse else [])
    n = len(receivers)
    words = {2: "two", 3: "three", 4: "four", 5: "five", 6: "six", 7: "seven"}
    if n == 0:
        dot, head = "good", "Everything stays on this phone"
        line = "Transcription and AI both run on this iPhone. No recording, transcript, or note is sent to any service."
    elif n == 1 and server:
        dot, head = "neutral", f"Text syncs to {server}"
        audio = "Audio stays on this phone." if not (stt or clips) else ""
        line = f"Your conversations' text goes to your own server. {audio}".strip()
    else:
        dot, head = "neutral", f"Your data goes to {words[n]} places you chose"
        line = "Each is listed below. Nothing else leaves this phone."

    # Where it goes: one row per destination the phone sends to, in the model's order.
    goes = []

    def dest(tile, title, sub, chips):
        ch = "".join(f'<span class="chip"><i data-i="{i}"></i>{l}</span>' for i, l in chips)
        return (f'<div class="row tall">{tile}<div class="grow"><span class="t strong">{title}</span>'
                f'<span class="s">{sub}</span><div class="chips">{ch}</div></div>{CHEV}</div>')
    if stt:
        goes.append(dest(svc_tile("S"), stt, "Transcribes your recordings", [("audio", "Audio")]))
    if server:
        goes.append(dest(icon_tile("server", "own"), "Your Pebble Audio server", f"{server} · {scope}",
                         [("text", "Text")] + ([("audio", "Clips when asked")] if clips else [])))
    if muse:
        goes.append(dest(svc_tile("M"), "Meta", "Your questions to Muse go to Meta", [("question", "Your questions")]))
    goes_html = ""
    if goes:
        # Only the rolling line, which is about the server row alone; deletion lives on AI Assistants.
        foot = ROLLING_LINE.format(n=rolling) if rolling else ""
        goes_html = (f'<div class="section-header">Where it goes</div><div class="list-card">{"".join(goes)}</div>'
                     + (f'<p class="footer">{foot}</p>' if foot else ""))

    who_html = ""
    if server:
        if assistants:
            can = "Can read and ask for clips" if clips else "Can read"
            rows = "".join(f'<div class="row tall">{tile}<div class="grow"><span class="t strong">{nm}</span><span class="s">{can}{"<br>" if clips else " · "}Last read {when}</span></div>{CHEV}</div>'
                           for tile, nm, when in assistants)
            who_html = (f'<div class="section-header">Who can read your archive</div><div class="list-card">{rows}'
                        f'<div class="row tint"><span class="t" style="flex:1">Manage AI Assistants</span>{CHEV}</div></div>'
                        '<p class="footer">What they read becomes part of your chats with them.</p>')
        else:
            who_html = ('<div class="section-header">Who can read your archive</div><div class="list-card">'
                        '<div class="row plain-text"><span class="t">No assistant is connected yet.</span></div>'
                        f'<div class="row tint"><span class="t" style="flex:1">Connect an Assistant</span>{CHEV}</div></div>')

    siri_rows = row("Siri &amp; Spotlight can see", sub=siri)
    if not server:
        siri_rows += row("AI Assistants", sub="Not set up")

    # Commitments, derived.
    if n == 0:
        c1 = ("This app has no account and no server of its own. Nothing you record, transcribe, or write is sent "
              "to its developer, and none of it is used for training, advertising, or profiling.")
        c2 = "Your recordings and transcripts are never sold or shared. They go only where this screen says they go."
    else:
        c1 = ("This app has no account of its own. Nothing you record, transcribe, or write is sent to its developer, "
              "and this app uses none of it for training, advertising, or profiling.")
        if server:
            c1 += " Your server holds a copy of the text because you linked it."
        c2 = "Your recordings and transcripts are never sold. They go only where this screen says they go."
    commits = [c1, c2]
    vendors = ([stt] if stt else []) + [a[1].replace(" on Mac", "") for a in assistants] + (["Meta"] if muse else [])
    if vendors:
        if len(vendors) == 1:
            vl = vendors[0]
        elif len(vendors) == 2:
            vl = f"{vendors[0]} and {vendors[1]}"
        else:
            vl = ", ".join(vendors[:-1]) + ", and " + vendors[-1]
        commits.append(f"What {vl} keep is governed by them, not by this app.")
    if muse:
        commits.append("Meta may use your questions to improve its AI. You can turn that off in the Muse app.")
    commits += [C_PEBBLE, C_DIAG, C_STORE, C_SPOT]
    commit_html = "".join(f"<div>{c}</div>" for c in commits)

    write(name, "Privacy", phone(f"""
{BACK}
<div class="content">
  <h1 class="large-title">Privacy</h1>
  <div class="card">
    <div class="state-head"><span class="dot {dot}"></span>{head}</div>
    <p class="state-line small">{line}</p>
  </div>
  {goes_html}
  {who_html}
  <div class="list-card">{siri_rows}</div>
  <div class="section-header">Privacy</div>
  <div class="list-card commit">{commit_html}</div>
</div>"""), css=".row .t.strong{font:var(--f-row-title)} .row .grow > .s{font:var(--f-sub-body)} .row.tall{align-items:center}")


privacy("09a-privacy-local")
privacy("09b-privacy-server", server=HOST)
privacy("09c-privacy-assistants", server=HOST, scope="Last 90 days", rolling=90,
        assistants=[(itile("GPT"), "ChatGPT", "1 hr ago"), (itile("Cl"), "Claude", "yesterday")])
privacy("09d-privacy-full", stt="Soniox", server=HOST, clips=True, muse=True,
        assistants=[(itile("GPT"), "ChatGPT", "1 hr ago"), (itile("Cl"), "Claude", "yesterday"),
                    (icon_tile("terminal"), "Codex on Mac", "Oct 18")])
print("built")
