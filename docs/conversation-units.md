# Topic-sized conversations

2026-09-30. How the app decides where one conversation ends and the next begins, why it changed,
and how it was measured. The code is in `ios/PebbleAudioKit/Sources/AppDB/`
(`ConversationUnits`, `ConversationLexicon`, `ConversationSegmenter`, `ConversationRunPlanner`,
`ConversationGrouper`, `ConversationCutStore`).

## What was wrong

Roger, 2026-09-30: "There is never a real world situation where there is a 24 hour conversation.
Conversations are generally 20 minutes or 30 minutes or maybe an hour. … If you ever have a
10-hour conversation in any circumstance, that is a bug." And: "The segments are an
implementation detail … don't let it constrain our actual end user experience."

A conversation was a set of WHOLE ~15-minute recording segments. It could end only at a file
rotation, and only after a gap in the record, a Stop, a pause, or 15 minutes of settled silence.
With the watch recording all day and people pausing for less than 15 minutes, nothing ever ended.
Two separate failures came out of that:

1. **Untranscribed audio chained without limit.** The silence rule reads transcripts. A day with
   no transcripts (the ten-day transcription outage) was one 24 h 53 m "conversation".
2. **Transcribed days were still blobs.** On eight fully transcribed days the old rule's units
   had a median of 1 h 27 m, a p90 of 4 h 30 m and a longest of 9 h 48 m.

Everything keyed on a conversation inherited the blob: the conversation screen, the title and
summary, follow-up sources, Ask and search documents, Spotlight, notes.

## The model now

- A conversation is an ordered list of **pieces**: `ConversationMember(segmentId, startMediaMs?,
  endMediaMs?)`, a range of one segment's stored audio in the segment's media clock. One segment
  can hold the end of one conversation and the start of the next. Every sample still belongs to
  exactly one conversation.
- Where a conversation starts is a **cut**: a position in a segment (`ConversationCut`), always
  between two turns. Its id is `conv-<segmentId>` at a segment's start, else
  `conv-<segmentId>-m<mediaMs>`.
- The structural rules (gap, Stop, pause) still decide which segments form one unbroken **run**.
  Inside a run, `ConversationRunPlanner` places cuts from, in order:
  1. **a long settled silence** (15 min; twice that when most of it is missing audio): the
     conversation ends at its last word, the next starts at the first word after, and the
     silence between is a unit of its own with nothing said in it (titled "No conversation").
     Each end is decided on the settled silence next to it, so a conversation that has ended
     does not change when the recording goes on;
  2. **decisions already made**: the segmenter's settled cuts (`conversation_cuts`) and the
     person's own splits (`conversation_cut_overrides`). A person's join records the span of
     the two conversations it joined, and nothing automatic cuts inside that span again;
  3. **the segmenter**, over each stretch of talk between two long silences.
- **Untranscribed audio** is divided by length alone (about an hour, at segment joins, reason
  `length`), is never written down, and is divided properly when its transcripts arrive. There is
  no circumstance in which a day is one unit.

### The segmenter

`ConversationSegmenter` treats a stretch of talk as short blocks (turns with a few seconds between
them at most) and finds, by an exact search, the division of the blocks into consecutive units
with the best total score. A division scores well when each cut sits where the talk visibly
changed (a pause; a jump in how fast turns arrive; dictation starting or stopping; another
language), when each unit is one kind of talk, and when the units are conversation-sized: every
unit costs a fixed amount, a unit under six minutes pays for being a sliver, and a unit pays
quadratically for every minute past nineteen. That last term is the guarantee — two hours of talk
with no pause in it is still divided, at the best places it offers — and it is not a cap: nothing
is cut at a fixed length, and a cut is always between two turns.

It needs no AI and reads no text at regroup time (`ConversationLexicon` turns each turn into a few
flags once, when its transcript is read), so it behaves the same in Local Only, with AI off, and
before any cloud call returns.

### Holding decisions still

The search's answer near the end of what it has heard can change as more arrives; its answer
further back does not. A segmenter cut with 45 minutes of settled talk after it (or in a run that
has ended) is written to `conversation_cuts` and held. Later passes search each whole stretch with
the held cuts forced, which reproduces exactly the conversations they were made with (pinned on
the real library). A conversation with a boundary still inside that window is `isProvisional`:
final titles and follow-up extraction wait for it, as they wait for a live conversation. A run
counts as still growing while it holds the open segment, or its last recording closed less than
five minutes ago (a dropped link reopens in the same run).

When ids do move (the first run after this change re-cuts the whole library; the recent tail can
re-cut), records follow their moment, not their id: follow-ups by their source position, notes and
the person's tags and speaker names by the position their conversation started at, and a title is
regenerated when the pieces it was written for change (`annotations.sourceKey`) unless the person
typed it.

### Delete

