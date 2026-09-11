"""Aggregate an xctrace Time Profiler export (time-profile table XML) of the companion app.

Usage: profile_aggregate.py <export.xml> [recorded_seconds]
Prints CPU by thread, the hottest leaf frames, inclusive time for every frame from our own
binary, and the most common whole stacks. See scripts/profile-phone.sh.
"""
import xml.etree.ElementTree as ET, collections, sys, re
path = sys.argv[1]
recorded_s = float(sys.argv[2]) if len(sys.argv) > 2 else 45.0
frames = {}      # id -> (name, binary)
bins = {}        # id -> name
bts = {}         # id -> [frame ids]
tagged = {}      # tagged-backtrace id -> backtrace id (rows reference the TAGGED element by ref)
threads = {}     # id -> fmt
weights = {}     # id -> int
rows = []        # (thread_fmt, weight, [frame ids], state)
states = {}
def binname(el):
    b = el.find('binary')
    if b is None: return '?'
    if b.get('ref'): return bins.get(b.get('ref'), '?')
    bins[b.get('id')] = b.get('name'); return b.get('name')
for ev, el in ET.iterparse(path, events=('end',)):
    tag = el.tag
    if tag == 'frame' and el.get('id'):
        frames[el.get('id')] = (el.get('name'), binname(el))
    elif tag == 'backtrace' and el.get('id'):
        ids = []
        for f in el.findall('frame'):
            ids.append(f.get('id') or f.get('ref'))
        bts[el.get('id')] = ids
    elif tag == 'tagged-backtrace' and el.get('id'):
        # xctrace emits each distinct stack ONCE, as `<tagged-backtrace id=N><backtrace id=M>…`,
        # and every later sample of the same stack as a bare `<tagged-backtrace ref="N"/>`. Not
        # resolving the ref silently dropped ~70% of samples from every summary before 2026-09-11.
        bt = el.find('backtrace')
        if bt is not None:
            tagged[el.get('id')] = bt.get('id') or bt.get('ref')
    elif tag == 'thread' and el.get('id'):
        threads[el.get('id')] = el.get('fmt')
    elif tag == 'weight' and el.get('id'):
        weights[el.get('id')] = int(el.text)
    elif tag == 'thread-state' and el.get('id'):
        states[el.get('id')] = el.text
    elif tag == 'row':
        th = el.find('thread'); w = el.find('weight'); tb = el.find('tagged-backtrace'); st = el.find('thread-state')
        thf = threads.get(th.get('id') or th.get('ref'), '?')
        wv = weights.get(w.get('id') or w.get('ref'), 0)
        stv = states.get(st.get('id') or st.get('ref'), '?') if st is not None else '?'
        ids = []
        if tb is not None:
            bt = tb.find('backtrace')
            if bt is not None:
                ids = bts.get(bt.get('id') or bt.get('ref'), [])
            elif tb.get('ref'):
                ids = bts.get(tagged.get(tb.get('ref'), ''), [])
        rows.append((thf, wv, ids, stv))
        el.clear()
total = sum(r[1] for r in rows)
print(f"samples {len(rows)} total weight {total/1e6:.0f} ms over {recorded_s:.0f} s  => avg {total/1e6/(recorded_s*1000)*100:.0f}% of one core")
print("\n== by thread (ms) ==")
bythr = collections.Counter()
for thf, w, ids, st in rows: bythr[thf] += w
for k, v in bythr.most_common(12): print(f"  {v/1e6:8.0f}  {k}")
print("\n== by thread state ==")
byst = collections.Counter()
for thf, w, ids, st in rows: byst[st] += w
for k, v in byst.most_common(): print(f"  {v/1e6:8.0f}  {k}")
def fname(fid):
    n, b = frames.get(fid, ('?', '?'))
    n = (n or '?')
    return f"{n[:110]} [{b}]"
print("\n== top leaf frames (ms) ==")
leaf = collections.Counter()
for thf, w, ids, st in rows:
    if ids: leaf[fname(ids[0])] += w
for k, v in leaf.most_common(25): print(f"  {v/1e6:8.0f}  {k}")
print("\n== inclusive: frames from our binaries (ms) ==")
incl = collections.Counter()
for thf, w, ids, st in rows:
    seen = set()
    for fid in ids:
        n, b = frames.get(fid, ('?', '?'))
        if b and ('Pebble Audio' in b or 'PebbleAudio' in b):
            key = f"{(n or '?')[:120]} [{b}]"
            if key not in seen:
                seen.add(key); incl[key] += w
for k, v in incl.most_common(40): print(f"  {v/1e6:8.0f}  {k}")
print("\n== top stacks (ms), 14 frames each ==")
stacks = collections.Counter()
for thf, w, ids, st in rows:
    stacks[tuple(ids[:14])] += w
for ids, v in stacks.most_common(6):
    print(f"--- {v/1e6:.0f} ms")
    for fid in ids: print("     ", fname(fid))
