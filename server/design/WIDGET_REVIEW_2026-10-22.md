# Compact chat widgets — local review candidate

Roger reported an unlabeled conversation strip and a useful summary cut off with no way to read
it. He then clarified two priorities: recording gaps should be quieter, and widgets should stay
small until deliberately expanded. This candidate follows those corrections. It is not deployed
or an approved replacement for the existing design yet.

## Behavior

- All three widgets start compact and have an explicit Expand / Collapse button. Titles have up
  to two lines, summaries up to three; expanded content is not line-clamped. The host is notified
  when the height changes. At 375 px wide the example conversation is 231 px tall collapsed.
- Conversation: title, time, summary preview, and Open conversation first. Expansion reveals the
  full description, people, topics, and a thinner recording strip with clock labels and timezone.
- Day: retain conversation navigation in compact mode. Expansion reveals the labeled day timeline,
  tags, and full summary. Day results truncate summaries at the server, so expansion fetches the
  full `get_conversation` summary on demand. A failed fetch retains the preview, offers retry and
  the existing Open action. Detached selections cannot be overwritten by late results.
- Clip: compact playback controls; expansion reveals the scrubber and transcript. The transcript
  has a visible explanation of its click-to-play action. Short clips now have endpoint labels
  and seconds in their header. Missing-date results render their unavailable message safely.
- Gaps: neutral gray metadata and hatching in widgets; no amber warning in the conversation
  header. Quiet, pause, and loss remain distinct. This updates the widget advice in REVIEW.md;
  it does not change the native app's or web viewer's loss styling. The shared web player's
  endpoint labels also improve its viewer use.

## Review locally

From this worktree:

```sh
python3 server/tools/preview-widgets.py
```

Open http://localhost:5099. Switch widget, width, theme, and content with the controls. Fixtures
are illustrative; the conversation text paraphrases only the visible part of the supplied
screenshot. The ready clip is a generated silent sample, not a real recording.

`--before /path/to/original/wwwroot` also enables comparison with the original code. The current
session's original snapshot is `/tmp/pebble-widget-review-before/wwwroot`.

## Validation and limits

- Server tests: 43 passed in the isolated worktree.
- All three composed inline modules pass `node --check`; `git diff --check` passes.
- Browser inspection: compact and expanded layouts at phone (375), tablet (768), and desktop
  (1100) widths; light and dark samples. Expanded content uses the same layouts checked before
  adding the compact mode.
- Exercised expand/collapse by click and keyboard; day summary retrieval and failure recovery;
  arrow/Home/End day navigation; clip transcript selection seeking to 00:10, play/pause, and
  collapse preserving playback position. The simulated host resized the frame after expansion.
- Preview reported no application errors. Browser tooling logged a MutationObserver error with
  no source URL; the widget sources contain no MutationObserver call. This is not a live-host
  integration check.
- Screenshots are under `server/artifacts/widget-review-2026-10-22/` (local ignored artifacts).
- Not merged, pushed, deployed, or tested inside a live assistant's widget sandbox. Widget URI
  versions should be bumped when shipping so hosts fetch the new design.
