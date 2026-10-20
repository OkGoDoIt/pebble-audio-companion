# Pebble Audio web: review of the four candidates

The candidate folders this reviews were removed from the repository on 2026-10-21 because they were
built from real recordings; a private copy is kept outside it. The direction chosen from them is
"Reviewer's blend" below.

Reviewed: every HTML, CSS, and JS file in `candidates/reading-first`, `candidates/timeline-first`,
`candidates/calm-cards`, and `candidates/instrument`, plus a headless-Chrome pass over each
viewer (390 px light and dark, 1280 px), day page (390 px full length, 1280 px), and all three
widgets (600 px light and dark host, 375 px). That pass also checked console errors, network
requests, horizontal overflow, and interactive targets under 44 px. I also checked facts against
the backup DB, read-only.

**Hygiene, all four:** no console errors, no network requests (only the SVG namespace string
appears as a URL), no horizontal scroll at 390 px, no framework, no bundler, system fonts only,
tokens as custom properties, and every file under 150 KB (the largest is
`instrument/day.html` at 68 KB). All four respect `prefers-color-scheme` and
`prefers-reduced-motion`, and support a `data-theme` override.

## Ranking

| | Candidate | Score | One line |
|---|---|---|---|
| 1 | timeline-first | **8.0** | The most honest about the day, the strongest squint test, and good widget mechanics. Its waveform is synthetic and its dark paused stripes are too loud. |
| 2 | reading-first | **7.5** | The best transcript to read. But its day page calls paused time "Quiet". |
| 3 | calm-cards | **7.0** | The most native to the app, with the best widget architecture. It invents a speaker name, and missing audio vanishes in its waveform. |
| 4 | instrument | **6.5** | The best clip player by far. Missing audio isn't flagged (a gray hatch on a gray waveform), and its clock is 3 minutes off the app's. |

---

## reading-first — 7.5

**Direction:** a magazine Q&A. A serif reading column, a time margin, and a coverage rail beside the words.

Strengths
- `viewer.html`: the transcript reads best of the four. A serif column at a real measure, speakers
  in small caps, minute stamps in the margin as 44 px play buttons, and short back-and-forth
  folded into one run-in line (`.run`), so runs of "Okay" don't take a row each.
