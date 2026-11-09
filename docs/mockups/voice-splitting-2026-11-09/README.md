# Mixed voice groups — design review, November 9, 2026

Status: option A with option C’s manual escape hatch implemented in native SwiftUI.
The user explicitly delegated the design choice and implementation, without further approval.
The user reported a large unnamed voice group containing themselves and several other people.
They want to break bad groups into tighter groups, potentially down to individual voice prints,
without laboriously deselecting recordings. Three alternatives were rendered before implementation; the autonomous follow-up authorized
choosing and completing the design.

Open `index.html` directly in a browser. It has no dependencies or network requests. All names,
quotes, dates, and grouping results are synthetic. Split and match results are scripted examples,
not an evaluation of recognition quality. Audio buttons illustrate playback state only.

## Options

- A, recommended: smaller groups with a representative clip, clip count, Review clips, and
  Split further. Keep the split without naming anyone. Individual clips remain accessible.
- B: choose one clear clip and pull its closest matches into a separate group.
- C: select individual clips, initially none selected, with Select all/Clear selection and a
  separate naming step. Different speakers from the same recording remain independently selectable.

Chosen composition: A as the main flow, C as its escape hatch; B could be another action
from a chosen clip. Preserve the existing quick checklist for the mostly-correct group case.
All directions reuse the current app tint, system typography, spacing, and card/button radii.
This is a behavior/layout prototype; the accompanying native screenshots show the implemented flow.

## Findings in the original source

- `ios/App/Screens/Voices/WhoIsThisSheet.swift`: More than one person initializes `kept` with
  every segment ID. The Same person page names selected recordings; it has no split operation.
- `ios/App/Runtime/LiveVoiceSource.swift`, `UnknownVoiceDisplay.build`: the `seen` set deduplicates
  by segment ID. Two different speakers from the same recording can be represented by only one
  displayed clip. `nameUnknownVoice` filters by recording IDs, selecting every group member in
  those recordings, including undisplayed speakers.
- `ios/PebbleAudioKit/Sources/CompanionRuntime/Services/VoiceRecognitionService.swift`,
  `speakerDrafts`: original saved prints are diarized within each recording, then pooled into
  one embedding per local speaker. `sortVoicesIfNeeded` clusters those pooled speakers archive-wide.
- `ios/PebbleAudioKit/Sources/SpeakerRecognition/SpeakerDiarization.swift`: adjacent crops first
  pool into blocks of up to four (up to two seconds apart); average-linkage threshold is 0.30;
  fragment absorption can combine short speakers afterward.
- `ios/PebbleAudioKit/Sources/SpeakerRecognition/VoiceClustering.swift`: micro-grouping followed
  by average linkage at 0.55. Average similarity does not guarantee every member is a tight match.
  Its early micro-groups are indivisible in the later merge pass. A stricter final threshold alone
  cannot undo those or the earlier within-recording pooling.
- `ios/PebbleAudioKit/Sources/AppDB/VoiceSpeakerStore.swift`: decisions are confirmed, rejected,
  ignored, or excluded. There is no persisted unnamed-group separation. `replaceSpeakers` transfers
  an old speaker's decisions to only the new speaker with the most overlap; this is unsuitable
  as the sole persistence mechanism for repeated finer splits.

The screenshot alone does not establish which grouping layer caused this particular mixture.
An authorized, read-only private backup investigation informed the edge cases. Audio and derived
embeddings stayed on the local computer, outside this public repository. No identities were inferred
or hand-labeled, so this is not a measured speaker-identification accuracy result.

## Implementation contract

1. Operate on the exact viewed group's members, identified by speaker IDs and ultimately source
   audio ranges. Never use recording ID as the selection identity. Revalidate the snapshot when
   saving if background work, deletion, recognition-off, or another correction changed it.
2. Derive a stricter subdivision from saved prints on demand. First separate the original local
   speakers with complete-link comparisons; within one local speaker, reopen its individual saved
   prints. Permit further subdivision down to individual saved crops. Do not
   force ambiguous fragments into a large group. Use a scoped, monotonic split: every original
   member appears once, no outside audio is pulled in, and repeated splits refine the current child.
3. Persist split provenance against source/range identity. Every clustering phase must honor it,
   including micro-grouping and local fragment absorption. A bridge through an unrelated voice
   must not reconnect the separated children. Separation is about grouping, not a claim that
   each child is a distinct person or negative training evidence against a named person.
4. Splitting does not name, enroll, ignore, or delete anything. Preserve explicit names; recompute
   affected automatic attributions. Do not silently transfer a mixed group's identity to every
   child. Children can remain unnamed or later receive the same person's name.
5. Undo must restore the affected grouping decisions without erasing subsequent unrelated work.
   Keep tiny/singleton children accessible from the split even if normal discovery hides voices
   heard briefly or in only one recording. Missing/unreadable prints must stay visible as
   unresolved clips, not disappear from the partition.
6. Reuse stored local prints rather than rescan the archive. Work off the main thread, cancel
   when dismissed, check current source/config generations before commit, and publish only changes.
   Do not increase the global matching threshold based on this single report.

Meaningful behavior tests: partition completeness, a same-recording mixed speaker, a bad early
micro-group, repeated splitting to singletons, stable separation after restart/regroup/reanalysis,
bridge merges, naming only selected ranges, undo, stale saves, ignored/deleted sources, unreadable
prints, and unchanged-result no-op. Synthetic cases exercise these guarantees. An unlabeled private cohort checks behavior on watch
audio, without supporting an accuracy claim; these mockups provide no accuracy evidence.

## Prototype checks

Rendered and visually inspected at 390, 820, and 1280 CSS px, plus larger text on phone. Exercised
split, save, undo, group review, matching, individual selection, name entry, and submit. Browser
warning/error log was empty. Computed tint `#5b5bd6`, card radius 12 px, button radius 14 px match
`ios/App/DesignSystem/Tokens.swift`. See the implementation report for native tests and delivery status.

Captures: `comparison-desktop.jpg`, `comparison-tablet.jpg`, `smaller-groups-phone.jpg`,
`smaller-groups-large-text.jpg`, and `before-phone.jpg`. The before image recreates the current
flow with synthetic clips; the user's private screenshot is not included in this repository.

Native captures: `native-phone-groups.png`, `native-phone-further.png`, `native-phone-clip.png`,
`native-phone-saved.png`, `native-tablet-groups.png`, and `native-tablet-selection.png`. Native
automatic and manual workflows passed on both simulators; see `../../voice-group-repair.md`.