Deleting a conversation destroys exactly its pieces. A whole segment goes through the existing
cascade. A partial piece has its audio replaced by encoded silence (so every clock, offset and
gap record stays valid), its turns removed from the transcript (and kept out if a transcription
was in flight), and the follow-ups sourced in it deleted. The neighbouring conversation keeps
its audio, words, id, title and notes; the silenced range joins a neighbour as silence. Known
edges: an upload already in flight cannot be recalled (as for a whole-segment delete); a
transcript with no turn timings cannot be cut, so its text stays with the piece that starts
the segment; and where the silenced range sits beside fifteen minutes of real quiet it remains
as a "No conversation" unit until retention.

## How it was measured

Eight real days (2026-09-19 … 09-29) were read in full and every conversation start marked:
**384 starts** — 199 `certain` (the people, place or activity changed), 185 `unsure` (the subject
drifted inside one exchange) — and **394 traps**: pauses of two minutes or more, and asides,
after which the same conversation carried on. A predicted start counts when it is within two
minutes of a marked one, one prediction per mark. The labels, the day transcripts and the
prototype live outside the repo in `~/Desktop/PebbleAudioAnalysis/conversation-units/`; the
harness is `RealConversationSegmentationTests` (env `PEBBLE_UNITS_BACKUP`, `PEBBLE_UNITS_LABELS`).

What the labels say about pauses, which is why no pause rule works:

| pause before the turn | turns | a marked start |
|---|---|---|
| under 1 min | 4,354 | 4% |
| 1–2 min | 354 | 11% |
| 2–3 min | 124 | 23% |
| 3–5 min | 129 | 40% |
| 5–8 min | 84 | 40% |
| 8–15 min | 77 | 51% |
| over 15 min | 39 | 67% |

38% of the certain starts follow a pause of under two minutes, and a third of the 15-minute
silences are inside one conversation.

Results on the eight days (Swift grouper, units that hold speech):

| | certain found | cuts on a mark | traps cut | units | median | p90 | longest | over 1 h |
|---|---|---|---|---|---|---|---|---|
| before (15 min of silence) | 22 / 200 (11%) | 25 / 38 | 13 / 397 | 45 | 1 h 27 m | 4 h 30 m | 9 h 48 m | 23 |
| cut at every pause ≥ 3 min (prototype) | 58% | 50% | 195 / 394 | 337 | 3 m | 26 m | 3 h 19 m | 16 |
| **now** | **103 / 200 (52%)** | **134 / 232 (58%)** | **62 / 397** | **239** | **16 m** | **46 m** | **1 h 26 m** | **6** |
| finer setting (not shipped) | 130 / 200 (65%) | 221 / 399 (55%) | 99 / 397 | 406 | 9 m | 23 m | 1 h 06 m | 3 |

Over the whole 915-segment library, untranscribed days included, the longest unit is 1 h 26 m.
Run on a copy of the real database, the upgrade turns 110 conversations (longest 24 h 52 m) into
410 units (longest 1 h 26 m; the count includes the silent units between stretches of talk), and
a second pass writes nothing.

The numbers in `SegmenterPolicy` are fitted to the labels, leaning toward precision (a false cut
gives two half-titled conversations; a missed one gives a slightly broad title) and treating
`unsure` starts as neither required nor wrong. Fitting on four days and scoring the other four
found 53% of the certain starts there with 62% of cuts on a mark, close to the all-days fit.
Removing each signal in turn: the change in turn rate and the pause carry most of it; the
dictation and other-language flags matter; a per-unit vocabulary model adds cuts at arguable
drifts and no certain starts, so it is off (weight 0). The finer setting turns it on and lowers
the unit cost; it is one edit away if smaller conversations are wanted.

Cost: grouping the whole library from nothing takes 56 ms on the Mac (release); with the settled
cuts, a relaunch takes 26 ms and an unchanged pass 2 ms (memoised per run).

## What this does not do

- **It does not understand what is said.** About half of the clear starts are found. The misses
  are mostly a change of person or place with no change in rhythm ("Hey Biscuit, I'm home" thirty
  seconds after the last dictated message). A model that reads the words could find those, and
  two ways of using one were tried as a check, with a small model standing in for the app's:
  given a whole day and asked for the conversation starts, it did worse than the segmenter on
  the same labels (16–50% of certain starts per day, units up to 3 h 10 m); asked to confirm or
  reject each cut of the finer setting from the ten lines either side, it came out level with
  the shipped setting on the four held-out days (50% of certain starts found against 56%; 71%
  of cuts on a mark against 64%; one unit of 2 h 08 m). So a reading stage is not an obvious
  win, and is worth building only measured against these labels with the model the app
  actually uses; the table that holds settled cuts is where its answers would go.
- The labels were made by reading transcripts, not by Roger. His own marks on two or three days
  would be a better yardstick and the harness takes them in the same format.
- A pause of 15 minutes always ends a conversation. The labels say a third of those are one
  slow exchange (typing between turns). Left as is: it is the rule the app already had.
