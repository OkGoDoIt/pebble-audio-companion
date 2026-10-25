# Reminders

Approved by Roger on 2026-10-22 (mockup v4, `docs/mockups/reminders/reminders-v4.html`). This is
the design of record for follow-ups, reminders, and where reminders are kept.

## Two nouns

- A **follow-up** is something the app noticed in a conversation that the person might want to
  act on. Nothing is committed yet.
- A **reminder** is a follow-up the person said yes to, or one they asked for.

A row in `follow_ups` carries its `stage`: `suggested` (waiting for review), `reminder`, or
`skipped`. Skipped follow-ups are not deleted: they stay findable in their conversation and in
search, and the summary can turn them back into reminders.

## How a follow-up becomes a reminder

| Where it came from | Becomes |
|---|---|
| The person asked out loud ("remind me…", "create a follow-up") | a reminder, at once |
| A moment marked on the watch | a saved moment with AI suggestions; a reminder when the person chooses it |
| An assistant was told to add it (Muse, ChatGPT, Claude, Siri) | a reminder, at once |
| Anything else the app noticed | a suggestion, for review |

There is no label anywhere saying which path an item took. The only trace is that it is already a
reminder.

## Review

- Only suggestions get cards. One gesture, one meaning: swipe right or tap ✓ is **Remind me**,
  swipe left or tap ✕ is **Skip**. "1 of 3" is the only progress. **Not Now** closes, and
  unanswered cards wait for next time.
- Each card shows the suggested due date, priority, and the source conversation and quote. Edit
  the wording directly in the card, tap its date to change it (or add/clear a date), and tap its
  priority to choose another. Edits save in place without confirming or skipping. Writes run in
  order, failures keep the latest draft visible with Retry, and later extraction preserves the
  person's edits. Confirmation waits for the save. Long content scrolls within the card;
  vertical scrolling never answers it.
- After the last card, the **summary** lists every follow-up decided today (the app's day), the
  automatic ones included, each with its state at the trailing edge. A tap flips it. That list is
  the only undo; there is no snackbar.
- With nothing to review, there are no cards: the entry row says "4 reminders added from today"
  and opens the summary.
- Entry points: the Reminders tab's top rows, Today's Reminders section, and (when turned on) one
  evening notification: "3 follow-ups to review · 4 reminders added".

Native inline-card renders: [phone](mockups/reminders/built/review-inline-375-light.png),
[no date](mockups/reminders/built/review-inline-undated.png),
[large text](mockups/reminders/built/review-inline-large-type.png),
[tablet, dark](mockups/reminders/built/review-inline-820-dark.png), and
[wide](mockups/reminders/built/review-inline-1024-light.png).

## Where reminders are kept

One setting, **Keep reminders in**: **Pebble Audio** (the default) or **Apple Reminders**.
There is always exactly one home. The Reminders tab looks the same either way: in Apple mode it
is the Apple list read back, so a tick in either app is the same tick.

### Switching to Apple Reminders

1. The person picks Apple Reminders. iOS asks for Reminders access then — this is the only
   moment it is asked, and it has to come first: the app can't show the person's lists without
   it. Don't Allow leaves the home on Pebble Audio, unchanged.
2. One sheet asks where, and does the move in the same tap. The list choice is IN the sheet, so
   nothing is ever moved into a list the person didn't pick and then moved again:
   - title: "Move 48 open reminders to Apple Reminders" (no open reminders: "Keep reminders in
     Apple Reminders");
   - one list picker row, preselected on a new list called **Pebble Audio** (created on the
     move), with the person's own lists below it;
   - buttons: **Move** (or **Done** with nothing to move) and **Cancel**. Cancel leaves the home on
     Pebble Audio.
3. Open reminders are created in that list. Completed and skipped ones stay in the app's history.

### Changing the list later

The List setting says where NEW reminders go. When it changes and the app has open reminders in
the list it was set to before, one confirmation asks, once: "Move 12 open reminders to
Groceries?" — **Move Them** / **Only New Ones**. With nothing open in the old list, nothing is
asked. Reminders the person moved to some other list themselves (in the Reminders app) are never
moved by this: they are where the person put them.

### Switching back to Pebble Audio

"Bring 12 open reminders back to Pebble Audio?" — **Bring Them Back** / **Cancel**. They are
removed from Apple Reminders (the app made them) and kept in the app. With nothing open there, the
switch happens without asking.

### Two-way

- Ticked, renamed, re-dated or moved in Apple Reminders: the app follows (by
  `calendarItemIdentifier`, whatever list it is in now).
- Deleted in Apple Reminders: it leaves the list in the app too (archived, findable).
- Access turned off in iOS Settings while the home is Apple: new reminders are kept in the app
  and sent on when access returns; Settings › Reminders shows "Reminders access is off" with
  **Open Settings**.

## Alerts

- **Alert on the due date** at a chosen time (default 9:00 AM). In Pebble Audio this is a local
  notification per open dated reminder (the soonest 50, rescheduled when they change); in Apple
  Reminders it is an alarm on the reminder.
- **Evening review** (off by default) at a chosen time (default 8:00 PM): one notification when
  there is something to review or something was added that day.

## Existing follow-ups

The open follow-ups a person has when this ships become reminders kept in Pebble Audio, unchanged,
after duplicates are filed away (same conversation and the same words, or the same task). Nothing
they already have goes back into review.
