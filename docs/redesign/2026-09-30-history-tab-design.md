# History tab — design notes (in progress)

Replaces the Library tab (a day-sectioned list of conversations) with a time-first **History**
tab at three zoom levels: Day (a timeline of the day), Week (a row per day), Month (a row per
week). Status: **design round 10, nothing implemented.** Mockups are in `history-mockups/`.

## Why the Library fails on real data

The Library was designed around conversations as the unit, and its demo data imagines 18-minute
conversations. On the phone the recorder runs most of the day, so a "conversation" is often a
5–24 hour block with one AI title (2026-09-23: one 15 h 28 min conversation; 09-24: one of
24 h 53 min, untitled). A list of those cannot answer "what happened Tuesday afternoon". Time is
the natural unit.

## User stories

1. Recall by time — "what was that thing around 3 on Tuesday?" → day, scan, tap, land at the moment.
2. Morning review — skim yesterday in 20 seconds.
3. Weekly review — one screen, a line per day.
4. Long-range find — "a weekend a few weeks ago, while planning the garden": the month level has to
   carry topic signal.
5. Trust check — was the 2 PM meeting recorded? Quiet and lost stay distinct.
6. Skip dead time — nights and quiet stretches must not cost rows.
7. Recall by topic — search and tags live in Library today and must survive.

## Decisions so far (Roger, 2026-09-30)

