# History tab — plan

**Status (2026-09-30):** design agreed with Roger after ten mockup rounds. Nothing is built.
This document is the plan to build it. It supersedes `2026-09-30-history-tab-design.md`, which
stays as the record of how the design was reached.

**Where things are:**

- Mockups (HTML and PNG): `docs/redesign/history-mockups/`. The current ones are listed in
  [section 12](#12-mockup-index).
- Running journal: the 2026-09-30 History entries in
  `UPSTREAM_THIRD_PARTY_BACKGROUND_AUDIO_IMPLEMENTATION_PLAN.md`.
- The app: `pebble-audio-companion/ios/` (SwiftUI `App/` over the `PebbleAudioKit` package).

**Contents**

1. [Summary](#1-summary)
2. [Why the Library has to go](#2-why-the-library-has-to-go)
3. [Goals, non-goals and principles](#3-goals-non-goals-and-principles)
4. [User stories](#4-user-stories)
5. [Design specification](#5-design-specification)
6. [What exists today](#6-what-exists-today)
7. [Architecture](#7-architecture)
8. [Build sequence](#8-build-sequence)
9. [Testing and validation](#9-testing-and-validation)
10. [Risks](#10-risks)
11. [Decisions Roger still has to make](#11-decisions-roger-still-has-to-make)
12. [Mockup index](#12-mockup-index)
13. [Appendix: notes for the audio-classification task](#13-appendix-notes-for-the-audio-classification-task)

---

## 1. Summary

The Library tab lists conversations. On a watch that records most of the day, a "conversation"
is often a block of 5 to 24 hours with one title, so the list cannot answer "what happened
Tuesday afternoon". The History tab replaces it with time as the unit, at three zoom levels on
one screen:

- **Day** — a vertical timeline of the day, first recording to last. Each stretch of talk about
  one subject is a white card (a *chapter*) with a title, its time range, a summary sized to its
  length, topic and people pills, and its follow-ups. Gaps between cards say what they are:
  quiet, paused, audio missing, or sound with no conversation. Swipe sideways to change day.
- **Week** — one row per day: a headline, a two-line summary, up to three topic pills and up to
  two follow-ups. Tap a row to open that day.
- **Month** — one row per week, in the same shape. Tap a row to open that week.

Every level opens with a short AI summary of the period ("The day in brief").

Three things do not exist yet and are most of the work:

1. **Chapters.** Nothing in the app summarises a day below the level of a conversation. A new
   pipeline stage cuts each day's transcript into chapters and writes a title, summary, tags and
   people for each.
2. **Week and month summaries**, plus a one-line headline and summary per day for the week rows.
3. **A read side built for windows of time.** The Library's data source rebuilds the whole
   archive on every database write. History reads one day, week or month at a time, publishes
   only when something visible changed, and does nothing while off screen.

One thing History depends on but does not build: deciding which recorded stretches hold no
conversation (music, TV, a café). That is a separate backend task; History only reads its
result. See [7.6](#76-audio-with-no-conversation-an-external-dependency).

---

## 2. Why the Library has to go

**The unit is wrong for this recorder.** The Library was designed around conversations of about
18 minutes (its demo data). The grouping rules split a conversation only at a long gap, a pause,
a loss, or 15 minutes of settled quiet, and only at the joins between 15-minute segments. With
the watch recording continuously, real conversations come out far longer. In the 2026-09-30
backup:

- 61 conversations span 13 days, from 15 minutes to 24 hours each.
- 2026-09-23 is one conversation of 15 h 28 min. 2026-09-24 is one of 24 h 53 min, untitled.
- One title and one three-sentence summary describe each of them.

A list row that says "Office search and vendor invoices · 15 h" is not something you can scan
for the thing that happened at 3 PM.

**The grouping cannot simply be made finer.** A conversation is a set of whole segments, and
every per-conversation record (titles, tags, notes, speaker names, follow-up sources, search
documents) is keyed by its id. A topic change falls inside a segment, usually mid-way. The code
says why it refuses to cut there (`AppDB/ConversationGrouper.swift:188-197`): a cut would snap to
the nearest 15-minute join, "usually mid-sentence", away from the change it claims to mark.

**Time is what the user remembers.** "Tuesday afternoon", "the morning we went to the market",
"a weekend a few weeks ago". An always-on recorder produces a diary, and a diary is read by
date.

**Parts of the Library are already dead on real data.** Its "mostly quiet" and "missing audio"
row flags read a table (`coverage_days`) that nothing writes. Its data source rebuilds every row
of the archive on every tracked write, twice, which breaks both battery rules in `CLAUDE.md`.

---

## 3. Goals, non-goals and principles

### Goals

1. Answer "what happened at time T on day D" in two taps and one scan: open the day, read down
   to the hour, tap, land in the transcript at that moment.
2. Make yesterday readable in about 20 seconds, a week in one screen's worth of scrolling, and a
   month in one more.
3. Keep the product's honesty rule visible where it matters: quiet, paused and lost audio are
   three different things on the day, and nothing is claimed that the app cannot back up.
4. Keep everything the Library does that people rely on: search, tags, opening a conversation,
   deleting one with undo.
5. Cost nothing in the background that the app does not already spend, and nothing at all while
   the tab is off screen.

### Non-goals

- Changing how audio is grouped into conversations, or the conversation detail screen beyond
  what is needed to land at a time.
- Classifying non-conversation audio. History consumes that; another task builds it.
- A pinch-to-zoom continuous canvas, a calendar month grid, or editing chapter boundaries by
  hand. Each was considered and left out ([5.10](#510-decisions-and-rejected-alternatives)).
- Android. The native iOS app is the only target.

### Principles

These came out of the mockup rounds and settle most detailed questions.

1. **Time is steady.** On the day, equal time takes roughly equal height. Content flexes to fit
   time, never the reverse.
2. **Recording is the normal state, so it is not information.** Week and Month show no coverage
   strips and no loss notes. The Day shows exceptions where they happened.
3. **Never make a claim the app cannot support.** A descriptor such as "music" appears only when
   it was determined accurately. Otherwise the app says less.
4. **A row points into a recording; it never replaces it.** Chapters are a reading aid over the
   conversation. Tapping one opens the real transcript at that time.
5. **One shape at every level.** In-brief card, then rows of headline, summary, pills,
   follow-ups. Learning the week teaches the month.
6. **Platform first.** Standard segmented control, toolbar buttons, paging and back-swipe
   behaviour. No custom gestures that fight the system.

---

## 4. User stories

Each story lists what the user does and what has to be true for it to work.

**1. Recall by time.** *"What was that thing around 3 on Tuesday?"*
Open History, swipe back to Tuesday (or tap Tuesday in the week), read down the hour axis to
3 PM, tap the card. The conversation opens with the transcript scrolled to the chapter's first
line and the player cued there.
Needs: a steady hour axis; chapters anchored to real transcript turns; a route that scrolls the
transcript to a wall-clock time.

**2. Morning review.** *"What did yesterday hold, and what do I owe people?"*
Open History on Day, swipe once to yesterday, read the brief, skim card titles, see open
follow-ups inside the cards they came from.
Needs: yesterday's chapters and brief ready by morning; follow-ups attached to the right
chapter; done follow-ups shown as done.

**3. Weekly review.** *"How did the week go?"*
Switch to Week. Read the brief, then seven rows. Tap a day that needs a closer look.
Needs: a headline and a two-line summary per day; a week brief; tags per day.

**4. Long-range find.** *"It was a weekend a few weeks ago, while we were planning the garden."*
Switch to Month, scan week rows for the "apartment" pill, tap the week, tap the Saturday.
Needs: tags rolled up by week and month; week briefs.

**5. Trust check.** *"Was the 2 PM meeting recorded?"*
Open the day. 2 PM is either inside a card, or inside a gap that says Quiet, Paused or Audio
missing with a duration and a cause.
Needs: the day drawn from coverage data, with loss never hidden; works even when no AI has run.

**6. Skip dead time.** Nights and long quiet stretches should cost little.
The timeline starts at the first recording and ends at the last, with one line at each end.
Quiet inside the day keeps its true height (so the scale stays honest) but carries no content.

**7. Recall by topic or word.** *"Where did we talk about the invoice?"*
Tap search in the toolbar. Results open the conversation at the match, as today. Tapping a topic
pill anywhere lists the chapters with that tag.
Needs: the Library's search kept as is; a tag results list over chapters.

**8. What is happening now.** On today, the timeline ends in a Live card at the current time
that opens the Live screen.

**9. Jump to a date.** *"What happened on the 3rd?"*
Tap the calendar button, pick a date. Days with recordings are marked; days outside the
recorded range are disabled.

---

## 5. Design specification

Reference mockups: `round10-background-audio` (Day), `round5-week-followup-state` (Week),
`round4-white-blocks-followups` (Month), `round3-today-and-week-text-tags` (today's Live card).
Where a mockup and this section disagree, this section wins.

### 5.1 Structure and navigation

- **Tab.** The Library tab becomes **History** (SF Symbol `clock.arrow.circlepath`), in the same
  position. Tabs: Today, History, Follow-ups, Ask, Settings.
- **One root screen.** Day, Week and Month are a state of `HistoryScreen`, not pushed screens.
  Horizontal paging inside a pushed screen would fight the back-swipe, and a zoom level is a way
  of looking at the same place in time, not a new place.
- **Level control.** A segmented control, Day | Week | Month, directly under the toolbar. It is
  always visible. Changing level keeps the date in focus: Day on Tuesday the 22nd → Week shows
  the week containing the 22nd → Month shows September.
- **Title.** Large, two lines, left-aligned under the control:
  - Day: "Tuesday" / "September 22". Today: "Today" / "Saturday, September 26". Yesterday is
    written as its weekday, not "Yesterday" (the title has to stay unambiguous after midnight).
  - Week: "Sep 20 – 26" (one line). Across months: "Sep 27 – Oct 3". The year is added when it
    is not the current year.
  - Month: "September" (plus the year when not the current year).
- **Toolbar.**
  - Leading: **Today**, shown only when the period in view does not contain today. It returns to
    today at the current level.
  - Trailing: **calendar** (jump to date) and **search**. Drawn by the system as one glass
    group; no hand-made capsules (see the memory note on iOS 26 toolbars).
- **Paging.** Swipe left and right to move one day, week or month. The range is bounded: from
  the period holding the first recording to the period holding today. There is no page beyond
  either end, and the scroll view rubber-bands there.
- **Drill down.** Tapping a day row on Week switches to Day on that date. Tapping a week row on
  Month switches to Week on that week. Both are level changes with an animated transition, not
  pushes, so the segmented control always tells the truth about where you are.
- **Re-tapping the History tab** while on it scrolls the current page to the top; a second tap
  returns to today. (Photos does the same: re-tap means "back to now".)
- **Pushes.** Only leaving History pushes: a chapter or no-conversation gap → conversation
  detail; the Live card → Live; search results → conversation detail; a tag → tag results.
- **Restoration.** The level and the date in view are kept for the session. A fresh launch opens
  on Day, today.

### 5.2 The in-brief card

Every level starts with one white card:

- Header: sparkles icon in tint, then "The day in brief" / "The week in brief" / "The month in
  brief". On today: "Today so far".
- Body: the period's summary, 14 pt, secondary-dark (`#3C3C43`), no clamp.
- Footer, 13 pt gray: follow-up count and state, for example "4 follow-ups · 2 open". On today
  it adds "· updated 11:15 AM". Tapping the footer opens the Follow-ups tab filtered to that
  period.
- Month only: a row of tag pills with counts under the body ("apartment 9", "work 7"). The count
  is the number of days the tag appears on.
- When there is no summary yet, the card shows one gray line instead (see
  [5.8](#58-states)). The card is never a spinner.

### 5.3 Day

The day is a logical day, 5 AM to 5 AM, the same boundary the rest of the app uses.

#### Layout

```
 gutter (58 pt)   content
 ┌──────────────┬───────────────────────────────────────────┐
 │       ┊      │ Quiet until 8:12 AM                        │  dashed axis
 │  9 AM ┼──    │ ┌─────────────────────────────────────────┐│
 │       │      │ │ Coffee and sprint planning              ││  chapter card
 │       │      │ │ 8:12 – 9:00 AM · 48 min                 ││
 │       │      │ │ Ordering coffee, then sticker ideas …   ││
 │       │      │ │ (design) (👤 Oliver)                    ││
 │       │      │ └─────────────────────────────────────────┘│
 │ 10 AM ┼──    │   Quiet · 1 hr 5 min                       │  gap
 │       ┃      │   Audio missing · 3 hr 30 min              │  amber bar on axis
 │       ┃      │   12:38 – 4:08 PM · watch out of range     │
 └──────────────┴───────────────────────────────────────────┘
```

- A continuous 1.5 pt axis line runs down the gutter at x = 50 pt. Hour labels (12 pt gray,
  right-aligned, "9 AM") sit on it with a short tick, each at the y where that hour falls.
- Cards and gaps stack in the content column in time order, 6 pt apart. (Chapters inside one
  stretch of talk follow each other with no gap in time, so the cards need that separation.)

#### The time scale

This is the rule the whole day hangs on. It took five rounds to get right.

- **Floor:** every minute inside the day takes at least **70 / 60 = 1.1667 pt**. An hour is
  never shorter than 70 pt, whatever it contains. Long gaps are **not** collapsed.
- **Chapter height:** at least `duration × 1.1667 pt`. A chapter aims to stay under
  `duration × 3 pt` (180 pt per hour). To get there, in order:
  1. the summary's line limit is reduced, down to one line;
  2. follow-ups collapse to the first open one plus "N more".
  Title, time line, one summary line and pills are the floor, so a very short chapter may exceed
  the band. Chapters under 25 minutes show no summary at all.
- **Long chapters get long summaries**, so a two-hour card is filled with text and not with
  white space. The summary stage writes to a target length derived from the duration
  ([7.3](#73-the-chapter-stage)).
- **Gap height:** `duration × 1.1667 pt`, minimum 8 pt. A gap that carries a label (paused,
  missing, no conversation) is at least 44 pt.
- **Hour labels:** the y of a time inside an item is interpolated linearly between the item's
  top and bottom. A label is skipped when it would sit less than 17 pt below the previous one.
- **The ends of the day:** the timeline starts at the first recording and ends at the last. One
  line sits above it on a dashed axis, "Quiet until 8:12 AM", and one below, "Quiet after
  9:44 PM". This is the only place time is compressed.

#### Chapter card

White, the app's card radius (12; the mockups drew 14), padding 10/13/11.

| Element | Spec |
|---|---|
| Title | 16 pt semibold, up to two lines. |
| Time line | 12 pt gray: "9:05 – 10:15 AM · 1 hr 10 min". The meridiem appears once when both ends share it. When audio was lost inside the chapter, an amber suffix: "· 4 min missing". |
| Summary | 14 pt, `#6E6E73`, line limit set by the fitting rule. None under 25 minutes. |
| Pills | Topic pills: tint text on 10 % tint. People pills: dark gray text on `#EFEFF4` with a person icon. 11 pt medium, radius 9. Up to three topics, then people. |
| Follow-ups | Below a hairline. Each: circle (open) or checked circle (done, dimmed), 14 pt text, one line, truncated. Open ones first. |

Tapping the card opens the conversation at the chapter's start
([7.9](#79-navigation-routes-and-deep-links)), with the transcript scrolled there and nothing
highlighted. Tapping a follow-up line opens that follow-up. The circles do not toggle. A long
press offers: Open, Share summary, Copy summary.

#### Gap kinds

| Kind | Axis | Label | Second line | Tappable |
|---|---|---|---|---|
| **Quiet** | bare line | gray "Quiet · 1 hr 5 min", only when the gap is 30 min or longer | the time range, when over 90 min | no |
| **Paused** | tint diagonal stripes, 5 pt wide | tint "Paused · 30 min" | "2:30 – 3:00 PM · you paused capture" | no |
| **Audio missing** | solid amber, 5 pt wide, for the whole stretch | amber "Audio missing · 3 hr 30 min" | time range · the recorded cause, if there is one | no |
| **Not recording** | dashed line (the axis itself breaks) | gray "Not recording · 2 hr 10 min" | time range | no |
| **No conversation** | see below | | | yes |
| **Not transcribed yet** | bare line | a dashed-outline card, gray title "Not transcribed yet", time range | | yes, opens the recording |
| **Transcription failed** | bare line | the same dashed card, title "Could not be transcribed", the reason | | yes, opens the recording |
| **Deleted** | dashed line | gray "Deleted by you · 40 min" or "Removed to save space · 40 min" | time range | no |

**Causes are only ever ones the app recorded.** The mockups show "watch out of range"; the app
does not know that. The real phrases come from the watch's and phone's gap records: "watch
buffer filled while disconnected", "connection was interrupted", "watch dictation used the
mic", "paused for watch battery", "phone missed audio". When a gap has no recorded cause the
second line is just the time range.

**Not recording** is time inside the day for which there is no audio and no record of why (the
watch was off, or capture was switched off). It is not quiet, because nobody was listening, and
it is not called missing, because nothing says audio was lost. It needs Roger's eye; see
[section 11](#11-decisions-roger-still-has-to-make).

**A change of time zone** inside a day is a thin divider across the content column, "Times from
here in Jakarta time". Hour labels below it use the new zone.

**No conversation** has two forms, and the choice is made by data, never by guesswork:

- **With an accurate descriptor:** a soft gray 5 pt bar on the axis, "Background audio · 45 min"
  in `#6E6E73`, second line "1:15 – 2:00 PM · music, no conversation", and a chevron.
- **Without one** (the classifier is not confident, or has not run): styled exactly like quiet,
  gray "No conversation · 45 min", plus a chevron because the audio exists and can be opened.
  Like quiet, it is labelled only at 30 minutes or more.

Both open the conversation at that time. Neither becomes a chapter, feeds follow-ups, or is
mentioned in a brief. A stretch of sound without conversation shorter than 15 minutes is not
drawn separately; it is part of the surrounding quiet.

**Label position.** A gap's label is vertically centred in the gap. While scrolling it is pinned
at both edges: its resting place is the middle of the gap, clamped to the visible part of the
scroll view and to the gap itself. So as a long gap scrolls out at the top the label slides to
the gap's bottom edge and stays readable, and as it comes in from below the label is at the
gap's top edge. It is never off screen while a usable part of its gap is on screen.

#### Today

- The title is "Today", the brief header "Today so far".
- The timeline ends in a **Live card**: white, 1.5 pt green outline, title "Recording now", a
  green "Live" badge, time line "11:20 AM · 21 min so far", and the last line of the live
  transcript in italics. It opens the Live screen.
- The axis carries a green "now" marker at the current time in place of an hour label.
- There is no "Quiet after" line. When capture is paused or the watch is away, the Live card is
  replaced by the matching gap, open-ended ("Paused since 2:30 PM").
- Chapters for the part of today that is still being talked through appear as they settle; the
  unsettled tail is covered by the Live card.

### 5.4 Week

A week follows the device's calendar (Sunday or Monday first, from the locale). The page is the
in-brief card, then one white card holding seven rows, oldest first.

Each row:

| Element | Spec |
|---|---|
| Date column | 34 pt wide: weekday (11 pt gray, "Tue") over day number (20 pt medium). Today's number is tint. |
| Headline | 16 pt semibold, one line. Today: "Today" in tint. |
| Summary | 13 pt `#6E6E73`, **two lines**. |
| Pills | Up to three topic pills. No people pills. |
| Follow-ups | Up to **two**, 13 pt, open ones first, then done ones (checked, dimmed). When there are more: a gray "3 more" line. The circles are **not** tap targets; they are too small to hit. |
| Chevron | Trailing, vertically centred. |

- The whole row opens that day.
- **No coverage strip and no missing-audio note.** Loss is shown on the day.
- A day with recordings but no transcripts yet: gray headline "Not transcribed yet", summary
  "13 hr waiting to transcribe".
- A day with no recordings: gray "Nothing recorded", no chevron, not tappable.
- Future days in the current week are not listed.
- The page may run past the fold. The two-line summaries stay.

### 5.5 Month

A calendar month. The page is the in-brief card (with tag pills and counts), then one white card
holding a row per week that overlaps the month, oldest first.

Each row:

| Element | Spec |
|---|---|
| Date range | 12 pt gray, "Sep 20 – 26". The current week adds "· This week" in tint. A week that straddles two months appears in both. |
| Headline | 16 pt semibold, one line. |
| Summary | 13 pt, two lines. |
| Pills | Up to three topic pills. |
| Follow-ups | One gray line: "16 follow-ups · 11 open". No items. |
| Chevron | Trailing. |

- The row opens that week.
- No calendar grid. The toolbar's calendar button covers jumping to a date, and a grid of
  day cells cannot carry the text that makes a week recognisable.

### 5.6 Follow-ups in History

- State is always true: a done follow-up shows a checked circle and dimmed text, everywhere.
- Where only some are shown (two per day on the week, one in a collapsed chapter), open ones
  come first, then done ones, each in the order they came up.
- "N more" counts everything not shown, open or done.
- Follow-ups are not ticked off from History. On the day, tapping a follow-up line opens that
  follow-up; on the week the row opens the day. The Follow-ups tab is where they are managed.
- A follow-up belongs to the chapter whose time range contains the moment it was said. When that
  moment is unknown it belongs to the day only: it counts in the brief's footer and the week
  row, and is not drawn inside any chapter. It is never attached by guess.

### 5.7 Jump to date, search, tags

- **Calendar button** → a medium-detent sheet with a month calendar. Days with recordings carry
  a dot; days outside the recorded range are disabled. Picking a day closes the sheet and shows
  that date at the current level.
- **Search button** → the existing search view (field, recents, results opening a conversation
  at the match) takes over the History content in place, as it does in the Library today.
  Cancel returns to the same page. No redesign in this project.
- **Tag pill** (any level) → a pushed list of chapters carrying that tag, newest first, grouped
  by day, each row in the week-row style and opening its chapter.
- **Delete** stays on the conversation detail screen, with the existing undo. History has no
  swipe-to-delete: a chapter is not a thing that can be deleted on its own, and a swipe on a
  paged screen is already taken.

### 5.8 States

| Situation | What the screen shows |
|---|---|
| No recordings at all | One centred message, "Nothing recorded yet", and a line pointing to Today. No level control content, no paging. |
| A day with no recordings | Title as usual; "Nothing recorded" in gray; no timeline. Reachable only inside the recorded range. |
| Recorded, not transcribed | The day shows dashed "Not transcribed yet" cards over the recorded stretches, with gaps drawn as normal. The brief card says "Waiting to transcribe". |
| Transcribed, chapters not made yet | The day is drawn from conversations clipped to the day: one card per conversation stretch, using the conversation's existing title, no summary length fitting. The brief card shows the day recap if there is one. A gray line under the brief: "Topics are being prepared". |
| AI turned off | Same fallback, permanently, without the "being prepared" line. History has to be useful with no AI at all. |
| Chapter stage failed | Same fallback. No error banner on History; the failure is reported where the other AI failures are (Settings → Diagnostics). |
| Brief missing | The card shows "No summary yet" in gray. |
| Approximate times | When a chapter's times come from a segment whose clock is inexact, the time line is prefixed with "about". |
| Loading | The previous content stays until the new page's data is ready. First load shows the frame (title, control, empty card outlines), never a full-screen spinner. |

### 5.9 Accessibility

- **Dynamic Type.** All text uses the app's scaled fonts. The time scale is in points per
  minute, so at large sizes the card floor (title, time, one summary line, pills) exceeds the
  band more often; the scale's minimum then grows with the type size (70 pt × the body font's
  scale factor, capped at 1.5×) so hours stay comparable. Hour labels stop growing at the
  second accessibility size so the gutter keeps its width.
- **VoiceOver.** A chapter reads as one element: title, time range, duration, summary, tags,
  people, "2 follow-ups, 1 open"; each follow-up is also a named action. A gap reads as "Quiet, 1 hour 5 minutes, 10:15 to 11:20 AM".
  The hour axis is hidden from VoiceOver; times are in each element. The level control is
  announced as tabs. Paging is exposed as an adjustable action ("next day", "previous day") on
  the title, since swipes are taken by VoiceOver.
- **Colour is never the only signal.** Every gap kind has a word. Done follow-ups change icon
  as well as colour.
- **Reduce Motion.** Level changes cross-fade; the pinned labels still track (they are position,
  not animation).
- **Contrast.** Gray label text on the ground colour is at least `#8A8A8E` for anything that
  carries information; the lighter `#B0B0B6` is used only for the word "Quiet".
- **Targets.** Rows and cards are full-width targets. Nothing smaller than 44 pt is tappable.

### 5.10 Decisions and rejected alternatives

| Decision | What was tried and dropped | Why |
|---|---|---|
| Segmented Day / Week / Month on one screen | Pushed screens per level; a pinch-zoom canvas; a calendar-first screen | Paging fights back-swipe; pinch is undiscoverable and has no accessible equivalent; a calendar shows dates, not content. |
| No coverage strips on Week or Month | A purple recorded-time strip per row | "We can assume it's nearly always recording." It carried no information. |
| No loss notes on Week or Month | "12 min missing" per row | Noise at that distance. Loss is shown where it happened. |
| White cards on the day | Tinted calendar-style blocks; a card with a curved coloured left border | Tinted was "a bit much"; the curved border "doesn't look good". |
| Hour axis with labels at every hour | Start-time-only labels per card | "Disorienting" with nothing regular to read against. |
| Steady scale with a floor per hour | Height driven purely by content; strict fixed-height hours | Pure content made 2–3 PM four times the height of 7–8 PM; fixed hours wasted space and clipped busy ones. |
| Never collapse gaps inside the day | Collapsing gaps over 90 min into a short "break" | "Still feels disorienting." Only the two ends compress. |
| 70 pt per hour | 105, 90, 80 | 70 kept the day to about three screens without cards feeling cramped. |
| One line at each end of the day | "Quiet until 7 AM" plus a separate "Quiet · 30 min" | Two labels for one stretch. |
| Gap labels centred and pinned at both edges | Label at the gap's top | Looked misplaced in a tall gap and scrolled away. |
| Tags as pills | A dotted line of text ("apartment · work") | Pills match the rest of the app. |
| Two follow-ups per day on the week, not tappable | One; a tappable circle | Two is enough to be useful; the circle is too small to hit. |
| Month as week rows | A calendar grid with dots | A grid cannot carry the words that make a week findable. |
| "No conversation" without a descriptor unless accurate | Always showing a reason | A false "music" is worse than saying less. |


---

## 6. What exists today

Paths are relative to `pebble-audio-companion/ios/`. `Kit/` stands for
`PebbleAudioKit/Sources/`. Every claim here was read in the code on 2026-09-30.

### 6.1 The screen being replaced

- `App/Screens/Library/LibraryScreen.swift` — title row, filter menu, search field, tag chips,
  day sections of conversation rows, the delete-undo snackbar (`:50`, the only host of it).
- `App/Screens/Library/DataSources.swift` — `LibraryDataSource`, `ConversationDataSource`,
  `FollowUpsDataSource`, the `AskLibraryDataSources.current` holder, `UndoCenter`, `TimeFmt`.
- `App/RootView.swift:30-32` — the tab. `App/AppRouter.swift` — `Tab.library`, `libraryPath`,
  `pendingLibraryTag`; `navigate(to:)` sends conversations, notes and search to the Library tab.
- `App/Router.swift` — `Route` and the `companion://` URL scheme.

### 6.2 Data that History can use as is

| Need | Source |
|---|---|
| Segments of a day | `SegmentStore.listSegments()`, an in-memory index; no disk read. |
| Recorded, quiet, missing, paused, off | `Kit/AppDB/CoverageComputer.swift` (`compute`, `:156`) over segment metas, gap records and `pause_intervals`; quiet re-cut in `LiveTimeline`. |
| Causes of loss | `gapDescription` in `Kit/StatusUI/GapStatus.swift:34-60`: "watch buffer filled while disconnected", "connection was interrupted", "watch dictation used the mic", and so on. |
| Day recap | `recaps` table (`text`, `shortText`), one row per logical day. `DailyRecapStore.load(dateKey:)` works for any day; the UI only ever asks for today. |
| Conversations and their titles | `conversations`, `conversation_segments`, `annotations`. |
| Tags | `tags`, `conversation_tags`. |
| Follow-ups | `follow_ups` (`done`, `archivedAtMs`, `snoozedUntilMs`, `sourceSegmentId`, `sourceStartMs`). |
| Transcript turns with timings | `transcription/transcripts/<segmentId>.transcript.json`; `FileTranscriptStore.loadSpeechTimings` decodes turns without words. |
| Media time → wall time | `SegmentMediaClock.wall(fromMedia:)`, valid when `isExact`. |
| Logical day | `LogicalDay` (5 AM boundary), `Kit/AppDB/CoverageComputer.swift:74`. |

### 6.3 Data that does not exist

- Any summary below a conversation: no chapters, no per-hour text. (Two recaps contain `HH:mm:`
  paragraphs; that is a truncation artefact of an on-device run, not a format.)
- Week and month summaries. A headline or one-line summary for a day.
- Wall-clock time on a follow-up. `sourceStartMs` is an offset into the segment's media.
- A lookup from a wall-clock time to a conversation and a transcript position.
- Week and month calendar helpers.
- A verdict on audio that has sound but no conversation
  ([7.6](#76-audio-with-no-conversation-an-external-dependency)).

### 6.4 The AI pipeline History extends

`Kit/CompanionRuntime/Services/PipelinePass.swift`. Stage order: …regroup → enrich → donate →
followUps → recap → liveLocal…

- AI stages run when `aiStagesDue = foreground || groupingChanged || aiStagesLeftWork` (`:368`).
  Recap is further limited to once per 15 minutes in the background (`:172`).
- Heavy stages are skipped while the phone is hot and carry their own failure backoff.
- `DailyRecapEngine` (`Kit/Intelligence/RecapEngine.swift:248`) is the model to copy: it buckets
  segments by logical day, fingerprints each day by `(segmentId, transcriptionState)`, keeps
  settled days in memory so an unchanged day costs no reads, debounces 30 minutes, map-reduces
  days that do not fit one call, refuses a cut input, and backs off on failure.
- Capacity: about 8,000 characters per on-device call (16,000 on iOS 27); a cloud model with a
  1M-token window takes a whole day in one call.
- The on-device model is deliberately kept away from judgement calls
  (`Kit/Intelligence/Providers/OnDeviceStructuredOutput.swift:30-34`): "judgement is the thing it
  measurably cannot do".

### 6.5 Problems found on the way, which the plan has to deal with

1. **New recordings carry no time zone.** `SegmentStore.openSegment` never sets
   `recordedTimeZone` (`Kit/SegmentStore/SegmentStore.swift:364-380`); 3 of 866 segments in the
   backup have one. Every consumer falls back to the phone's current zone, so past days are
   re-dated when the phone changes zone. This cannot be backfilled. Fixed separately the same
   day (commit `9baad3e`, "segmentstore: stamp recordedTimeZone on every newly opened
   segment"); recordings made before it stay unstamped and History tolerates that.
2. **Retention deletes text, not just audio.** `RetentionService` runs the full delete cascade
   for every evicted segment, which removes its transcript, follow-ups and any recap that quoted
   it. Defaults are 30 days or 2 GB. So on default settings History reaches back about a month
   and then empties from the far end. See [11](#11-decisions-roger-still-has-to-make).
3. **Two loss classifiers disagree.** `CoverageComputer.isVisibleLoss` (`:135-141`) treats the
   watch's power-save mute as a pause; `GapVisibility.isVisibleLoss`
   (`Kit/StatusUI/GapStatus.swift:119-124`) counts it as loss, and only the second excuses a
   sequence skip inside a silence gap. History needs one answer.
4. **An invented cause.** `Copy.Popover.missingSpan` (`App/DesignSystem/Copy.swift:1176`) appends
   "— Bluetooth" to every missing span. The mockups' "watch out of range" is likewise not
   something the app records. History shows only causes the gap records give.
5. **Time with no record at all.** Stretches between recordings with no gap record come out of
   the coverage computer as `off`. Today draws nothing for them. On History's day they need
   their own honest label ([5.3](#53-day), "Not recording").
6. **Conversation ids are not stable.** On a split only the first half keeps its id. Anything
   History stores must be anchored on segment ids and times, never on a conversation id.
7. **Every conversation read builds the whole library.** `ConversationQueries.buildDetail`
   (`Kit/AppDB/ConversationQueries.swift:431`) calls `buildRows` for every conversation and picks
   one. There is no index on `conversations.startMs`.
8. **`coverage_days` is never written**, so the Library's "mostly quiet" and "missing audio"
   flags and its "with missing audio" filter are dead.
9. **The undo snackbar lives on the Library screen only.** A delete made from a conversation
   opened from Today shows no Undo.

---

## 7. Architecture

### 7.1 Overview

```
 segments + gap records + pauses ─┐
 transcripts (turns, timings) ────┼─► [chapters stage] ─► day_chapters, chapter_tags
 audio-content spans (external) ──┘         │
                                            ▼
 recaps (exists) ─► [briefs stage] ─► recaps.headline/lineSummary, period_briefs
 follow_ups ─► wall-time columns (at extraction)

 ───────────────────────────── read side ─────────────────────────────
 HistoryDayBuilder (pure) : coverage + chapters + follow-ups + content spans ─► HistoryDay
 period queries           : recaps + period_briefs + chapter_tags + follow_ups ─► week / month
 LiveHistory (data source): windowed, digest-gated, visibility-gated ─► HistoryScreen
```

Three layers, each testable on its own:

1. **Write side (pipeline).** Two new stages produce chapters and briefs. They follow the recap
   engine's discipline: work is proportional to what changed.
2. **Read side (pure builders and queries).** A day is assembled by a pure function from inputs
   that are already cheap to get. Weeks and months are plain queries.
3. **Screen.** One SwiftUI root with a data source that reads a window of time and is silent
   when nothing changed or when the tab is hidden.

History works at every stage of that pipeline being absent. With no chapters it draws
conversations clipped to the day. With no briefs the cards say so. With AI off it stays in that
state and is still a correct record of when recording happened.

### 7.2 The unit: chapters

A **chapter** is a stretch of one day's talk about one subject. It is a new layer beside
conversations, not a change to them.

- Keyed by logical day. A chapter never crosses the 5 AM boundary.
- Anchored on transcript turns: it stores the segment id and turn index of its first and last
  turn, and its wall-clock start and end taken from those turns.
- It stores **no conversation id**. The conversation is looked up when a chapter is tapped,
  through `conversation_segments.segmentId`. Conversation ids move when a split moves; segment
  ids do not.

Why not make conversations finer: membership is whole segments, every per-conversation record
is keyed by conversation id, and AI output would then rewrite the grouping, which the code
forbids on purpose (`EnrichmentService.swift:120-125`). Topic boundaries shift every time a tail
is re-read; conversation ids would shift with them and orphan notes and tags.

### 7.3 The chapter stage

New: `DayChapterEngine` (actor), `DayChapterStore`, `ChapterInputBuilder`,
`ChapterSummaryBudget`, in `Kit/Intelligence/` and `Kit/AppDB/`. Stage `.chapters` between
`.donate` and `.followUps`, `heavy: true, when: aiStagesDue`.

**Input.** For each day, the closed segments overlapping the day window. Turns come from the
stored transcripts with looped artefacts collapsed (`withLoopedArtefactsCollapsed()`), each
placed on the wall clock by one shared helper, `SegmentMediaClock.wallRange(of:in:)`, extracted
from the inline conversion at `Kit/AppDB/ConversationBoundaries.swift:326-338` and used
everywhere a turn is placed on the wall clock. A chapter that includes a segment whose clock is
not exact is stored with `timesApproximate`.

Turns become numbered **lines**: consecutive turns by the same speaker are merged up to 60
seconds and written as `L412 2:14 PM S2: …`.

**Stretches.** The day is cut deterministically, before any model is asked, into stretches at:

- the day boundary;
- any segment that is not transcribed (pending, failed, disabled) or has no speech;
- recorded loss, and pauses;
- a gap of 8 minutes or more with no speech (`quietCandidateMs`, the grouper's own threshold);
- the edges of any span the audio classifier has marked as no conversation
  ([7.6](#76-audio-with-no-conversation-an-external-dependency)); lines inside such a span are
  left out.

A stretch is the unit of work and of recomputation. Its key is a hash of
`(segmentId, transcriptionState, transcript version)` for its segments, plus the classifier's
version for the day. A chapter can never span a gap, so the day view's gaps and the chapters can
never disagree.

**Cloud path: two calls per changed stretch.**

1. `day-chapters` — strict JSON:
   `{"chapters":[{"startLine": 412, "title": "…", "tags": ["…"], "people": ["…"]}]}`.
   The model returns **line numbers only**, never times. The engine checks that the first
   chapter starts at the stretch's first line and that line numbers strictly increase; any
   violation is a content failure and nothing is stored. Times are read from the real turns.
2. `day-chapter-summaries` — each chapter's lines with a target length, for example
   `Chapter 3 (2 h 05 min): write about 270 characters`.

**Summary length.** `ChapterSummaryBudget.targetCharacters(durationMs:)` returns nil under 25
minutes (no summary), otherwise about `2.6 × minutes − 60` characters: one line at 40 minutes,
five to six lines at two hours. The constants live in one place and the day layout reads the
same ones, so the text is written to the space it will be given. A shorter answer is accepted;
the layout clamps a longer one.

**Tags.** The 40 most used tag names are given to the model as preferred vocabulary. Chapter
tags are stored by tag id in a new `chapter_tags` table (same normalisation as
`TagStore.tagId`, so renames carry through). They are not written to `conversation_tags`.

**People.** A name is kept only when it appears in the chapter's own lines or matches the
`people` table. Speaker labels are per segment and are a hint, not proof.

**On-device path.** Used in Local Only, and whenever Local First really runs locally. The model
is not asked where topics change. The engine cuts each stretch by rule (at speech gaps of 3
minutes or more, no chapter over 90 minutes or under 10) and the model writes only the title,
tags and summary for each piece, which is the job it already does for conversations. The UI
copy does not change between the two paths; the cards are simply coarser.

**Today.** A chapter **settles** when a hard break or 45 minutes of later speech follows it.
Settled chapters are never rewritten, so their ids and the screen stay still. The unsettled
tail is re-read at most every 30 minutes in the foreground (15 in the background, like the
recap), with the settled chapters passed in as context. Late-arriving audio inside a settled
stretch changes that stretch's key, and only that stretch is redone.

**Change detection.** Unchanged days are memoised in memory by their segment set, as the recap
does; after a relaunch one read of `day_chapter_state` restores them. A changed day recomputes
only the stretches whose key changed and swaps them in one transaction
(`replaceStretch(dateKey:stretchKey:with:)`).

**Failures.** Retry state is persisted in `day_chapter_state` and follows `AiRetryPolicy`. A
cut input is never stored. Both templates join `AiInputPolicy.wholeInputTemplateIds`, so a
provider refuses rather than truncates.

**Cost.** Cloud: a fully recorded day is roughly 3 to 8 calls, about twice the day's characters
in input, a few thousand tokens out. On-device: one call per 8,000 (or 16,000) characters, 20
to 40 for a heavy day, at most 4 per pass.

```swift
public struct DayChapter: Equatable, Sendable, Identifiable {
    public var id: String                    // "ch-<startSegmentId>-<startTurnIndex>"
    public var dateKey: String
    public var startMs, endMs: Int64         // wall clock, from real turns
    public var startSegmentId: String; public var startTurnIndex: Int; public var startMediaMs: Int64
    public var endSegmentId: String;   public var endTurnIndex: Int
    public var title: String?; public var summary: String?
    public var tags: [String]; public var people: [String]
    public var timesApproximate: Bool; public var isSettled: Bool
}

public struct DayChapterStore: Sendable {
    public func chapters(dateKeys: ClosedRange<String>) async throws -> [DayChapter]
    public func replaceStretch(dateKey: String, stretchKey: String, with: [DayChapter]) async throws
    public func dateKeys(touchingSegment id: String) async throws -> [String]
    public func deleteChapters(touchingSegment id: String) async throws
}

public actor DayChapterEngine {
    public func refresh(onProgress: (@Sendable () -> Void)?) async throws -> Bool   // true = left work
    public func resetFailureBackoff()
}
```

### 7.4 Briefs

**Day.** The day brief is the existing recap. Three columns are added to `recaps`: `headline`,
`lineSummary`, `briefOfHash`. One structured call turns the recap text into a headline (up to
about 45 characters) and a two-line summary (up to about 150), guarded by a hash of the text in
the same way `shortOfHash` guards the condensed recap. These feed the week rows.

**Week and month.** New table `period_briefs`, new `PeriodBriefEngine` and `PeriodBriefStore`,
new stage `.briefs` after `.recap`.

- A week brief is written from its seven day recaps (the condensed text where there is one) and
  their headlines: about 4,500 characters, which fits even the on-device model.
- A month brief is written from its week briefs.
- Each has `text` (for the in-brief card), and a `headline` and `lineSummary` (for the month's
  week rows).
- The source fingerprint is a hash of the members' keys and text hashes. A brief regenerates
  only when it changes, and no more often than every 3 hours for the current week and once a
  day for the current month. A past period regenerates only if one of its days changed.

**Tags are counted, not generated.** Per day and per week: the top three tags by total chapter
duration. For the month card: tags with the number of days they appear on.

```sql
-- top tags for a range of days
SELECT t.name, SUM(c.endMs - c.startMs) AS ms, COUNT(DISTINCT c.dateKey) AS days
  FROM chapter_tags ct JOIN day_chapters c ON c.id = ct.chapterId JOIN tags t ON t.id = ct.tagId
 WHERE c.dateKey BETWEEN :first AND :last
 GROUP BY t.id ORDER BY ms DESC LIMIT :n;
```

### 7.5 Follow-ups on the clock

A follow-up has to be placed in time to sit in the right chapter.

- **New columns** `sourceWallStartMs`, `sourceWallEndMs` on `follow_ups` and
  `follow_up_candidates`, written in `FollowUpWorker.persist` from the located quote, using the
  shared wall-time helper. Once stored they survive the segment being deleted.
- **Existing rows** are filled by a one-time pass over rows that have a `sourceSegmentId`, a
  `sourceStartMs` and a segment still on disk. In the backup that is about 30 rows.
- **Placement at read time**, in this order:
  1. wall time present → a moment → the chapter containing it;
  2. no wall time but the segment exists → the segment's span → the chapter holding at least
     80 % of it, otherwise the day only;
  3. segment gone → the receive time embedded in the segment id gives an approximate day; day
     only;
  4. written by hand (no segment) → the day it was created; day only.
  `createdAtMs` is never used for extracted follow-ups: it is when extraction ran.
- **Which rows count.** Open and done ones. Snoozed ones count as open. Archived ones are left
  out (481 of 511 rows in the backup are archived legacy rows with no quote).
- **Order.** Open first, then done, each by time.

### 7.6 Audio with no conversation: an external dependency

Deciding that a recorded stretch holds no conversation, and what it holds instead, is **not
part of this project**. A separate backend task owns it (task chip "Classify recorded audio that
holds no conversation"). This section is the contract between the two.

**What History needs from it**

```swift
public struct AudioContentSpan: Equatable, Sendable {
    public enum Kind: String, Sendable { case conversation, noConversation }
    public var startMs, endMs: Int64     // wall clock; spans for a day do not overlap
    public var kind: Kind
    public var descriptor: String?       // e.g. "music", "TV or video". Present ONLY when the
                                         // classifier met its accuracy bar for that label.
    public var confidence: Double
    public var decidedBy: String         // which signal or model decided
    public var version: Int              // bumps when the verdict for this stretch changes
}

public protocol AudioContentSource: Sendable {
    /// Spans overlapping the window, in time order. Time not covered by any span is unclassified.
    func spans(overlappingMs: Range<Int64>) async throws -> [AudioContentSpan]
    /// A cheap value that changes when any span overlapping the window changes.
    func digest(overlappingMs: Range<Int64>) async throws -> Int64
}
```

**Rules on History's side**

- `noConversation` with a descriptor → the "Background audio" gap with that descriptor.
- `noConversation` without one → "No conversation", styled like quiet.
- `conversation`, or unclassified time with words → chaptered as usual.
- A user correction made on the conversation screen is the classifier's to store; History just
  reads the result.
- History never derives a descriptor itself, and never shows one the source did not give.

**Delivered (2026-09-30, `docs/audio-content-classification.md`).** `AudioContentStore`
(`Kit/AppDB/AudioContentStore.swift`) implements `AudioContentSource` exactly as above, with two
clarifications and one addition: `version` is the METHOD version (change detection is
`digest`, which is content-gated — rewriting a segment with the same verdicts does not move it);
`confidence` is the measured precision of the rule that decided the span (1 for a person's
correction); and each span carries `wordCount`. Time with no span is unclassified. The only
descriptor shipped is `fewWords` (words were said, under two a minute); no `music` or
`TV or video` descriptor met the accuracy bar yet. Corrections:
`AudioContentService.correct(startMs:endMs:kind:)` / `undoCorrection(_:)`, reachable from the
app as `AppComposition.audioContent`; the store is `AppComposition.audioContentStore`. Its
migration is **`v14-audio-content`**, independent of every History table, so the two sessions'
migrations can land in either order.

**What History does before the classifier exists.** `AudioContentSource` has a built-in
fallback implementation that uses only facts the app already has: a segment the transcriber
found no words in, and wordless stretches inside transcribed segments. Those are returned as
`noConversation` with no descriptor. So the day shows "No conversation" from the first build,
and "Background audio · music" appears when the real classifier is plugged in. Audio with words
that is really a TV show will be chaptered as if it were talk until then; that is today's
behaviour everywhere in the app.

**Drawing rule**, to keep the day calm. Inside a gap between two chapters:

- recorded, wordless sound is drawn as its own item only when it runs 15 minutes or more
  (holes of up to 2 minutes are bridged);
- shorter runs are absorbed into the surrounding quiet;
- the form without a descriptor shows its label only at 30 minutes or more, like quiet, and is
  tappable only when labelled.

### 7.7 Schema

Additive migrations after `v13-follow-up-model` (`Kit/AppDB/AppDatabase.swift:511`), each in the
commit that first needs it. The classification task will add its own migration; migration
names must be agreed between the two sessions before either lands.

```sql
-- history-indexes
CREATE INDEX IF NOT EXISTS conversations_start    ON conversations(startMs);
CREATE INDEX IF NOT EXISTS pause_intervals_start  ON pause_intervals(startMs);
CREATE INDEX IF NOT EXISTS follow_ups_segment     ON follow_ups(sourceSegmentId);

-- day-chapters
CREATE TABLE day_chapters (
  id TEXT PRIMARY KEY,                 -- "ch-<startSegmentId>-<startTurnIndex>"
  dateKey TEXT NOT NULL,
  startMs INTEGER NOT NULL, endMs INTEGER NOT NULL,
  startSegmentId TEXT NOT NULL, startTurnIndex INTEGER NOT NULL, startMediaMs INTEGER NOT NULL,
  endSegmentId TEXT NOT NULL, endTurnIndex INTEGER NOT NULL,
  stretchKey TEXT NOT NULL,
  title TEXT, summary TEXT, targetChars INTEGER,
  peopleJson TEXT NOT NULL DEFAULT '[]',
  timesApproximate BOOLEAN NOT NULL DEFAULT 0,
  isSettled BOOLEAN NOT NULL DEFAULT 0,
  provider TEXT, model TEXT, updatedAtMs INTEGER NOT NULL);
CREATE INDEX day_chapters_day ON day_chapters(dateKey, startMs);

CREATE TABLE day_chapter_segments (
  chapterId TEXT NOT NULL REFERENCES day_chapters(id) ON DELETE CASCADE,
  segmentId TEXT NOT NULL, PRIMARY KEY(chapterId, segmentId));
CREATE INDEX day_chapter_segments_segment ON day_chapter_segments(segmentId);

CREATE TABLE chapter_tags (
  chapterId TEXT NOT NULL REFERENCES day_chapters(id) ON DELETE CASCADE,
  tagId TEXT NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
  rank INTEGER NOT NULL, PRIMARY KEY(chapterId, tagId));
CREATE INDEX chapter_tags_tag ON chapter_tags(tagId);

CREATE TABLE day_chapter_state (
  dateKey TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, settledThroughMs INTEGER,
  attempts INTEGER NOT NULL DEFAULT 0, transientFailures INTEGER NOT NULL DEFAULT 0,
  nextAttemptAtMs INTEGER, lastError TEXT, updatedAtMs INTEGER NOT NULL);

-- follow-up-wall-times
ALTER TABLE follow_ups            ADD COLUMN sourceWallStartMs INTEGER;
ALTER TABLE follow_ups            ADD COLUMN sourceWallEndMs   INTEGER;
ALTER TABLE follow_up_candidates  ADD COLUMN sourceWallStartMs INTEGER;
ALTER TABLE follow_up_candidates  ADD COLUMN sourceWallEndMs   INTEGER;

-- briefs
ALTER TABLE recaps ADD COLUMN headline TEXT;
ALTER TABLE recaps ADD COLUMN lineSummary TEXT;
ALTER TABLE recaps ADD COLUMN briefOfHash TEXT;
CREATE TABLE period_briefs (
  periodKey TEXT PRIMARY KEY,          -- "W2026-09-20" (first day of the week) | "M2026-09"
  kind TEXT NOT NULL,                  -- week | month
  text TEXT NOT NULL, headline TEXT, lineSummary TEXT,
  sourceFingerprint TEXT NOT NULL, provider TEXT, model TEXT, updatedAtMs INTEGER NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0, nextAttemptAtMs INTEGER);

-- deleted-spans
CREATE TABLE deleted_spans (
  startMs INTEGER NOT NULL, endMs INTEGER NOT NULL,
  reason TEXT NOT NULL,                -- user | retention
  atMs INTEGER NOT NULL);
CREATE INDEX deleted_spans_start ON deleted_spans(startMs);
```

`coverage_days` and `CoverageDayStore` are removed with the Library code.

### 7.8 Time: days, weeks, months and zones

- **Day key.** `"YYYY-MM-DD"` of the logical day (5 AM to 5 AM) in the zone the moment was
  recorded in. New `ZoneTimeline`, built from the segments' stamped zones, answers
  `zoneID(atMs:)` and `dayKey(forMs:)`; unstamped segments use the phone's current zone, as
  today. The chapter stage, the recap engine and History all take day keys from it, so there is
  one boundary at every level.
- **Week and month** are calendar arithmetic on the day key, independent of zone:
  `HistoryCalendar.week(containing:firstWeekday:)`, `month(containing:)`,
  `weeks(inMonthOf:firstWeekday:)`, `days(in:)`. `firstWeekday` comes from
  `Calendar.current`. A week's key is its first day.
- **A zone change inside a day** (travel). The day's items stay in absolute time order. A
  divider line is inserted at the change, "Times from here in Jakarta time", and hour
  labels after it use the new zone. Flying west can make the same date occur twice; both
  stretches appear on that date's page, one after the other. Flying east can skip a date; that
  date has no page and reads "Nothing recorded" on the week.
- **Titles** use the zone of the day's first moment, not `TimeFmt.dayLabel`, which uses the
  phone's current zone.

```swift
public struct ZoneTimeline: Sendable {
    public init(segments: [SegmentMeta], currentZoneID: String)
    public func zoneID(atMs: Int64) -> String
    public func dayKey(forMs: Int64) -> String
    public func windows(of dateKey: String) -> [(range: Range<Int64>, zoneID: String)]
}
public enum HistoryCalendar {
    public static func week(containing dateKey: String, firstWeekday: Int) -> ClosedRange<String>
    public static func month(containing dateKey: String) -> ClosedRange<String>
    public static func weeks(inMonthOf dateKey: String, firstWeekday: Int) -> [ClosedRange<String>]
    public static func days(in range: ClosedRange<String>) -> [String]
}
```

### 7.9 Navigation, routes and deep links

**Landing at a time.** New resolver on the live data layer:
`momentTarget(atWallMs:) async -> CitationTarget?`

1. Among the day's segments pick the one whose span contains the time (latest start wins; on a
   tie, the one that has frames).
2. `conversationId(ofSegment:)` (`Kit/AppDB/ConversationQueries.swift:477`).
3. The media offset comes from the member walk already inside `citationTarget`
   (`App/Runtime/LiveLibraryDataSources.swift:1120-1185`), factored out so both use it.

**No new route for it.** `TranscriptFocus` gains a style:

```swift
struct TranscriptFocus: Equatable, Hashable {
    var segmentId: String; var startMs, endMs: Int64?
    var style: Style = .citation
    enum Style: String { case citation, moment }      // URL: fk=m
}
```

With `.moment`, the conversation screen scrolls to the last transcript row starting at or
before the time (or the first after it) and draws no "Cited moment" band. `atMs` still cues the
player. Today's focus needs a row inside the window, which fails for a gap.

**Routes.**

- New `Route.history(date: String?, level: HistoryLevel?)`, URL
  `companion://history?date=2026-09-22&level=day`.
- `Tab.library` becomes `Tab.history`; `libraryPath` becomes `historyPath`.
- `navigate(to: .conversation / .note / .search)` lands in the History tab.
- `Route.today(date:)` with a past date opens History on that day. (It is parsed and ignored
  today, `AppRouter.swift:50-52`.)
- `Route.library(tag:)` stays parseable as an alias, so old links and Shortcuts keep working; it
  opens the tag results.
- Pushes from inside History use `router.push`, which stays in the tab.

**Other places that name the Library** and must change or be kept:

| Place | Action |
|---|---|
| `App/RootView.swift:30-32` | The tab: label, icon, root view. |
| `Copy.Tabs.library`, `Copy.Library.*` (`Copy.swift:366`, `:509-523`) | Rename; `searchPlaceholder` moves to `Copy.Search`; `title` is used by `SavedNotesScreen.swift:17`. |
| `NoteJobCenter.swift:275` | `case .today, .library` → `.history`. |
| `OpenIntents.swift:77-100` | Search intent lands in History. |
| `LibraryDayEntity` | **Keep the type name** (it is its identity for Siri and Shortcuts); open History on that day; use the recorded zone. |
| `EntityDataSource.libraryDayKeys` (`:420`) | Replace the whole-library build with the recorded-days set. |
| `SpotlightService.swift:77`, widget context (`AppComposition.swift:952`) | Switch to windowed reads when the library builder is removed. |
| `UndoCenter` snackbar | Move the host from `LibraryScreen` to `RootView`, which also fixes problem 9 in 6.5. |
| Tests | `AppRouterTests`, `LiveMockConformanceTests` (reads sources by path), `EntityQueryTests`, `NoteJobCenterTests`, `StoresTests`, `DeleteCascadeTests`, `LossNotificationRoutingTests`. |

### 7.10 Read side

#### The day builder

`HistoryDayBuilder.build(…) -> HistoryDay`, a pure static function in `Kit/AppDB/`, run off the
main actor.

Inputs for one day: segment metas overlapping the window; pause intervals; chapters; follow-up
placements; audio-content spans; deleted spans; the pending-delete set; the live snapshot when
the day is today.

Every minute between the first and last recording is given exactly one kind. The first rule
that applies wins:

| Order | Kind | Source |
|---|---|---|
| 1 | deleted | `deleted_spans`, and conversations inside the undo window. "Deleted by you" / "Removed to save space". |
| 2 | paused | `pause_intervals` ("you paused capture", "timed pause"), and the watch's power-save gap ("watch was saving power"). |
| 3 | audio missing | Visible-loss gap records, from the single classifier. Cause from `gapDescription`. |
| 4 | not recording | Coverage `off`: no recording and no record of why. |
| 5 | quiet | Watch-reported silence. |
| 6 | not transcribed yet / transcription failed | Recorded time whose segment is pending, running, disabled, or failed. |
| 7 | chapter | A chapter row. Loss inside it becomes `missingMs` on the card, never a separate item. |
| 8 | no conversation | Audio-content spans marked so; else recorded, transcribed time with no speech. |
| 9 | fallback card | Transcribed speech that no chapter covers yet: the conversation's title and the time range. |

Then: neighbours of the same kind merge; items under 2 minutes fold into a neighbour, **except
loss**, which is never absorbed (it becomes a suffix on the card or a thin amber gap); the
15-minute rule for no-conversation applies; the two ends become single edge lines.

```swift
public struct HistoryDay: Equatable, Sendable {
    public var dateKey: String
    public var titleZoneID: String
    public var brief: HistoryBrief?
    public var followUpTotal, followUpOpen: Int
    public var leadingEdge, trailingEdge: HistoryEdge?      // "Quiet until 8:12 AM"
    public var items: [HistoryItem]
    public var isToday: Bool
}
public enum HistoryItem: Equatable, Sendable, Identifiable {
    case chapter(HistoryChapterBlock)
    case gap(HistoryGap)
    case zoneChange(atMs: Int64, zoneID: String)
    case live(HistoryLiveBlock)
}
public struct HistoryChapterBlock: Equatable, Sendable {
    public var id: String; public var startMs, endMs: Int64
    public var title: String; public var summary: String?
    public var tags, people: [String]
    public var missingMs: Int64; public var timesApproximate: Bool; public var isFallback: Bool
    public var followUps: [HistoryFollowUpLine]      // already ordered: open, then done
}
public struct HistoryGap: Equatable, Sendable {
    public var id: String; public var kind: Kind; public var startMs, endMs: Int64
    public var detail: String?                       // cause or descriptor, only when known
    public var isTappable: Bool
    public enum Kind: Equatable, Sendable {
        case quiet, paused, audioMissing, notRecording, noConversation
        case notTranscribedYet, transcriptionFailed, deleted
    }
}
public struct HistoryFollowUpLine: Equatable, Sendable, Identifiable {
    public let id: String; public var text: String
    public var done, isSnoozed, isApproximate: Bool
}
```

Invariants, enforced by tests: items tile the span from first to last recording with no overlap
and no hole; total missing time shown is never less than the coverage computer's; suppressed
silence is never shown as missing; loss is never shown as quiet; `off` is never shown as quiet;
a failed segment is never inside a chapter.

**Cost.** A day is about 100 segments and a few thousand gap records. `CoverageComputer.compute`
flattens by comparing every boundary against every range (`:279-283`). Measure a full day on
the backup first; if it costs more than about 50 ms, rewrite the flatten as a sweep line, with
an old-versus-new equivalence test. Speech runs come from the enrichment service's memoised
evidence cache or `loadSpeechTimings`, keyed on the transcript's version.

#### Weeks and months

Plain queries over `recaps`, `period_briefs`, `day_chapters`, `chapter_tags` and `follow_ups`,
plus the day-state roll-up over segment states (recorded, not transcribed yet, nothing
recorded, today).

```swift
public struct HistoryWeekRow: Equatable, Sendable, Identifiable {
    public var dateKey: String; public var state: HistoryDayState
    public var headline, summary: String?; public var tags: [String]
    public var followUps: [HistoryFollowUpLine]; public var moreFollowUps: Int
}
public enum HistoryDayState: Equatable, Sendable {
    case nothingRecorded, recorded, notTranscribedYet(waitingMs: Int64), today(isLive: Bool)
}
public struct HistoryMonthRow: Equatable, Sendable, Identifiable {
    public var week: ClosedRange<String>; public var isCurrent: Bool
    public var headline, summary: String?; public var tags: [String]
    public var followUpTotal, followUpOpen: Int
}
public struct HistoryPeriod<Row: Equatable & Sendable>: Equatable, Sendable {
    public var brief: HistoryBrief?; public var tagCounts: [TagWithCount]; public var rows: [Row]
    public var followUpTotal, followUpOpen: Int
}
```

#### The data source

```swift
@MainActor protocol HistoryDataSource: AnyObject {
    func bounds() async -> HistoryBounds          // first and last day, set of recorded days
    func day(_ dateKey: String) -> AsyncStream<HistoryDay>
    func week(_ range: ClosedRange<String>) -> AsyncStream<HistoryPeriod<HistoryWeekRow>>
    func month(containing dateKey: String) -> AsyncStream<HistoryPeriod<HistoryMonthRow>>
    func prefetch(days: [String])                 // build once into the cache; no observation
    func setVisible(_ visible: Bool)
    func momentTarget(atWallMs: Int64) async -> CitationTarget?
}
```

`LiveHistory` (in `App/Runtime/`) and `MockHistory` (demo data), registered as a pair in
`LiveMockConformanceTests`.

The two battery rules are built into the shape:

- **Content gate.** For the visible page only, one database observation over a small **digest**
  of the window: the overlapping conversations' ids, states and ends; their segments'
  transcription states; overlapping pauses; the window's follow-up rows (id, done, archived,
  snoozed, text); the chapter and brief `updatedAtMs`; deleted spans; the audio-content digest.
  Duplicate digests are dropped. The regroup stage rewrites every conversation row each pass;
  for a past day that produces an identical digest, so nothing is rebuilt and nothing is
  published. When the digest does change, the day is rebuilt off the main actor and published
  only if the new `HistoryDay` differs from the last one.
- **Visibility gate.** `setVisible(false)` cancels the observations; it does not merely ignore
  them. `setVisible(true)` re-subscribes, fetches once and compares with the cache. The pattern
  is `LiveStorageStatsSource.setVisible` (`App/Runtime/LiveSettingsDataSources.swift:191-195`).
  The History root calls it on appear, disappear and scene-phase change.
- **Today** is the one page whose digest changes every pass while recording. Its rebuilds are
  coalesced to one per 10 seconds. The Live card's text comes from the existing live snapshot,
  not from a second walk of the live transcript.
- **Paging.** Only the visible page is observed. The neighbours are built once by `prefetch`.
  A small LRU (about seven days) keeps recently seen pages.
- **Recorded days** (for bounds and the calendar) are the day keys of all segment starts, from
  the in-memory index, recomputed only when the count or the first or last start changes.

`LibraryDataSource` shrinks to what others still use (tags, the row lookup search needs,
delete and undo) and its whole-library build is deleted in the last step.

### 7.11 Deletion and retention

- Deleting a segment (by the user or by retention) also deletes the chapters touching it
  (`day_chapter_segments`), clears that day's chapter state so the day is re-chaptered, and
  marks the day recap, week brief and month brief for regeneration. No summary may go on
  describing audio that is gone.
- The cascade writes a `deleted_spans` row, so the hole on the day reads "Deleted by you" or
  "Removed to save space" instead of "Not recording".
- During the undo window the conversation's time is drawn as deleted; undo restores it.
- Retention moves History's first page forward. A size-cap eviction can remove stretches inside
  a day; those show as "Removed to save space".

### 7.12 The screen (SwiftUI)

Type-checked sketches of the pieces below are in `docs/redesign/history-sketches/`
(`Geometry.swift`, `Timeline.swift`, `Screen.swift`). They compile against the iOS 26 simulator
SDK under Swift 6 and the geometry was run against sample data on the Mac. **Nothing in them
has run in a simulator**, which is what the spike in [section 8](#8-build-sequence) is for.

#### Files

```
App/Screens/History/
  HistoryScreen.swift        root: level control, toolbar, pager, search swap, destinations
  HistoryModel.swift         level, visible page, page list, jump and scroll-to-top tokens
  HistoryDataSources.swift   HistoryDataSource protocol + view types (scanned by the conformance test)
  DayPage.swift  WeekPage.swift  MonthPage.swift
  DayTimelineLayout.swift    the Layout
  TimelineGeometry.swift     pure maths: heights, hour marks, pin offset
  ChapterCard.swift  LiveChapterCard.swift  PendingChapterCard.swift  TimelineGap.swift
  WeekDayRow.swift  MonthWeekRow.swift  JumpCalendar.swift  TagResultsScreen.swift
App/Components/BriefCard.swift  FollowUpLine.swift
App/DesignSystem/Copy+History.swift
App/Runtime/LiveHistory.swift
App/Mocks/…                  MockHistory (demo data: the two mockup days, a week, a month)
```

#### State

```swift
enum HistoryLevel: String, Hashable, CaseIterable { case day, week, month }
struct HistoryPageID: Hashable, Comparable { var level: HistoryLevel; var key: String }  // key = first day

@MainActor @Observable final class HistoryModel {
    var level: HistoryLevel
    var visiblePage: HistoryPageID?        // bound to .scrollPosition(id:)
    var jumpToken = 0                      // rebuilds the pager for a far jump
    var scrollToTopToken = 0               // bumped on tab re-tap
    private(set) var range: ClosedRange<String>   // first recorded day … today; only ever grows
    func pages(for level: HistoryLevel) -> [HistoryPageID]
    func show(_ level: HistoryLevel, containing dateKey: String, animated: Bool)
    var isShowingToday: Bool { get }
}
```

- The screen owns the level and the page in view. A page view owns only its own vertical scroll
  position.
- Only the visible page subscribes to its stream (`.task(id: isCurrent)`); neighbours show a
  prefetched snapshot.
- `range` never shrinks during a session. If retention removes the oldest day while the screen
  is open, that page shows its removed state; the list shortens on the next launch. Removing
  pages at the front would make the scroll position jump.

#### Paging

`ScrollView(.horizontal)` + `LazyHStack(spacing: 0)` + `.containerRelativeFrame(.horizontal)` +
`.scrollTargetLayout()` + `.scrollTargetBehavior(.paging)` + `.scrollPosition(id:)`, one pager
per level (`.id(level)`), starting at the trailing edge (today is the last page).

- Pages are equal width, so only the visible page and its neighbours are built.
- The list only appends (a new day at 5 AM). It never prepends.
- "Today" from a neighbouring page scrolls with animation; from further away it rebuilds the
  pager at the target and cross-fades, since scrolling across 200 pages would look wrong.
- A page's vertical offset is not kept once the page is dropped; you come back to its top.
- The tab bar's minimise-on-scroll is not enabled: there is no API to say which of two nested
  scroll views the bars should follow.
- Not `TabView(.page)`: same nesting problem, less control. Not a hand-built three-page
  recycler: much more machinery for nothing.

**Back-swipe.** At the root of the stack there is nothing to pop, so the pager has the
horizontal pan to itself. One level down (a conversation), the pager is not on screen. This is
the reason the levels are state and not pushes.

#### Chrome

- **Level control** in `.safeAreaBar(edge: .top)` (iOS 26), so it stays put while pages slide
  under it and the scroll edge effect extends to it. `.pickerStyle(.tabs)` on iOS 27,
  `.segmented` on iOS 26, chosen in a small `@ViewBuilder` helper behind `#available`.
- **Title** is drawn inside the page, under the control, so "Tuesday / September 22" slides away
  with Tuesday. Not a system large title: that cannot sit below a bar, and its collapse depends
  on which scroll view the bar tracks.
- **Navigation bar** stays visible (the Library hides it) because the design has toolbar
  buttons. `.navigationTitle` is set for the back label on pushed screens and removed from the
  bar with `.toolbar(removing: .title)`.
- **Toolbar items** are plain `Button(_, systemImage:)`; the system draws the glass. The Today
  item is wrapped in `if !model.isShowingToday` at the `ToolbarItem` level so no empty capsule
  is left behind.
- **Jump to date**: `UICalendarView` in a `UIViewRepresentable`, `availableDateRange` first
  recorded day to today, dot decorations on recorded days, single-date selection (week-of-year
  selection when the level is Week), `.presentationDetents([.medium, .large])`.
- **Tab re-tap**: there is no public event. A custom `Binding` setter on
  `TabView(selection:)` that fires when the value set equals the current one is the candidate;
  the spike confirms it.

#### The day timeline

`DayTimelineLayout: Layout`. Children are tagged through a `LayoutValueKey` as the axis, an
item (with its time span and floor height) or a mark (an instant: an hour label or "now").

- `sizeThatFits` measures each item at the available width and takes
  `max(ideal, minutes × 1.1667, floor)`. Heights are cached per width.
- `placeSubviews` stacks the items, then places the axis and each mark at the y interpolated
  along the item that contains its instant.
- The whole gutter comes out of one layout pass. No preference keys, no second pass, no
  `Canvas`, no scroll-offset state.
- **Hour labels cannot collide, and this is decided before layout.** Every item is at least
  `minutes × 1.1667` pt tall and spacing only adds, so two instants Δ minutes apart are at
  least `1.1667 × Δ` pt apart. `TimelineGeometry.hourMarks` drops an hour that falls within a
  label's height (in minutes) of the first item's start, the last item's end, or now.
- Times are epoch milliseconds and hours come from `Calendar` in the day's zone, so a
  daylight-saving day works.

**Fitting a chapter's text.** `ViewThatFits(in: .vertical)` over candidates in the mockup's
order: summary limited to 7, 6, … 1 lines with follow-ups expanded, then 1 line with follow-ups
collapsed to "first + N more". It sits in a tiny `ProposeHeight` layout that proposes the soft
maximum (`duration × 3 pt`) and reports the chosen candidate's real height. When nothing fits,
the last candidate is used and the card exceeds the band; it never truncates the floor content.
All candidates are measured in one pass, so there is no measure-then-relayout loop. If
profiling on the 24-hour day shows the eight candidates per card are too costly, the fallback is
to measure one summary line and compute the count.

**Pinned gap labels.**

```swift
label.visualEffect { effect, proxy in
    let gap = proxy.bounds(of: .named(GapLabelPin.space)) ?? .zero
    let viewport = proxy.bounds(of: .scrollView(axis: .vertical)) ?? gap
    let visible = viewport.inset(top: insets.top, bottom: insets.bottom)
    return effect.offset(y: TimelineGeometry.pinOffset(
        labelHeight: proxy.size.height, gap: gap, visible: visible))
}

static func pinOffset(labelHeight h: CGFloat, gap: CGRect, visible: CGRect) -> CGFloat {
    let inView = min(max(0, visible.minY), visible.maxY - h)   // keep it on screen…
    return min(max(inView, gap.minY), gap.maxY - h)            // …but never outside its gap
}
```

`.scrollView(axis: .vertical)` names the innermost vertically scrolling container, which skips
the horizontal pager. The gap clamp is applied last so a label whose gap is almost gone slides
out with the gap's edge. Bar insets come from `onScrollGeometryChange` and change only when the
bars do, not per frame.

#### Components

| Mockup element | Built from |
|---|---|
| Cards | `Card`, `ListCard` (`Components/Card.swift`) |
| In-brief card | new `BriefCard`, modelled on Today's recap card (`TodayScreen.swift:306-346`) |
| Topic and people pills | `TagChip` with a new tone (`.topic`, `.person`); `FlowLayout` for wrapping |
| Follow-up line | new `FollowUpLine`, display only (not `FollowUpRow`, which has a toggle) |
| Live card | new; reuses `LiveBadge` |
| Paused stripes | `DiagonalStripes` (`Components/CoverageStrip.swift:168`) |
| Rows | new `WeekDayRow`, `MonthWeekRow` inside `ListCard` |

New tokens: `timelineAxis`, `missingText` (`#C77700`; orange text on the ground colour fails
contrast), `backgroundAudioBar`, and the timeline constants (gutter 58, axis x 50, spacing 6).
New fonts: `hourLabel`, `timelineMeta`, `dayNumeral`. All copy in `Copy+History.swift`. Every
new component gets an entry in `ComponentGallery.swift`.

#### Transitions

- Level change and drill-down: opacity combined with a slight scale, through `Motion.transition`
  (which already reduces to opacity under Reduce Motion).
- No matched geometry: the source row is in a lazy stack that is being removed.
- iOS 27's `.crossFade` is a `NavigationTransition` for pushes and does not apply to in-place
  state.
- No haptics: the app's rule is "never on navigation or scrolling".

### 7.13 Performance and battery

| Rule | How History meets it |
|---|---|
| A screen's data source does nothing while its screen is off screen | `setVisible(false)` cancels every observation. Tested by counting builds and queries while hidden. |
| An observer never re-publishes what it observes | History only reads. Publishing is gated twice: on the digest, then on the built value. |
| Pipeline steps cost in proportion to what changed | Chapters: unchanged days memoised, changed days redo only changed stretches. Briefs: fingerprinted on their members. |
| No whole-library work | Windowed queries with a `startMs` index; `buildDetail` stops calling `buildRows`. |
| Heavy AI work stays on the charger in the background | Both stages are `heavy` and sit behind `aiStagesDue`. Backfill of days older than yesterday runs only in the foreground or when plugged in and cool. |
| Main thread stays free | The day is built in a detached task; the main actor only assigns the result. |

Budgets to hold, measured on the 2026-09-30 backup: building one day under 50 ms; opening the
tab to first content under 150 ms; a page swipe never drops a frame on the 24-hour day.

---

## 8. Build sequence

One commit per numbered step, each leaving the app working. Commits go in
`pebble-audio-companion` with explicit paths staged (other sessions share the repo), and each
phase ends with a progress-log entry.

### Phase 0 — Spike (a branch, not merged)

A throwaway screen in the simulator to settle the things that could only be read from the SDK:

| Question | If the answer is bad |
|---|---|
| Does the horizontal pager with a vertical scroll view in each page scroll cleanly, and do the bars behave? | Fall back to a UIKit page controller hosting the pages. |
| Does `bounds(of: .scrollView(axis: .vertical))` include the area under the bars? | Drop or keep the inset in the pin maths. |
| On first show, does the trailing default anchor or the bound id win? | Set the id before the first layout. |
| Does the `TabView(selection:)` setter fire on re-tap, and does the system pop the stack itself? | Drop re-tap-to-today; the Today button remains. |
| Does back-swipe from a pushed conversation start cleanly? | — (report) |
| Is the back-button title still "History" after the title is removed from the bar? | Set it on the pushed screens. |
| Does VoiceOver's three-finger swipe page the pager? | Add `accessibilityScrollAction`. |
| How long does the day layout take with 25 cards? | Replace `ViewThatFits` with computed line counts. |

Output: a short note with each answer and a screen recording for Roger.

### Phase 1 — Foundations (no visible change)

| # | Step | Proof |
|---|---|---|
| 1 | One loss classifier for coverage and gap status; decide power-save and watch-side stop; remove the hard-coded "— Bluetooth" | `TRGapWordingTests`, `CUCoverageQuietRecutTests`, `CoverageComputerTests` |
| 2 | Shared turn → wall-clock helper on `SegmentMediaClock`; existing call sites use it | `GPSegmentMediaClockTests`, `ConversationBoundaryTests` |
| 3 | `ZoneTimeline`, `HistoryCalendar` | new `HistoryCalendarTests` (5 AM boundary, week starts, weeks across months, west and east travel) |
| 4 | Index migration; `ConversationQueries.rows(overlapping:)`; `buildDetail` without `buildRows` | `AppDatabaseTests`, `StoresTests` with a build counter |
| 5 | Measure `CoverageComputer.compute` on a full day; sweep-line flatten if over budget | old/new equivalence in `CoverageComputerTests`, `RealCoverageLossTests` |
| 6 | `HistoryDayBuilder` with fallback cards, the built-in `AudioContentSource`, and `deleted_spans` | new `HistoryDayHonestyTests` |
| 7 | `momentTarget(atWallMs:)`; `TranscriptFocus.Style.moment`; conversation screen scrolls without highlighting | new `HistoryMomentResolverTests`, `AppRouterTests` |
| 8 | Follow-up wall-time columns, written at extraction; one-time fill; read-time placement | `FollowUpWorkerTests`, new `HistoryFollowUpAssignmentTests` |
| 9 | `HistoryDataSource`, `MockHistory`, `LiveHistory` with the digest gate and `setVisible` | new `HistoryObservationGateTests`, `LiveMockConformanceTests` |

Prerequisite from outside this plan, already landed: the time-zone stamp on new segments (`9baad3e`).

### Phase 2 — The screen, on data that already exists

Built behind a `-history` launch argument; the Library stays the tab until step 15.

| # | Step | Proof |
|---|---|---|
| 10 | `TimelineGeometry`, formatting and accessibility-label builders | unit tests, including a daylight-saving day and the pin cases |
| 11 | Tokens, fonts, `Copy+History`, new components, gallery entries | gallery screenshots, light and dark |
| 12 | `HistoryScreen` shell: pager, level control, title, toolbar, states. Week and Month from day recaps, conversation titles and follow-up counts | simulator screenshots against the mockups; demo data |
| 13 | Day: `DayTimelineLayout`, gaps, pinned labels, edge lines, Live card, now marker, fallback cards | screenshots on demo data and on the backup days 09-22, 09-23, 09-24 |
| 14 | Search in place, tag results, jump-to-date, routes (`Route.history`, `.today(date:)`, aliases), intents, snackbar at the root | `AppRouterTests`, `LossNotificationRoutingTests`, `SearchScopeTests` |
| 15 | Make History the tab | full test suite; phone deploy; battery gate (section 9) |

At the end of this phase History is already better than the Library for stories 1, 5, 6, 8 and
9, with no AI work done: a true timeline of each day with conversations as cards.

### Phase 3 — Chapters and briefs

| # | Step | Proof |
|---|---|---|
| 16 | `ChapterInputBuilder` (lines, stretches) | new `ChapterInputTests` |
| 17 | Chapter tables; `DayChapterStore`; tag adoption that leaves conversation tag counts alone | `AppDatabaseTests`, new `DayChapterStoreTests`, `StoresTests` |
| 18 | Prompts, parser, line-number validation; input-policy and on-device budget entries; `ChapterSummaryBudget` | `PromptsTests`, `AiInputPolicyTests`, `AFOnDeviceBudgetTests` |
| 19 | `DayChapterEngine`, cloud path: settling, stretch keys, retry state | new `DayChapterEngineTests`, modelled on `RecapEngineTests` |
| 20 | On-device path | same suite |
| 21 | `.chapters` stage and wiring; delete cascade for chapters | `PipelinePassTests`, `DeleteCascadeTests` |
| 22 | Chapter review on real days (section 9) — **Roger reads the output before the UI uses it** | the review report |
| 23 | Chapter cards on the day; tags on week and month rows; follow-ups inside cards | screenshots against `round10` |
| 24 | Day headline and line summary; `PeriodBriefEngine`, `.briefs` stage; brief cards and row text from them | `RecapEngineTests`, new `PeriodBriefEngineTests`, `PipelinePassTests` |
| 25 | Backfill: newest first, call caps, plugged-in gate | `BackgroundWorkPolicyTests`, `PipelinePassTests` |

### Phase 4 — Finish

| # | Step | Proof |
|---|---|---|
| 26 | Plug in the real audio-content source when the classification task delivers it; "Background audio" with descriptors | `HistoryDayHonestyTests` cases; screenshots |
| 27 | Zone-change divider and per-zone hour labels | `HistoryCalendarTests`, a travel-day fixture |
| 28 | VoiceOver pass: element labels, adjustable title, rotors, focus after level change | manual pass with VoiceOver; label-builder tests |
| 29 | Remove the Library: `LibraryScreen`, `LibraryViewModel`, the whole-library builder, `coverage_days`; rename `Tab.library` → `.history`; move Spotlight, entity day keys and the widget context to windowed reads | `EntityQueryTests`, `LiveMockConformanceTests`, `AppRouterTests`, `NoteJobCenterTests` |
| 30 | Phone deploy, battery gate, a week of real use, fixes | cost reports; Roger's notes |

---

## 9. Testing and validation

### Unit tests

Listed per step above. The ones that protect the product's promises:

- **`HistoryDayHonestyTests`** — the invariants in [7.10](#710-read-side): the day tiles with no
  hole or overlap; loss is never reduced, never drawn as quiet; suppressed silence is never
  drawn as missing; "not recording" is never drawn as quiet; a failed segment is never inside a
  chapter.
- **`HistoryObservationGateTests`** — a regroup pass that changes nothing publishes nothing and
  builds nothing; a hidden source runs no queries.
- **`DayChapterEngineTests`** — an unchanged day makes no calls; a changed stretch redoes only
  itself; settled chapters keep their ids; invalid line numbers store nothing; a cut input
  stores nothing.
- **`CheckpointSafetyTests`** stay green throughout (nothing here touches the receiver, but it
  is the standing check).

### Real data

- Tests gated on `PEBBLE_HISTORY_BACKUP=<backup folder>` (the pattern of `PEBBLE_GAP_BACKUP` in
  `RealCoverageLossTests.swift`). They assert invariants and aggregates only, and are skipped
  when the variable is unset. Nothing from a real transcript is committed.
- Simulator check: copy a backup into the dev app's container
  (`<container>/Library/Application Support/audio-companion/`) and look at 2026-09-22, 09-23
  (15 h conversation) and 09-24 (24 h 53 min). The pipeline modifies the copy, so re-copy
  before each check.

### Chapter review (before the UI depends on chapters)

An env-gated suite, `ChapterReviewMeasurement`, runs the chapter stage over chosen backup days
and prints, per day: the chapters (time, title, tags, summary length against target), and
counters. Roger reads three days he remembers well.

Gates before step 23:

- no chapter boundary contradicts a gap (guaranteed by construction; asserted anyway);
- 95 % or more of stretches pass line-number validation on the first attempt;
- a typical recorded day comes out at 8 to 20 chapters;
- on Roger's read of three days: titles are right, and no chapter lumps together things he
  would call separate more than occasionally.

The same suite is run once for the on-device path, to see how coarse it is before deciding
whether the UI should say anything about it.

### Visual

- Every page state in [5.8](#58-states) has a demo-data fixture and a simulator screenshot,
  light and dark, at default and at the largest accessibility text size.
- Screenshots are compared by eye against the mockups and shown to Roger at the end of steps
  12, 13 and 23, in chat, as the design rounds were.

### Battery gate

After every phone deploy: `./scripts/phone-cost-report.sh` ten minutes in and the next morning.
A FAIL takes the build off the phone and `./scripts/profile-phone.sh` says why. Two specific
checks for this work:

- With History open on today while recording, CPU stays in line with the Today tab's.
- With the app in the background overnight on the charger, the two new stages add no passes:
  the pass count and CPU are compared against the night before the stages landed.

### Deploy

`./scripts/deploy-ios-rebuild.sh --device G17 --replace` (never two native builds side by side;
they share the App Group). Steps 15 and 30 are the planned deploys.

---

## 10. Risks

| Risk | Why it matters | Mitigation |
|---|---|---|
| Chapter quality | Wrong titles or lumpy chapters make the day worse than conversation cards | Model returns line numbers only; hard breaks are deterministic; review gate (step 22) before the UI uses chapters; fallback cards remain |
| On-device chapters are cut by rule | In Local Only, cards are time slices with a title, not true topics | Measured in the review; copy stays neutral ("chapters" are never called topics in the UI) |
| Cloud cost | About two calls per changed stretch, plus today's tail every 30 min in the foreground | Caps per pass; stretch-level recomputation; backfill gated to foreground or charger |
| Nested scrolling under Liquid Glass | The pager inside a tab with a vertical scroll view per page is the least proven part | Phase 0 spike; UIKit page controller as fallback |
| `ViewThatFits` cost | Eight candidates per card, all built | Profile on the 24-hour day; computed line count as fallback |
| Opening a 24-hour conversation at a moment | The conversation screen loads the whole transcript; a past hang was traced to transcript decoding | Time it against the backup in step 7; if slow, load a window around the moment first |
| Retention empties the far end | Month is thin on default settings | Decision 1 in section 11 |
| Time zones | Segments recorded before `9baad3e` are unstamped and dated in the phone's current zone | History tolerates unstamped data; new recordings are stamped |
| Segments overlap in wall time (spool backfill) | "Which segment holds this moment" can pick the wrong one | Latest start wins, frames break ties; resolver parity test with `citationTarget` |
| Time inside a segment with no frames and no gap record | Drawn as recorded today; could show a card over a hole | Measure how common it is (step 6); for inexact-clock segments read frame ranges once and cache |
| Two sessions adding migrations | The classification task adds its own tables | Agree names and order before either lands; both additive |
| A pending delete is invisible to database observers | The undo window lives in memory | The digest includes a pending-delete version pushed by the delete call |
| Summaries describing deleted audio | A brief that still mentions a deleted morning | Cascade clears chapters and marks the day, week and month briefs for regeneration |

---

## 11. Decisions Roger still has to make

None of these block writing code for Phases 0–2. Each has a recommendation.

1. **How far back should History go?** Today retention removes a recording's transcript and
   summaries along with its audio (default 30 days or 2 GB), so History would hold about a
   month. *Recommendation:* keep transcripts, chapters and briefs after the audio is removed,
   under their own setting, so old days stay readable and only playback is lost. That changes
   what retention means and is its own piece of work; until it is decided, History shows what
   retention leaves.
2. **"Not recording."** Time inside a day with no audio and no record of why (watch off, capture
   switched off). *Recommendation:* its own calm label, "Not recording · 2 hr 10 min", on a
   dashed axis; not amber. A mockup will show it next to quiet and missing.
3. **Capture stopped on the watch.** A watch-side stop is currently drawn as missing audio.
   *Recommendation:* draw it as paused, "paused on the watch". This also changes the Today
   strip.
4. **Archived follow-ups.** *Recommendation:* leave them out of History's lines and counts.
5. **Causes.** The mockups' "watch out of range" cannot be shown; only recorded causes can.
   Listed in [5.3](#53-day). Confirm the wording is acceptable as is.
6. **Local Only chapters.** Cut by rule, so coarser than cloud chapters. *Recommendation:*
   accept, decide after the review output whether the screen should say anything.
7. **Week start.** Follows the phone's locale setting (Sunday or Monday).

---

## 12. Mockup index

In `docs/redesign/history-mockups/`, each as `.html` and `.png`.

| File | Shows | Status |
|---|---|---|
| `round10-background-audio` | Day: 70 pt hours, white cards, all gap kinds, merged edge lines, centred labels | **current Day** |
| `round5-week-followup-state` | Week: rows with pills and two follow-ups with state | **current Week** (its day phones are superseded) |
| `round4-white-blocks-followups` | Month: week rows, tag pills, follow-up counts | **current Month** (its day and week are superseded) |
| `round3-today-and-week-text-tags` | Today's Live card and now marker | **current for the Live card** (tinted blocks and text tags superseded) |
| `round6`–`round9` | The steps to the time scale: minimum hour height, merged edges, 90/80, 70 | history |
| `round3-day-week-month`, `round2-*` | Tinted blocks; merged first set | history |
| `direction-a` … `direction-d` | The four opening directions | history |

Still to be drawn, when building starts: "Not recording", "Could not be transcribed", "Deleted",
the zone-change divider, the jump-to-date sheet, tag results, and every empty state.

---

## 13. Appendix: notes for the audio-classification task

Findings from this project's research that belong to the other session. They are background,
not a design.

- **What the app keeps today.** A segment with no words is marked `NoSpeech` (either the energy
  floor at −60 dBFS or blank provider text; the author is in `lastError`). Any words make it
  `Complete`. Those verdicts have been wrong before: 53 of 575 old ones later produced
  transcripts.
- **Soniox audio events.** `is_audio_event` is decoded and then filtered out
  (`SonioxTranscriptionProvider.swift:328-331`, `:481`, `:494`). No captured response in the
  repo or the backups contains one, so whether Soniox emits music or TV events for this request
  is unknown. Old ones cannot be recovered.
- **Local transcripts are thin.** In the newest backup 260 transcripts are from Soniox, all with
  confidence and 259 with speakers; 43 are from the local engine with turns but no speakers,
  words or confidence. Signals built on speakers or confidence are absent in Local First.
- **Words per minute is weak alone.** A lull rule scored worse than chance for splitting, and its
  showcase case was two people talking with a TV on (`ConversationBoundaries.swift:170-177`).
  The transcriber also invents text on near-silence (`SegmentEnergy.swift:5-10`). 23 of 303
  transcripts run under 2 words per minute and 55 between 2 and 10.
- **Apple's sound classifier** is not linked anywhere in the app. Audio is Speex wideband at
  16 kHz, about 9.8 kbps, which mangles music; accuracy on it is unknown.
- **A measurement pattern exists**: `VadCoverageMeasurement` in `Tests/TranscriptionTests`
  (env-gated, prints results, changes nothing).
- **Suggested ship gates**: a descriptor needs precision of 95 % or better on at least 30
  hand-labelled positives; "no conversation" must not swallow more than 3 % of real
  conversation minutes.
- **What History will do with the result** is in
  [7.6](#76-audio-with-no-conversation-an-external-dependency): the `AudioContentSpan` shape,
  and the rule that a descriptor is shown only when the source provides one.
- **Consumers beyond History**: follow-up extraction (drop candidates located inside a
  no-conversation span), the day recap's input, enrichment titles, search.
