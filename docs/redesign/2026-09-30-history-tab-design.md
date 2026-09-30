# History tab — design notes (in progress)

Replaces the Library tab (a day-sectioned list of conversations) with a time-first **History**
tab at three zoom levels: Day (a timeline of the day), Week (a row per day), Month (a row per
week). Status: **design round 4, nothing implemented.** Mockups are in `history-mockups/`.

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
- **The day is a timeline with a floor on its scale:** every minute gets at least 1 pt (60 pt per
  hour). Quiet gaps are drawn at exactly that scale, capped at 120 pt, so a quiet hour looks like
  an hour; a block is at least as tall as its duration and grows when its content needs more. A
  continuous axis line runs down the gutter; it is dashed where time is compressed (before the
  first and after the last recording of the day).

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
`history-mockups/round4-white-blocks-followups` — the current design.
`history-mockups/round3-day-week-month` — the previous round (tinted blocks). `round3-today-and-week-text-tags`
— today's day view with the live block, and the week with text tags.