- Day / Week / Month segmented control at the top (round-1 direction A).
- An AI "in brief" card at the top of every level; topic chips on the month (direction B).
- Week rows: weekday + date, headline, two-line summary (direction A's week).
- **No coverage strips on Week or Month** — recording is the normal state, so it is not
  information there. Those levels show exceptions only (missing audio, not transcribed yet).
- The day is a **timeline** (directions B and C). The curved left accent on C's blocks is out.
- **Day timeline (round 3):** content-sized blocks in the tinted calendar-block style, with topic
  tags, people and follow-ups inline. The left gutter carries a regular hour axis (8 AM, 9 AM…)
  whose labels sit where each hour falls against the blocks, so hours are all present and in
  order but unevenly spaced; the exact range ("9:05 – 10:15 AM · 1 hr 10 min") is inside the
  block. Roger found start-time-only labels disorienting. Quiet stretches collapse to one line.
- **Week and Month carry no missing-audio notes at all.** Loss is shown on the day, in the block
  where it happened. Each week/month row gets its top few topic tags (max three).
- Today's day view ends in a Live block at the current time that opens the Live screen.
- **Round 4:** day blocks are WHITE cards (the tinted style was "a bit much"); topic tags are
  tint pills, people are gray pills with a person icon. Tags on Week/Month are pills, not a text
  line. Week and Month may run past the fold — keep the two-line summaries.
- **Week rows show up to two follow-ups per day**, then "N more". Month rows show a follow-up
  count ("16 follow-ups · 11 open"), not the items.
- **The day's time scale (rounds 5–6).** Hour spacing driven purely by content was "too
  variable" (2–3 PM came out about four times the height of 7–8 PM). Rule now:
  - **Every hour inside the day keeps a minimum height of 70 pt (1.17 pt/min), with no
    exceptions for gaps.** (105, 90 and 80 were tried; Roger chose 70 on 2026-09-30.) Collapsing long gaps to a short break was tried and rejected as
    disorienting. Compression is allowed only before the first and after the last recording of
    the day. The timeline starts AT the first recording and ends at the last, with one line at
    each end ("Quiet until 8:12 AM", "Quiet after 9:44 PM") — never a rounded-hour label plus
    a second "Quiet · 30 min" gap.
  - A block aims to stay under about 180 pt per hour (3 pt/min): its summary is clamped to fit,
    and its follow-ups collapse to one line plus "N more". Title, time, one summary line and tags
    are the floor, so a very short topic may exceed the band; topics under 25 min show no summary.
  - Long topics get LONGER summaries so the block fills its time without blank space (the
    summary stage has to be able to write to a length).
  - A continuous axis line runs down the gutter with hour ticks on it.
- **Gap kinds on the day:** quiet = bare axis + gray "Quiet · 1 hr 5 min"; paused = tint-striped
  axis + "Paused · 30 min" and who paused; **audio missing = solid amber axis for the whole
  stretch + "Audio missing · 3 hr 30 min", its time range and the cause.** Loss inside a topic is
  an amber suffix on the block's time line ("56 min · 4 min missing"). Gap labels are centred in
  their gap and **pinned at both edges while scrolling**: the label's resting place is the middle
  of the gap, clamped to the visible part of the scroll view and to the gap itself, so it slides
  to the top as the gap scrolls out above and to the bottom as it comes in from below, and is
  never off-screen while any usable part of the gap is on screen. (SwiftUI: `visualEffect` with
  the label's frame and the scroll view's bounds in the `.scrollView` coordinate space — no
  scroll-offset state.)
- **Background audio (round 10, proposed — awaiting Roger's read).** Sound that was recorded
  but holds no conversation (music, TV, a café, a fan, a few stray words) is a fourth gap kind,
  in the same calm family as quiet: a soft gray bar on the axis, "Background audio · 45 min", the
  time range and a short reason ("music, no conversation"). Unlike quiet it is tappable, because
  the audio exists — it opens the recording at that time. It never becomes a topic block, feeds
  no follow-ups and is left out of the day/week/month briefs. Why not just call it quiet: the
  audio is there to hear, and "no speech" verdicts have been wrong before (53 of 575 old ones
  later produced transcripts).
  What decides it, from what exists today (see the 2026-09-30 progress-log entry):
  - *No words at all* is known per ~15-min segment (`NoSpeech`, with who decided), and between
    turns inside a transcribed segment.
  - *Words that are not a conversation* (lyrics, TV dialogue) cannot be told from speech by any
    signal the app keeps: no music/TV classifier, Soniox's `is_audio_event` tokens are dropped,
    per-turn confidence is stored but never used. The topic stage has to make this call from the
    transcript, and it will sometimes be wrong — so the row is always openable, never hidden.
- **Follow-up state:** done items show a checked circle and dimmed text everywhere. Where only
  some are shown (two per day on the week, or a collapsed block), open ones come first. The
  circles are NOT tap targets on the week (too small); the row opens the day.

## What the research established

Data layer (all `path:line` detail is in the 2026-09-30 History progress-log entry):

- **Hour/topic summaries do not exist.** The `HH:mm:` paragraphs in two recaps are a truncation
  artifact of an on-device run, not a format. A new pipeline stage is needed; the closest thing to
  copy is `DailyRecapEngine` + `DailyRecapStore` (fingerprinted, change-gated, same gating).
- Week and month summaries do not exist either; daily recaps (`recaps.text` / `shortText`) do,
  but the UI only ever shows today's.
- `Route.conversation(atMs:)` is a MEDIA offset that only cues the player; the transcript scrolls
  only for `focus`. No wall-time → conversation lookup exists (`citationTarget` is the closest).
- Coverage for any past day is cheap (`CoverageComputer.compute` over the in-memory segment
  index). `coverage_days` is never written, so the Library's "mostly quiet" / "missing audio"
  flags are dead on real data.
- `LibraryDataSource` rebuilds the whole library on every tracked DB write, twice, and follows
  neither the content-gating nor the visibility-gating rule. History needs date-windowed reads.
- Logical day = 5 AM → 5 AM (`LogicalDay`). No week/month helpers exist.

Platform (verified against the Xcode 27.0 SDK swiftinterface):

- Zoom levels must be state inside one root screen, not pushes: horizontal day paging would
  fight the back-swipe. Page with `ScrollView(.horizontal)` + `.scrollTargetBehavior(.paging)` +
  `.scrollPosition(id:)` over a bounded range (first recording → today); no prepending.
- iOS 27 adds `.pickerStyle(.tabs)` (segmented look, announced as tabs), `.crossFade` navigation
  transition, `toolbarMinimizationBehavior(for: .navigationBar)`. Nothing new for paging, zoom,
  scroll position or calendars. `UICalendarView` decorations suit a jump-to-date sheet.

Patterns from other apps: collapse empty and overnight hours (never hide them outright);
re-tapping the tab means "back to now" (Photos); Limitless users complain about one conversation
chopped into confusing blocks, so timeline rows point INTO a conversation and never replace it;
one day boundary at every zoom level.

## Mockups

`history-mockups/direction-{a,b,c,d}` — round 1, four directions.
`history-mockups/round2-merged` — the merged set. `round2-day-alternatives` — the day drawn
content-sized and as calendar blocks.
`history-mockups/round10-background-audio` — the current day (70 pt minimum hour, merged edge
labels, centred gap labels, background-audio gaps). Rounds 6–9 are the steps that led to it. `round5-week-followup-state`
— the current week (its two day phones are superseded by round 6).
`history-mockups/round4-white-blocks-followups` — the current month; day and week superseded.
`history-mockups/round3-day-week-month` — the previous round (tinted blocks). `round3-today-and-week-text-tags`
— today's day view with the live block, and the week with text tags.
