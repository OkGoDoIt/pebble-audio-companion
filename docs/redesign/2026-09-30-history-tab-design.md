# History tab — design notes (in progress)

Replaces the Library tab (a day-sectioned list of conversations) with a time-first **History**
tab at three zoom levels: Day (a timeline of the day), Week (a row per day), Month (a row per
week). Status: **design round 2, nothing implemented.** Mockups are in `history-mockups/`.

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
- Open: how the day timeline trades scale against content — see `round2-day-alternatives`.

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
