# Summary-first chat widgets — design of record

Roger’s screenshots showed a summary-less compact card and an expanded card dominated by a
recording timeline. The first local design review missed the real transcript-only result shape.
A useful widget must explain what was discussed before presenting navigation or recording detail.
Compactness must not come at the expense of the summary.

## Final behavior

- Conversation: title and subtle time metadata, then the app’s actual overview in readable text.
  Compact mode allows four lines; Read more reveals the entire supplied overview and secondary
  topics/people. Recording details are a separate collapsed disclosure, even after Read more.
- Every get_conversation mode includes the overview. Previously include=transcript intentionally
  removed it, producing exactly the empty cards Roger supplied. The existing integration test
  now verifies that transcript mode retains the same overview as summary mode.
- Older result payloads without an overview retrieve the summary automatically while compact.
  Missing summaries and retrieval failures have explicit text and a retry/Open path rather than
  leaving a blank card. A Node regression checks compact-mode retrieval and no duplicate fetch.
- Day: the concise day recap appears compact; Read more reveals the fuller recap. Browsing
  conversations is a separate disclosure and begins with a summarized conversation when available.
  Recording details, including gaps and timelines, are another secondary disclosure. The card no
  longer substitutes an arbitrary unsummarized first conversation for a recap that already exists.
- Multi-day: compact date buttons and the selected day’s recap; expanded mode reveals all days.
- Clip: playback controls stay compact; expansion reveals its scrubber and transcript. Short
  clips have clock endpoints and seconds in the header. Transcript selection seeks the audio.
- Gaps remain explicit and distinct from quiet, with neutral styling confined to the widgets.
  They do not lead the reading experience. Labels and timezone remain available with the timeline.
- Resource URIs are v3, with both v1 and v2 aliases retained. Repeated host results do not reset
  expansion, selection, or playback; changed results and renewed signed audio URLs still render.

## Live day-response repair

The first live get_day read exposed 18,287 coverage transitions taking 2,004,752 JSON characters
and crowding out every conversation. Detailed spans now get at most one quarter of the response
budget. Above it, exact totals remain, spansOmitted explicitly identifies absent detail, and the
widget points to the day view. No gap data changes in storage and no spans are fabricated.
After deployment, the same day returned 47 conversation cards in 39,356 characters with all
recorded/quiet/lost totals unchanged. Partial counts say “shown.” A 4,000-transition regression
checks the answer size, preserved cards, and preserved totals.

## Validation

- 44 server tests pass, including transcript-mode overviews and all three resource URI versions.
- 3 Node behavior tests pass; both CI workflows run them. Composed widget modules parse and
  git diff --check passes.
- Browser inspection uses the actual composed widget sources at phone, tablet, and desktop
  widths, compact/expanded, light/dark. The final pass uses saved live results from the exact
  conversation/day in Roger’s screenshots, including the legacy payload without an overview.
- Checked summary recovery while compact, full recap expansion, optional conversation browsing,
  and separate recording detail. Earlier checks covered keyboard navigation, failures/retry,
  clip play/pause/seeking, and resize/collapse preserving state.
- These visual checks use a simulated host. Roger’s supplied screenshots are the evidence of the
  actual assistant rendering; the assistant sandbox cannot be independently inspected here.
- Local screenshots and private saved fixtures are ignored under server/artifacts/widget-review-2026-10-22/.
  Do not commit private fixtures. Deployment hashes and live checks are in the workspace progress log.

## Reproduce locally

Run `python3 server/tools/preview-widgets.py`, then open http://localhost:5099. Default samples
are illustrative; the ready clip is generated silence. `--fixtures /path/to/local-results.json`
accepts a private local object keyed by conversation-card and day-timeline for exact-data review.
`--before /path/to/original/wwwroot` enables the original implementation for comparison.