- `viewer.html`: the rail beside the words carries the state in place. Solid tint for speech,
  dotted for quiet, a wide amber hatch for missing. The quiet and missing rows sit where they
  happened, and missing gets an amber band plus its reason ("32 sec missing · connection was
  interrupted").
- `viewer.html`: the cited moment opens 30% down the viewport in a tinted band with one action,
  "Play from here". The header answers what, when, who, and tags in order, then a glance strip
  with a "the moment this cites" pin.
- `shared.js` `PA.Clip`: steps over quiet *and* missing (there is no audio in either) and says
  so ("Skipped 32 sec missing" in amber). "Back to playing" appears only when the reader scrolls
  away.
- `widget-timeline.html`: two 12-hour lanes, so a 10-minute conversation is still a shape at
  600 px. Tapping picks the nearest item, there are 44 px earlier and later steppers, and missing
  stretches can be selected and described.
- `widget-card.html`: compact, and the clearest card at 600 px. The coverage bar uses the same
  shapes as the page.
- `tokens.css`: darkens only the text tokens that fail AA and documents why.

Weaknesses
- **Honesty:** `day.html` and `widget-timeline.html` compute quiet as "everything between the first and
  last conversation that isn't talk, missing, or background". The 6+ hours the watch was paused
  for power show as "Quiet 10 hr 36 min" and as a quiet baseline (the index note admits it). That
  claims the watch was listening when it was not. Paused needs its own shape.
- `viewer.html` glance strip: quiet is the bare baseline, so a deliberate 1 min 27 sec quiet
  stretch looks the same as the ordinary pauses between speech blocks. Only the key's text tells
  them apart.
- `widget-player.html`: Speaker 3's bars use `--background-audio` gray, the same color that means
  "no conversation" everywhere else. Its turn buttons measure 39 px tall (under 44).
- `day.html`: "No conversation · under 1 min" rows add noise, and the day nav links are dead
  (`aria-disabled`). Tags are plain dotted text, so none of them can be tapped.
- `widget-card.html`: `ui/open-link` is posted with no `id` and then also calls `window.open`,
  which opens twice in some hosts.

## timeline-first — 8.0

**Direction:** time is the spine. A to-scale strip with one lane per speaker, a vertical day axis,
and dark first.

Strengths
- `pa.js` `PA.convStrip`: the conversation drawn to scale, one lane per person. Missing is a
  full-height orange hatch with orange edges, and quiet is a dotted gray floor. It is the best
  squint test of the four. You can see who carried the conversation, and where the hole is,
  before reading a word.
- `viewer.html`: a sticky mini-strip (`.mini`) keeps the shape and the playhead in view while
  reading. Tapping the strip jumps to the words. Holes on the vertical axis get a height
  proportional to their length.
- `day.html`: the most honest day of the four. It uses the real coverage data: paused (tint
  stripes, "watch was saving power"), quiet, no conversation, missing, and not recording, each
  with its own shape. Missing gets its own rail under the band, binned so a few seconds read as
  a sliver and not a wall. "Not summarized yet" is shown honestly. Card height follows duration.
- `widget-timeline.html`: the axis is a real `role="slider"` (arrows, Home, End) with drag to
  choose, 44 px steppers, "11 of 39", and a filled Open button. The headline names the day's
  missing total.
- `widget-player.html`: the missing stretch is unmistakable inside the waveform, and turns dim as
  they pass. Only one player plays at a time.
- `pa.js` `PA.hostBridge`: handles `ui/notifications/tool-result`, host theme, and
  `window.openai`.

Weaknesses
- **Honesty:** `pa.js` `PA.wave` makes up amplitude from noise seeded by turn timing, and the UI
  presents it as a waveform. For the mockup that's acceptable, but the shipped version must draw
  real levels or a speech/no-speech bar.
- `tokens.css` dark: `--pat-paused` stripes at 55% tint on near-black are the loudest thing in the
  day strip and the timeline widget (see the dark-host render). They are louder than missing
  audio, which inverts the priority. Paused must be calm.
- All three `widget-*.html` files bake the review harness (two host sections) into the widget
  page. The widget and the chrome need to be separable, as calm-cards does it.
- `viewer.html` order: the strip comes before the summary. The page answers "what was said"
  after "where are the holes".
- `day.html`: every card links to `viewer.html?from=day` (the same conversation) with no marker
  that only one is built.
- `pa.js` `PA.Clip`: plays through quiet as if it were audio, and skips only missing.
- `viewer.html`: the end link "See the rest of Wednesday" is 35 px tall. The strip band is
  clickable but cannot be focused (the turn-time buttons cover keyboard use).
- Monospaced `11:08:05` stamps read as instrumentation rather than as the app's voice.

## calm-cards — 7.0

**Direction:** the iPhone History tab, carried to the web: cards, the four-state taxonomy, and
calm stretch lines.

Strengths
- `tokens.css`: the most faithful to `Tokens.swift` and `Tokens+History.swift`. It has text and
  shape pairs for the tokens that fail AA (`--missing-text #A35F00`, `--speaker-other #1F7F7F`)
  and the app's type scale by name.
- `day.html`: the History tab done right. Logical day from 5 AM (matching the app), and one calm
  line per stretch between cards ("Paused · 3 hr 4 min / watch was saving power"). Quiet is the
  bare axis, missing is an amber bar, follow-ups sit on their cards, and short conversations get
  compact cards. The brief collapses on phones.
- `pa.js` `PA.timeLine`: "10:54 – 11:21 AM · 27 min · 48 sec missing", with the loss in amber. It
  is the right single line for every card and widget.
- `widgets.css` and `widgets.js`: the best widget architecture. `.host-*` is review-only chrome,
  `.w-*` is the widget, sizing uses container queries, and `W.boot` handles
  `ui/notifications/tool-result` and `host-context-changed`. `ui/open-link` is sent with an
  `id`, and the ChatGPT and Claude, light and dark, and 600 px and phone toggles work.
- `widget-timeline.html`: the squint test passes. Missing is a 26 px amber tick over the rail, and
  paused is low stripes. Tapping the 44 px track picks the nearest conversation, `role="listbox"`
  supports arrow keys, and there are steppers, "7 of 34", and Open day.
- `pa.js` `PA.Player`: steps over quiet and missing, and has a speed control.

Weaknesses
- **Honesty:** names the unnamed Speaker 2 "Megan" (`viewer.html` and widget data, plus the
  mock assistant's reply: "You and Megan went through…"). The DB's `people` table names only
  Roger. Inventing an identity in someone's real archive is exactly what this product must never
  do, even in a mockup.
- `tokens.css` `.wave-bar.missing`: 16 px high, against speech bars up to 40 px. In the viewer's
  27-minute waveform, 48 seconds of loss is one or two short amber bars that read as a quiet
  moment (see the phone render). Missing has to be the most visible mark, not one of the
  smallest.
- `.strip .missing` and `.strip .quiet` are full-height fills that differ only by hue.
- `viewer.html`: the player covers the whole conversation rather than a clip around the moment,
  stamps appear only every 30 s, and `.para` rows and widget `.cp-turn` rows can be clicked but
  aren't buttons, so a keyboard can't reach them.
- It is the least "genuinely different" direction. It is close to a port, which also makes it
  the safest base.

## instrument — 6.5

**Direction:** an audio tool. Ink on paper, one accent, and the waveform scrubber as the hero.

Strengths
- `instrument.js` `<pa-player>`: the best clip player. The waveform is the scrubber (a slider
  with keys and drag). Under it, a lane shows who spoke when, then a minute axis, a large
  readable clock, ±10 s buttons, and a live caption. A "Skip quiet" button appears while
  playing through quiet, and missing audio is skipped with a status line ("Skipped 48 sec of
  missing audio"). "QUIET" is labelled inside the wave.
- `<pa-overview>`: the whole conversation with the clip window and a linked-moment pin, which
  works well for re-aiming the clip.
- Real web components (`pa-player`, `pa-overview`, `pa-daystrip`), which suits the owner's rules.
- `day.html`: a totals key with values (Talk, No conversation, Quiet, Paused, Audio missing, Not
  recording), "Jakarta time" shown, a hover and tap readout of any minute, and follow-ups
  that link to their source conversation.
- `widget-player.html`: the compact player plus turns that light up. The turn rows are real
  44 px buttons.

Weaknesses
- **Squint test fails for loss:** missing audio is a gray hatch (`--lost #5a5a60`) on a gray
  waveform. In `widget-timeline.html` and `day.html` it shrinks to 2–3 px hatched ticks above
  the strip, which disappear at a squint. "Flagged" needs color as well as shape. Here the
  hatch is the only signal, and it is gray.
- **Data:** the times come from segment media offsets (10:57–11:24 AM, day rows 8:24, 9:12, and so
  on), but `conversations.startMs` and `endMs`, which the app shows, say 10:54–11:21. The web
  must never disagree with the phone about when something happened.
- `viewer.html` order: when, title, people, tags, *player*, then summary, then transcript. On a phone
  the summary is below a 600 px instrument, and the page doesn't scroll to the linked turn
  (`if (wide.matches)` only), so "opens at a moment in the transcript" isn't true on phones.
- The widgets have no host bridge. They read only the inline JSON, ignore host theme messages,
  and Open is a plain `href` inside the iframe. The harness is in the widget file.
- Copy: "watch buffer filled while disconnected" leaks the mechanism, whereas the others say
  "connection was interrupted". A monochrome palette that drops the app's amber taxonomy breaks
  the design of record for no gain.

---

## Rule violations

- **All four:** the shared JS is a classic script, not an ES module (`shared.js`, `pa.js`,
  `instrument.js`, `widgets.js`), to open from `file://`. Each file says why. That deviation is
  acceptable for the mockup, but production must ship them as modules.
- **reading-first:** paused or unknown time is labelled and drawn as "Quiet" (`day.html` `quietMs`,
  `widget-timeline.html` lanes), which breaks "quiet is not loss" and "never pretend audio
  exists". Its direction statement is 157 words, against a target of 150. Turn buttons in
  `widget-player.html` are 39 px tall, against a 44 px minimum.
- **timeline-first:** all three widget files embed the review harness. The synthetic waveform
  (`PA.wave`) is presented as audio levels. The "See the rest of Wednesday" link is 35 px tall.
- **calm-cards:** it invents the name "Megan" for an unnamed speaker, in the data and in copy
  (`viewer.html`, `widget-*.html`). Clickable transcript paragraphs (`.para`) and widget turn rows
  (`.cp-turn`) are not buttons. Its statement is 154 words. The preview-only alt links are
  32 px.
- **instrument:** missing audio isn't flagged distinctly from quiet at a squint (gray
  hatch). Its conversation and day times are 3 minutes off the app's stored times. The answers
  come out of order on the viewer (summary after the player), and on phones it doesn't open at
  the transcript moment. The widgets lack any host bridge. The copy "watch buffer filled while
  disconnected" is implementation detail.

## The combined design

Base it on **calm-cards' tokens and architecture**. That means the app's design of record, its
text and shape token pairs, its widget harness and bridge, and its logical day. Bring in these
parts from the others:

1. **One mark vocabulary, everywhere.** Talk is tint. Quiet is a calm dotted gray line (from
   timeline-first and instrument). Missing is an **amber hatch with amber edges**, at full height
   and never smaller than speech (timeline-first `.strip__missing`). Paused is muted tint stripes,
   and dark mode needs a much lower stripe alpha than timeline-first's. Not recording is a
   dashed hairline. The words always include "N missing" in `--missing-text`.
2. **Viewer header, in this order:** back to the day, title, then the calm-cards time line
   ("Wed, Oct 14 · 10:54 – 11:21 AM · 27 min · 48 sec missing"), people (named first, then "and
   N other voices", never invented names, as instrument does), and tags. Then the summary.
3. **Conversation shape:** timeline-first's per-speaker lane strip, with the clip window and a
   linked-moment pin from instrument's `<pa-overview>`. Add timeline-first's sticky mini-strip
   on scroll.
4. **Transcript:** reading-first's treatment. Margin minute stamps as 44 px buttons, run-in
   short turns, the rail beside the words, holes set in place with their reason, and the cited
   band with "Play from here". Every turn is a real button.
5. **Clip player:** instrument's `<pa-player>`. Waveform scrubber, who-spoke lane, large clock,
   ±10 s, "Skip quiet" offered, missing auto-skipped with a status line, and reading-first's
   "Back to playing". Draw from real levels, or fall back to a speech/no-speech bar. Never draw
   fake amplitude. On phones, dock it at the bottom (reading-first) and open the transcript at
   the moment.
6. **Day page:** calm-cards' History column, with the 5 AM logical day, one calm line per
   stretch, and follow-ups on cards. Above it goes timeline-first's coverage strip with the
   missing rail, and instrument's totals key with values plus the "Jakarta time" note.
7. **Widgets:** calm-cards' card and bridge (`W.boot`, `ui/open-link` with an `id`, container
   queries). For the day timeline, reading-first's two 12-hour lanes, with the slider semantics
   and drag from timeline-first and its filled Open, "N of M", and 44 px steppers. For the
   player, instrument's compact `<pa-player>` with its turn buttons. Read the initial theme from
   the host as well as from change notifications.
8. **Data rule for the build:** times always come from `conversations.startMs` and `endMs`, the
   same as the phone. Speakers the library hasn't named stay "Speaker N" or "other voices".
