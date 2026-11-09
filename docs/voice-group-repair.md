# Repairing mixed voice groups

Implemented November 9, 2026. The user authorized autonomous design selection after reviewing
three rendered alternatives in `mockups/voice-splitting-2026-11-09/`.

## The experience

**More than one person → Split this voice** proposes smaller groups with playable examples.
**Split further** refines only that group. **Review clips** shows every saved sample, initially
unselected, with **Separate selected clips** and **Separate every clip**. **Keep groups** saves
without naming anyone; an Undo action restores the old grouping. Leaving before saving changes
nothing. The existing quick naming checklist remains under **Select clips to name**.

Two voices from the same recording are now independently selectable. Small saved groups remain
in Voices to name even below the usual discovery thresholds. A group is a review aid, not a claim
that each group represents a distinct person; several groups may later receive the same name.

## Similar products and the choice here

[Google Photos face groups](https://support.google.com/photos/answer/6128838?hl=en) lets people
remove incorrect items from a face group without deleting the media. It also offers same/different/
not-sure feedback. That supports separating group repair from deletion or identity assignment.

[Otter speaker tagging](https://help.otter.ai/hc/en-us/articles/360048465453-Tagging-speaker-names-in-a-conversation)
propagates an initial speaker tag, but permits correction of a particular paragraph and splitting
paragraphs. This reinforces the need for a local correction when broad propagation is wrong.
Neither document establishes an automatic bulk voice-splitting workflow like this one.

The watch adds short, noisy samples, uncertain speaker boundaries, and changing acoustic conditions.
A stricter global threshold would create work everywhere and still could not undo earlier pooling.
This repair therefore operates only on the selected group, exposes progressively smaller units,
and preserves uncertain samples instead of forcing them into a dominant voice.

## Implementation

- `VoiceSubdivision`: deterministic complete-link subdivision. Every pair in a child must meet
  the threshold. No irreversible micro-groups, fragment absorption, new outside members, or claimed
  identities. Across local speakers the floor is 0.65; within one speaker’s original prints it is
  0.55. Explicit repeated splitting tightens above the weakest pair by 0.02, so it makes progress.
  These are conservative repair defaults, not newly calibrated recognition-accuracy thresholds.
- `VoiceSplitting`: decrypts stored original samples on demand, does comparisons off the main
  actor, propagates cancellation, and re-encrypts child pools. It does not run the speech models
  or rescan audio. Missing embeddings remain available for manual separation.
- `VoiceSplitStore`: one atomic write validates a current source/configuration snapshot and exact
  crop coverage. It saves unnamed children and durable source/range separation constraints.
  Recognition cannot reconnect different parts, including through an unrelated bridging voice.
  New names, exclusions, deletion, or reanalysis invalidate stale reviews and unsafe Undo.
- Reanalysis preserves each saved child within its recording before local pooling. A late result prepared before
  the split cannot overwrite it. Uncovered saved ranges remain reviewable when prints are missing.
  Source deletion/expiration removes constraints; ordinary print regeneration retains them.
- Newly split groups stay unnamed pending review. They do not become negative examples of any
  person. Explicit naming is limited to the selected saved crops; it cannot spread a short repaired
  sample’s name across an entire mixed transcript paragraph.
- UI drafts hold their snapshot directly. They do no off-screen polling and persist nothing until
  Keep groups. Undo tokens expire with the existing snackbar lifetime.

## Validation

Synthetic regression cases cover bad early grouping, bridge merges, complete-link pair bounds,
repeated subdivision, exact coverage, same-recording selection, persistence, stale saves, Undo,
missing prints, tiny groups, and naming only the repaired audio range. Real-app UI tests exercise
automatic and manual separation, saving, and Undo. Native screenshots contain synthetic content.

The private investigation found same-recording speakers hidden by the old display deduplication
and a large mixed group whose original samples could all be decoded. Its measurements and derived
embeddings remain in the private investigation folder. There are no verified identity labels in
that cohort, so no speaker-accuracy improvement is claimed.

Delivery and final test results are recorded in the workspace implementation progress log.

### Checked build

- Core package: all 2,809 tests in the first full run passed (two previously recorded expected
  issues). After the additional missing-print regression, 2,810 tests ran; the voice regressions
  passed. Two unrelated timing-sensitive checks failed during host load: recovery and a receiver
  keepalive. The receiver check passed on isolated rerun; recovery was 2.34 s against a 2 s limit.
  Neither recovery nor receiver code was changed for this feature.
- Native App tests: 817 passed. Shared helper tests: 44 passed. The simulator logs contain existing
  Apple asset/Spotlight diagnostics; these are not a claim of a clean system log.
- Protocol fixtures: all 150 checked successfully.
- Phone UI automatic split/refine/review/save test passed. Manual separation/Undo and tablet checks
  were expanded after the first pass; the final result is recorded in the workspace log.
- Signed iPhone Release build succeeded; a final incremental build includes the last regression
  fixes. Physical phone installation and battery measurements remain unavailable while G17 is
  disconnected. This change does not claim on-device quality or battery verification.

Tablet visual review uses a QA-only device-family override to exercise the same SwiftUI at larger
sizes. The shipping app’s existing iPhone-only device family is unchanged; native iPad adoption is
being implemented separately. Three HTML candidates were also reviewed at 390, 820, and 1280 px.
