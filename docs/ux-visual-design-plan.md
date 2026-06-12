# Pebble Audio Companion UX And Visual Design Plan

Date: 2026-06-12

Status: product and design plan for the separate third-party audio receiver, transcription, and AI app.

## 0. Overall Goal

We are implementing a third-party audio companion experience for Pebble-class watches running custom firmware. The watch captures microphone audio in the background, encodes it efficiently, and streams it over a dedicated watch-hosted BLE service to this separate mobile app. The mobile app receives the stream, writes audio to durable local storage, tracks any interruptions or loss, transcribes stored segments, and lets the user run AI workflows over transcripts and structured metadata. This is a lifelogger app that is always recordingt (when enabled), not something we turn on specifically to record a specific event like a meeting.

The defining product boundary is that the official Core Devices Pebble mobile app remains unmodified and continues doing normal Pebble companion work. This new app exists beside it as a specialized audio receiver and intelligence layer. From a user's point of view, the feature should feel like adding a trustworthy audio memory function to their Pebble without destabilizing the normal watch experience or hiding important privacy and reliability details.

## 1. Context And Product Promise

Pebble Audio Companion is not a replacement for the official Pebble companion app. It is a focused second app for users running custom firmware that can stream watch microphone audio over the dedicated Audio Companion GATT service. The official Core Devices Pebble app remains responsible for normal watch behavior: pairing, notifications, timeline, app management, settings, and firmware workflows. This app is responsible only for audio receiving, durable storage, transcription, AI processing, privacy controls, and diagnostics.

The product promise should be:

> Use your Pebble as an always-ready audio capture device, while your phone safely receives, stores, transcribes, and helps you understand what was captured. You stay in control of when it records, where audio is stored, what goes to cloud providers, and when data is deleted.

The experience must feel calm, native, and trustworthy. Because this is a background microphone product, the design cannot rely on surprise, ambiguity, or invisible automation. Recording status, receiver health, gaps, cloud processing, retention, sharing, and revocation must be obvious.

## 2. Source Material Read

This plan assumes the upstream architecture and implementation plan are fully accepted:

- `UPSTREAM_THIRD_PARTY_BACKGROUND_AUDIO_GUIDE.md`
- `UPSTREAM_THIRD_PARTY_BACKGROUND_AUDIO_IMPLEMENTATION_PLAN.md`

Key constraints from those documents:

- Two-app model: official Pebble app remains unmodified; this app is the separate third-party audio receiver.
- Watch hosts a dedicated Audio Companion GATT service; phone app is a GATT client.
- Capture is default off.
- First receiver authorization requires explicit watch confirmation.
- The watch stores a single authorized receiver identity and fails closed on mismatch.
- Phone persists encoded audio before transcription or AI processing.
- Any loss or interruption is represented as explicit gaps, never silently hidden.
- Android and iOS must be first-class from the beginning.
- Android uses Companion Device Manager plus a connected-device foreground service.
- iOS uses Core Bluetooth central mode with background restoration and quick notification handling.
- Transcription supports `LocalOnly`, `RemoteOnly`, `LocalFirst`, and `RemoteFirst`.
- Cloud transcription and AI require explicit separate consent.
- Diagnostics must be useful without exposing audio, transcript text, or AI output by default.

## 3. External Design And Product Research

Research sources consulted:

- Apple Human Interface Guidelines: https://developer.apple.com/design/human-interface-guidelines
- Apple HIG privacy guidance: https://developer.apple.com/design/human-interface-guidelines/privacy
- Apple Core Bluetooth background processing: https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html
- Android Material Design 3: https://m3.material.io/
- Material Design 3 in Compose: https://developer.android.com/develop/ui/compose/designsystems/material3
- Android Companion Device pairing: https://developer.android.com/develop/connectivity/bluetooth/companion-device-pairing
- Otter App Store listing: https://apps.apple.com/us/app/otter-transcribe-voice-notes/id1276437113
- PLAUD product site: https://www.plaud.ai/
- Limitless product site: https://www.limitless.ai/
- Granola product site: https://www.granola.ai/
- The Verge coverage of Granola link/privacy defaults: https://www.theverge.com/ai-artificial-intelligence/906253/granola-note-links-ai-training-psa

Research takeaways:

- Native fit matters more than a branded custom shell. iOS should look like an iOS productivity utility. Android should look like a Material 3 app.
- Audio note products compete on fast capture, trustworthy organization, summaries, search, and action items.
- Wearable audio products emphasize battery savings and hands-free capture, but users judge them harshly when processing is slow, subscriptions are unclear, or recording reliability is uncertain.
- Privacy defaults can become product risk. Sharing links, AI training, cloud processing, diagnostics, and retention must be explicit and private by default.
- Background Bluetooth limitations must be explained through state and recovery UX, not through long technical copy.
- The strongest UX differentiator for this product is honest observability: users should always know whether the watch is recording, whether the phone is receiving, whether audio has gaps, and what processing happened afterward.

## 4. Product Design Principles

1. Recording is never ambiguous.
   The app and watch should always make the current state clear: off, waiting, recording, paused, buffering, syncing, transcribing, or error.

2. Trust beats cleverness.
   Never hide gaps. Never auto-enable cloud processing. Never share by public link by default. Never imply continuous memory if the receiver was unavailable.

3. The app is an operations dashboard first.
   The first screen should answer: Is my watch connected? Is audio being captured? Is anything being lost? What happened today? What needs attention?

4. Native platform behavior wins.
   Use iOS tab bars, navigation bars, large titles, grouped settings, native alerts, SF typography, Dynamic Type, and iOS permission patterns. Use Material 3 navigation bars, top app bars, dynamic color, Material switches, list items, dialogs, snackbars, and Android foreground notification conventions.

5. Primary actions are few and clear.
   The user should not be confronted with protocol terms or engineering diagnostics on the main surface. The core actions are Start, Pause, Stop, Review, Ask AI, Export, Delete, and Revoke.

6. Diagnostics are available but not noisy.
   The product should support engineering-grade troubleshooting without turning the main experience into a debug console.

7. Local-first is the trustworthy default.
   Default transcription should prefer local where available. Remote transcription and remote AI are separate opt-ins with visible provider and model provenance.

8. Automation must be reviewable.
   AI outputs and future rules can suggest summaries, actions, exports, or reminders, but consequential actions should be reviewed before execution unless the user deliberately creates an automation rule.

## 5. Audience And Core Use Cases

Primary users:

- Pebble enthusiasts and early adopters running custom firmware.
- Professionals who want unobtrusive personal meeting notes.
- Students or researchers capturing lectures, interviews, field notes, or conversations.
- Users who want a wearable audio memory but do not want the official Pebble app modified.
- Privacy-sensitive users who want local retention, local transcription options, clear deletion, and explicit cloud controls.

Core use cases:

- "I want my Pebble to record background audio while I keep using the official app normally."
- "I want to confirm quickly that recording is actually working."
- "I want to review what happened today, including places where audio was missing."
- "I want transcripts and summaries without babysitting the app."
- "I want to search across captured conversations."
- "I want AI to turn a day or meeting into notes, action items, decisions, or a custom output."
- "I want to delete or export my data with confidence."
- "I want to diagnose why audio stopped without reading logs."

Non-goals for the main UX:

- It should not look like a generic Pebble companion app.
- It should not expose packet counters, sequence numbers, MTU, stream IDs, or checkpoint details on the main screen.
- It should not pretend to be a legal recording compliance tool. It can provide respectful reminders, but users are responsible for recording laws and consent.
- It should not optimize for social sharing before private review and control.

## 6. Product Information Architecture

The app should have four top-level destinations:

1. Today
   Operational status, current recording state, today's capture timeline, recent transcripts, and attention items.

2. Library
   Browse, search, filter, play back, read transcripts, inspect gaps, edit labels, export, and delete segments.

3. AI
   Ask questions, run templates, review AI outputs, and manage future automation rules.

4. Settings
   Watch binding, privacy, retention, transcription modes, AI providers, diagnostics, support report, delete-all, and revoke.

Platform navigation:

- iOS: native tab bar with SF Symbols, large titles per tab, navigation stacks for details, modal sheets for setup and destructive confirmations.
- Android: Material 3 bottom navigation bar for compact screens, NavigationRail on tablets/foldables where appropriate, top app bar with page title and one or two page-specific actions.

Recommended tab icons:

- Today: `waveform` on iOS, waveform or graphic equalizer icon on Android.
- Library: `doc.text.magnifyingglass` or `folder` on iOS, folder/search icon on Android.
- AI: `sparkles` on iOS, auto-awesome icon on Android.
- Settings: `gearshape` on iOS, settings icon on Android.

## 7. Onboarding Flow

The onboarding should be a short, stateful setup wizard, not a marketing tour.

### Step 1: Welcome

Goal: establish the two-app model and trust boundary.

Screen content:

- Title: "Pebble Audio Companion"
- Short body: "Receive audio from your Pebble, store it on this phone, and turn it into transcripts and notes. The official Pebble app keeps handling normal watch features."
- Primary button: "Set Up Audio"
- Secondary button: "Learn How It Works"

Design:

- Use a clean full-width layout, not a hero card.
- Show a simple watch-to-phone audio glyph or bitmap mockup. Do not use abstract blobs.
- Mention "custom firmware required" before the user invests setup time.

### Step 2: Requirements Check

Goal: prevent confusing failures later.

Checklist rows:

- Custom audio firmware installed on watch.
- Official Pebble app remains installed and paired.
- Bluetooth enabled.
- Watch nearby and charged.
- App permissions ready.

Each row should have one of three states: ready, needs action, or unknown.

Primary button:

- Enabled when required checks are satisfied or when the app cannot verify but the user can proceed.
- Label: "Continue"

### Step 3: Platform Permissions

Goal: request only what is needed, in native order.

iOS:

- Explain Bluetooth access in a pre-permission screen.
- System Bluetooth permission follows.
- Notification permission should be requested later, when the app can explain receiver/loss alerts, unless the onboarding includes notification setup.
- Do not request microphone permission unless a phone-mic debug feature ships.

Android:

- Explain nearby-device Bluetooth permission.
- Use Companion Device Manager for watch association.
- Explain that a persistent foreground notification is required while background receiving is enabled.
- Request notification permission when enabling background alerts on Android versions that require it.

Copy principle:

- "We use Bluetooth to receive audio from your watch" is better than "Allow nearby devices".
- "We use notifications to show receiver status and delivery problems" is better than "Send notifications".

### Step 4: Find Watch

Goal: bind the third-party app to the watch-hosted Audio Companion service.

iOS behavior:

- First try `retrieveConnectedPeripherals` for the Pebble pairing service and Audio Companion service.
- If not found, offer foreground scanning.
- If still not found, show a concise troubleshooting sheet.

Android behavior:

- Launch the system Companion Device Manager picker filtered to the watch/audio service.
- Use native system UI; do not build a fake Bluetooth picker.

Visual:

- A progress state with "Looking for your Pebble".
- A discovered watch row with watch name, connection state, and "Connect".
- Failure state with "Make sure the watch is nearby, Bluetooth is on, and custom audio firmware is installed."

### Step 5: Watch Consent

Goal: make receiver authorization explicit.

Phone screen:

- Title: "Confirm on your watch"
- Body: "Your watch will ask whether Pebble Audio Companion can receive microphone audio in the background."
- State: waiting, accepted, declined, timed out.

Watch prompt:

- Title: "Audio Companion"
- Body: "<receiver name> wants to receive watch microphone audio in the background."
- Actions: "Allow" and "Decline"
- Timeout: decline.

UX requirement:

- If declined or timed out, the phone should say "Not authorized" and offer "Try Again" plus "Why this is required".
- If another receiver is already bound, the phone should say "This watch is already authorized for another receiver" and explain that the user can forget the receiver from watch Settings.

### Step 6: Privacy Defaults

Goal: make core privacy choices before the first recording.

Controls:

- Background audio: off by default; user can enable.
- Retention: default 30 days and 2 GB.
- Transcription: default `LocalFirst` when local model is installed or installable; otherwise `LocalOnly` with setup prompt or `RemoteOnly` disabled until cloud consent.
- Cloud transcription: off.
- Remote AI: off.
- Diagnostics content: off.

This screen should use grouped native settings rows. Avoid a wall of legal text.

### Step 7: Ready

Goal: land in Today with an understandable next action.

Possible final states:

- Ready, background audio off: primary action "Start Recording".
- Ready, background receiver on but watch waiting: "Waiting for watch".
- Recording: "Recording from Pebble".
- Authorized but firmware disabled: "Turn on Background Audio on your watch".

## 8. Today Screen

The Today screen is the main product surface and should be useful at a glance.

### Layout

Top area:

- Large page title: "Today"
- Status header with recording state, watch connection, receiver status, and one primary action.

Main content:

- Visual waveform showing the last ~60 Seconds of audio.
- Timeline of today's captured segments.
- Recent AI triggers and outputs (if any)

Bottom:

- Light diagnostics summary if something needs attention: gaps, low storage, failed transcription, cloud consent needed, receiver downtime.


### Status Header

The header should be a full-width band or restrained card depending on platform conventions. It should not be nested inside multiple cards.

States:

- Off: neutral gray, "Background audio is off", primary "Start".
- Waiting: blue/neutral, "Waiting for Pebble", secondary "Troubleshoot".
- Authorizing: blue, "Authorizing receiver".
- Confirm on watch: blue, "Confirm on your watch".
- Recording: green or system accent, "Recording from Pebble", primary "Pause" or "Stop".
- Paused by dictation: amber, "Paused while watch dictation is using the mic".
- Paused low battery: amber, "Paused to protect watch battery".
- Paused low storage: amber/red, "Paused: phone storage low".
- Disconnected buffering: amber, "Phone not receiving. Watch is buffering briefly."
- Loss occurred: red, "Some audio was skipped", primary "Review gaps".
- Revoked: red/neutral, "Receiver revoked", primary "Set up again".
- Error: red, "Receiver error", primary "Troubleshoot".

Header details:

- Watch name and battery if available.
- Last audio received time.
- Queue state: "Transcribing 2 segments" or "Up to date".
- Storage state: "1.6 GB free for audio" or "Low storage".

Primary action rules:

- Use exactly one filled primary button.
- Secondary actions use text or outlined buttons.
- Never show Start and Stop as equal-weight buttons at the same time.
- Destructive actions are never in the status header.

### Visual Waveform

The waveform should be a real-time visual representation of the last ~60 Seconds of audio, including different colors for successful recording, transcription completed, loss of data due to gaps, and detected silence. This should scroll in a real time from right to left, with new audio waveform being appended to the right and old audio waveform falling off the left.

### Today Timeline

The timeline should be a list of today's captured segments, complete with an AI generated summary of the transcript of each segment (or just a snippet of the transcript if there is no AI generated summary). Remember this is An always recording lifelogger, not something we turn on specifically to record a specific event like a meeting. So the timeline should be more based on the time and less based on specific events. Detected silent periods, gaps in audio, and AI-delineated new conversation topics are the appropriate breakpoints between segments.

The timeline should present captured audio as time blocks:

- Recording segment block: start time, duration, title, transcription state, gap markers.
- Gap block: reason and approximate duration.
- AI output block: summary/action items linked to the source segment.

Example rows:

- "9:12 AM - 9:47 AM, Team sync, Transcribed"
- "9:47 AM - 9:49 AM, Gap: watch dictation used microphone"
- "11:03 AM - 11:18 AM, Conversation, Transcribing"
- "2:24 PM, Some audio skipped: receiver unavailable for 1 min 12 sec"

Gap display:

- Gaps should be visible but not alarmist. Gaps are occasionally expected and we don't need to make it seem like it's a big deal or a real error. Just lightly inform the user.
- Use amber or yellow or dark gray.
- Let users tap a gap for exact reason, source, and recovery guidance.

### Recent AI Triggers and Outputs

(let's think more about what this should include and come up with a good design)

### Empty States

First-run empty state:

- "No audio captured yet"
- Body: "Start background audio after authorizing your watch."
- Primary: "Start Recording"

Authorized but off:

- "Ready when you are"
- Body: "Your watch is authorized. Start when you want background audio."

No transcripts yet:

- "Audio is stored. Transcripts will appear here after processing."

## 9. Library Screen

The Library is for retrieval, review, search, and management.

### Top-Level Library

Controls:

- Search bar at top.
- Filter chips: All, Today, This Week, Gaps, Untranscribed, Favorites.
- Sort menu: Newest, Oldest, Priority (as judged by AI), Needs Attention.

Segment list item:

- Title or generated label (AI used to summarize the transcript)
- Date and time range.
- Duration.
- State (Recorded, silence, gap, transcribed, processing, etc.)
- Privacy/provenance indicators only when relevant.
- Detailed summary of the transcript (if any; AI used to summarize the transcript)
- Action items (if any; AI used to extract action items from the transcript)

Avoid exposing raw file names or stream IDs.

### Segment Detail

Header:

- Title, date, duration. (title is short AI generated, if any)
- State chips: Stored, Transcribed, Local, Remote, Gaps, AI.
- Overflow menu for rename, export, delete.

Audio timeline:

- Playback controls if decoded playback is available.
- Scrubber with gap markers.
- Tap a transcript word or paragraph to jump to audio when timestamps exist.
- Playback speed control.

AI Summary:

- Detailed summary of the transcript (if any; AI used to summarize the transcript)
- Action items (if any; AI used to extract action items from the transcript)
- Detected people in the conversation (if any; AI used to detect people in the conversation)

Transcript:

- Paragraphs grouped by time.
- Speaker labels if available in future
- Search within transcript.
- Highlight, copy, edit correction, add note.
- Gap annotations inline: "[Gap: mic conflict, about 38 sec]".

Provenance panel:

- Codec/source: Pebble watch.
- Transcription mode used: LocalOnly, RemoteOnly, LocalFirst, or RemoteFirst.
- Provider and model.
- Processing time.
- Cloud consent status at time of processing.
- Known gaps or errors.

Actions:

- "Fact check"
- "Extract actions"
- "Export"
- "Delete"

Deletion:

- Deleting a segment should clearly say whether it deletes encoded audio, transcript, and AI outputs linked only to that segment.
- Offer "Delete audio only" only if the product intentionally supports transcript retention without source audio. Otherwise keep deletion simple: delete all linked data for the segment.

## 10. AI Screen

AI should feel like a reviewable workspace, not an autonomous black box.

### AI Home

Sections:

- Ask: natural-language question over selected time range.
- Templates: Summary, Meeting Notes, Action Items, Decisions, Follow-up Email, Custom Prompt.
  (users can define their own custom prompts as new templates, just like the built in system that extracts action items or fact checks)
- Recent Outputs.
- Rules, when post-MVP automation is ready.

Scope selector:

- Today.
- Selected segment (or multiple segments).
- Date range (or date/time range)
- Search result set.
- Manual selection.

Before running:

- If remote AI is off, remote templates should either be disabled with explanation or run locally if local provider is available.

After running:

- Output appears in a review screen.
- User can edit, copy, export, share, save, or delete.
- Output is stored for future reference
- Show provenance: prompt template, model/provider, token count, source segments, and generated time.

### AI Rules Engine

Rules should be post-MVP and visibly opt-in.

Rule builder shape:

- Trigger: schedule, keyword/topic, completed transcription, manual shortcut.
- Condition: time range, watch state, segment duration, participant label in future, keyword threshold.
- Action: generate summary, extract actions, create note, export to webhook, notify user.
- Review mode: always review, notify only, auto-save, auto-export.
- Limits: max runs per day, provider allowlist, token budget, quiet hours.

UX guardrails:

- No hidden auto-sharing.
- No default remote execution.
- Every rule has a visible run history.
- Failed rules show why and how to fix them.

## 11. Settings Screen

Settings should use native grouped sections. It is a control center for trust and configuration.

Recommended sections:

1. Watch
   - Watch name.
   - Receiver status.
   - Background receiver toggle.
   - Reconnect.
   - Revoke receiver.

2. Recording
   - Start/stop background audio.
   - Low battery pause threshold, if user-configurable.
   - Loss alerts.
   - Recording reminders.

3. Storage And Retention
   - Retention days.
   - Maximum storage.
   - Current storage used.
   - Delete old audio after transcription.
   - Delete all local data.

4. Transcription
   - Mode: LocalOnly, RemoteOnly, LocalFirst, RemoteFirst.
   - Local model status and download/manage action.
   - Cloud transcription consent.
   - Provider configuration.
   - Retry failed transcription.

5. AI
   - Mode: LocalOnly, RemoteOnly, LocalFirst, RemoteFirst.
   - Remote AI consent.
   - Provider configuration.
   - Prompt templates.
   - Rules, when available.

6. Privacy
   - Cloud processing explanations.
   - Diagnostics content toggle, default off.
   - Export data.
   - Delete all.
   - Privacy policy.

7. Diagnostics
   - Receiver state.
   - Last audio received.
   - Checkpoint lag described in plain language.
   - Storage pressure.
   - Transcription queue.
   - Recent gaps.
   - Build versions.
   - Export support report.

Destructive settings:

- Revoke receiver and Delete all local data must require confirmation.
- Delete all should use platform-native destructive styling.
- The confirmation must list what will be deleted.

## 12. Watch Experience

The watch UI should be minimal and explicit.

### Watch Settings Page

Path:

- Settings -> Audio Companion

Rows:

- Background Audio: On/Off.
- Status: Disabled, Waiting for app, Recording, Paused, Low battery, Low storage, Error.
- Receiver: <name> or None.
- Forget Receiver.
- Diagnostics in debug builds.

Behavior:

- Turning off Background Audio stops capture quickly.
- Forget Receiver revokes the phone app and stops streaming.
- Status row should be readable without opening the phone app.

### Watch Consent Prompt

Prompt:

- "Audio Companion"
- "<receiver name> wants to receive watch microphone audio in the background."
- Buttons: Allow, Decline.

Design:

- Use the existing Pebble modal/actionable dialog style.
- Do not use vague terms like "connect" when the real permission is microphone audio receiving.
- Timeout declines.

### Watch Recording Indication

At minimum:

- Settings status row must show recording state.

Preferred future enhancement:

- A small status icon in a system status screen or quick settings surface, if the platform has a suitable location.

Avoid:

- Persistent intrusive overlays.
- Making every temporary reconnect visible as an alert.

Loss alert:

- Only alert when real audio is skipped due to buffer overflow or unrecoverable receiver absence.
- Rate-limit heavily.
- Copy: "Audio Companion skipped some audio because the phone was unavailable."

## 13. State Model And User-Facing Copy

The app should translate protocol and service states into plain user language.

Recommended state mapping:

- `Disabled`: "Background audio is off."
- `Idle`: "Waiting for the audio app."
- `AuthorizedIdle`: "Authorized and ready."
- `Streaming`: "Recording from Pebble."
- `PausedConflict`: "Paused while another watch feature uses the microphone."
- `PausedPolicy`: "Paused by app policy."
- `PausedLowBattery`: "Paused to protect watch battery."
- `Error`: "Audio receiver needs attention."
- Disconnected before first authorization: "Connect your watch to set up."
- Disconnected after authorization with spool available: "Trying to reconnect. The watch can buffer briefly."
- Spool overflow/loss: "Some audio was skipped."
- Receiver mismatch: "This watch is authorized for another receiver."
- Revoked: "Receiver access was revoked."

Avoid:

- "GATT"
- "AUTH_RESULT"
- "checkpoint"
- "spool"
- "sequence"
- "stream id"
- "NimBLE"

Use those only in diagnostics detail or support reports.

## 14. Visual Design System

### Overall Style

The app should feel like a precise system utility with a polished productivity layer:

- Clean backgrounds.
- High contrast text.
- Restrained accent colors.
- Clear hierarchy.
- Dense but not cramped operational data.
- No decorative gradients, abstract spheres, or large marketing illustrations.
- Use real product imagery or simple device glyphs where imagery is needed.

### Color

Use platform system colors where possible.

Semantic colors:

- Recording: green or platform success color.
- Paused/waiting: amber or platform warning color.
- Error/loss: red or destructive color.
- Cloud/remote: blue or purple accent, used sparingly.
- Local/private: neutral or green privacy indicator.

Android:

- Use Material 3 dynamic color on Android 12+.
- Provide a conservative fallback palette for older Android versions.
- Do not let dynamic color undermine semantic warning/error states.

iOS:

- Use system background, grouped background, labels, separators, tint, destructive, and secondary label colors.
- Support light mode, dark mode, increased contrast, and tinted accessibility settings.

### Typography

iOS:

- Use SF via native system typography.
- Prefer large navigation titles for top-level screens.
- Support Dynamic Type through all text sizes.

Android:

- Use Material 3 typography roles.
- Keep labels and diagnostics legible at font scale 1.3 and above.

Hierarchy:

- Screen title.
- State headline.
- Key metric row.
- Segment title.
- Metadata.
- Diagnostics detail.

Avoid tiny timestamp-only metadata. Time and gap data are critical in this product.

### Components

Use native components:

- Switches for persistent on/off settings.
- Segmented controls or single-choice lists for modes.
- Chips for filters and provenance.
- Lists for settings.
- Cards only for repeated segment/output items and status summaries.
- Dialogs/sheets for confirmation and setup.
- Snackbars/toasts only for transient confirmation, not critical failures.
- Progress indicators for searching, connecting, transcribing, and AI processing.

Cards:

- Radius 8 dp/pt or platform default.
- No nested cards.
- Avoid floating everything in cards.
- Use list rows for settings and diagnostics.

Buttons:

- Filled button for one primary action.
- Outlined button for secondary.
- Text button for tertiary.
- Destructive button uses platform destructive styling.

## 15. Platform-Specific Design Details

### iOS

Use:

- Tab bar for the four top-level areas.
- NavigationStack-style flows.
- Large titles on top-level screens.
- Grouped List/Form for Settings.
- Native sheets for onboarding steps and detail editors.
- Action sheets or confirmation dialogs for export/delete/revoke.
- SF Symbols for tab and toolbar icons.
- iOS system materials only where they improve separation.

Permission flow:

- Pre-permission explanations should be short and specific.
- Request Bluetooth only when setup needs it.
- Request notifications when enabling alerts/background status, not on first launch unless necessary.

Background Bluetooth:

- The app should explain that iOS can restore the receiver after system termination, but not after a user force-quit.
- If the app detects receiver downtime, show it as a gap or attention item.

Accessibility:

- VoiceOver labels for status, controls, transcript timeline, and gap markers.
- Dynamic Type support.
- Minimum touch target sizes.
- No color-only state indicators.

### Android

Use:

- Material 3 Scaffold.
- Bottom navigation for compact screens.
- Top app bar with concise title and page actions.
- Dynamic color on Android 12+.
- Material switches, chips, list items, dialogs, and cards.
- System Companion Device Manager picker for watch association.
- Connected-device foreground service notification while background receiving is active.

Foreground notification:

- Title: "Pebble Audio Companion"
- Content states: "Recording from Pebble", "Waiting for Pebble", "Paused: low storage", "Some audio skipped".
- Actions: Stop, Open, maybe Pause.
- The notification must be honest and persistent when required by the platform.

Android battery restrictions:

- Diagnostics should detect likely background interruption patterns.
- Guidance should be device-specific where possible, but not shown unless needed.

Accessibility:

- TalkBack labels for status and timeline.
- Large font support.
- Predictable back behavior.
- Touch targets at least 48 dp.

## 16. Notifications And Alerts

No notifications or alerts at this time.

## 17. Privacy, Consent, And Legal UX

Privacy must be a first-class surface.

Defaults:

- Background audio off.
- Cloud transcription off.
- Remote AI off.
- Diagnostics content off (actually there will be no diagnostics shared with anyone, so we don't need a setting for this)
- Sharing private by default.

Consent surfaces:

- Watch consent for receiver authorization.
- App consent for cloud transcription.
- App consent for remote AI.
- Explicit confirmation for export/share.

Recording laws and bystander consent:

- The app should include a concise reminder during onboarding and in Settings: "You are responsible for following recording and consent laws where you use this feature."
- Do not make the UI preachy.
- Do not imply the app has solved legal compliance.

Deletion:

- "Delete all local data" must delete encoded audio, transcripts, transcription tasks, AI outputs, queued runs, and receiver resume state.
- If cloud providers store submitted data, the app must explain what it can and cannot delete remotely.

Export:

- Default export should be local/share-sheet based.

## 18. Transcription UX

Transcription should be durable and explainable.

Modes:

- Local Only: "Keep audio on this phone. Transcription requires a local model."
- Remote Only: "Send audio to the selected cloud provider for transcription."
- Local First: "Try local transcription first, then use cloud if local is unavailable or fails and cloud consent is enabled."
- Remote First: "Use cloud first, then local fallback if cloud is unavailable."

Mode picker:

- Use a single-choice list with descriptions, not a cycling button.
- Show availability of local model and remote provider.
- Disable unavailable options with an explanation.

Queue states:

- Pending.
- Running.
- Complete.
- No speech detected.
- Failed, retryable.
- Disabled by settings.

Segment list should summarize state:

- "Transcribing"
- "Transcript ready"
- "No speech"
- "Transcription failed"
- "Waiting for cloud consent"
- "Local model needed"

Failure detail:

- Show likely reason and action.
- Examples: install local model, add provider key, enable cloud consent, retry, delete.

## 19. AI UX

AI should be clearly downstream of transcription.

Empty AI state:

- "Transcripts become AI-ready after processing."
- Primary: "View Library"
- Secondary: "Set up AI"

Run flow:

1. Choose scope.
2. Choose template.
3. Review prompt and provider mode.
4. Run.
5. Review output.
6. Save/export/share/delete.

Template examples:

- Daily summary.
- Meeting notes.
- Action items.
- Decisions.
- Follow-up email.
- Study notes.
- Interview highlights.
- Custom prompt.

Output detail:

- Generated output.
- Source transcript links.
- Gap warnings.
- Provider/model provenance.
- Prompt used.
- Regenerate, edit, copy, export, delete.

## 20. Diagnostics UX

Diagnostics should have two layers.

User layer:

- "Watch connected"
- "Audio receiving"
- "Last audio received 8 sec ago"
- "Phone storage low"
- "2 transcription tasks failed"
- "iOS stopped receiver after force quit"

Engineering layer:

- Firmware version.
- App version.
- Watch model.
- Protocol version.
- Last state transitions.
- Segment counts.
- Gap counts by reason.
- Storage usage.
- Queue depth.
- Support report export.

Diagnostic copy should explain what to do:

- "Open the app once after force quitting; iOS will not restart Bluetooth receivers after a user force-quit."
- "Free storage or reduce retention to resume receiving."
- "Open watch Settings -> Audio Companion -> Forget Receiver to authorize this phone."

## 21. Error And Edge Case Flows

### Unsupported Firmware

State:

- Watch found but Audio Companion service missing.

Message:

- "This watch is paired, but audio firmware was not detected."

Actions:

- "How to install the audio firmware"
- "Try Again"

### Receiver Mismatch

State:

- Watch has another stored receiver hash.

Message:

- "This watch is already authorized for another Audio Companion receiver."

Actions:

- "How to Forget Receiver"
- "Try Again"

### Phone Storage Low

State:

- App requests pause due to free storage threshold.

Message:

- "Recording paused because this phone is low on storage."

Actions:

- "Manage Storage"
- "Delete Old Audio"
- "Change Retention"

### Watch Battery Low

State:

- Firmware pauses to protect watch battery.

Message:

- "Recording paused to protect watch battery."

Actions:

- "Open Settings"

### App Force-Quit On iOS

State:

- Receiver unavailable after user force-quit.

Message:

- "iOS will not restart Bluetooth receiving after you force-quit the app. Open the app to resume."

Actions:

- "Got It"

### Transcription Cloud Consent Missing

State:

- Mode requires remote provider but cloud consent is off.

Message:

- "Cloud transcription is off. Enable it or switch to local transcription."

Actions:

- "Enable Cloud"
- "Use Local"


## 22. Data Model Reflected In UX

The UI should expose product objects, not protocol objects.

Product objects:

- Watch.
- Receiver.
- Recording segment.
- Gap.
- Transcript.
- AI output.
- Rule.
- Provider.
- Support report.

Hidden implementation objects:

- GATT service.
- Characteristic.
- Stream id.
- Sequence number.
- Checkpoint.
- Spool chunk.
- MTU.

Diagnostics can reveal technical details only when useful for support.

## 23. Visual Screen Specifications

### Today, Recording

Top:

- Large title: "Today"
- Header: green left status dot, "Recording from Pebble", subtext "Last audio received just now".
- Primary button: "Pause" or "Stop".

Below:

- Current segment row with waveform strip, elapsed duration, "Stored on phone".
- Timeline list.

### Today, Audio Loss

Header:

- Red status dot, "Some audio was skipped".
- Subtext: "The watch buffer filled while the phone was unavailable."
- Primary: "Review Gaps"
- Secondary: "Troubleshoot"

Timeline:

- Gap row highlighted inline at the correct time.

### Library

Top:

- Search field.
- Filter chips.

List:

- Segment rows with title, timestamp, duration, transcript state, gap marker.

### Segment Detail

Top:

- Title and metadata.
- Actions in toolbar/overflow.

Body:

- Playback timeline.
- Transcript with inline gaps.
- AI outputs linked below.

### AI

Top:

- Prompt box or "Ask about..." entry.
- Scope selector.

Body:

- Template grid/list.
- Recent outputs.
- Rules preview when enabled.

### Settings

Grouped sections:

- Watch.
- Recording.
- Storage.
- Transcription.
- AI.
- Privacy.
- Diagnostics.

## 24. Copy Tone

Tone should be clear, plain, and operational.

Use:

- "Recording from Pebble"
- "Waiting for Pebble"
- "Confirm on your watch"
- "Some audio was skipped"
- "Stored on this phone"
- "Cloud transcription is off"
- "Delete all local data"

Avoid:

- "Always listening"
- "Perfect memory"
- "Never miss anything"
- "Magical AI"

The product should not overpromise. It should say what it knows and what it does not know.

## 25. Accessibility Requirements

Minimum:

- Dynamic Type/font scaling.
- VoiceOver/TalkBack labels for all controls.
- Status conveyed by text and icon, not color alone.
- Touch targets meet platform minimums.
- Transcript and timeline are navigable by screen reader.
- Gap markers have accessible descriptions.
- All destructive actions are confirmed.
- Support reduced motion.
- Light and dark mode.
- High contrast support.

Testing:

- iOS Dynamic Type at largest accessibility sizes.
- Android font scale at 1.3 and 2.0.
- VoiceOver and TalkBack pass through onboarding, Today, segment detail, settings, delete-all, and revoke.

## 26. MVP UX Scope

MVP should include:

- Onboarding through watch authorization.
- Today screen with clear receiver and recording state.
- Start, stop, pause/resume where supported.
- Durable segment list.
- Gap visibility.
- Basic segment detail with metadata and transcript.
- Transcription mode settings.
- Cloud transcription consent and provider key entry.
- AI manual templates from transcripts.
- Privacy settings.
- Retention settings.
- Delete all local data.
- Revoke receiver.
- Diagnostics and support report without content by default.
- Android foreground notification.
- iOS background restoration explanation and state handling.

MVP must also include (decision 2026-06-12 — these were previously implied lower priority but
are explicitly required for the MVP):

- Live waveform view on Today (Section 8 "Visual Waveform").
- Audio playback with scrubbing and speed control in segment detail (Section 9).
- AI-generated segment titles and summaries in timeline/Library rows, with transcript-snippet
  fallback when AI is not configured (Sections 8 and 9).
- The full onboarding wizard screens of Section 7 (not just the bare permission/CDM/consent
  flow).

MVP can defer:

- Speaker diarization.
- Calendar integration.
- Widgets.
- Siri Shortcuts.
- Android Quick Settings tile.
- Rule-based AI automation.
- Team sharing.
- Public web links.
- Multi-watch support.
- Multi-receiver support.

## 27. Post-MVP Enhancements

High-value next steps:

- iOS widget or Live Activity-style status if platform rules allow.
- Android Quick Settings tile for start/stop.
- Siri Shortcut and Android app shortcut for "Start recording" and "Stop recording" and maybe other AI actions.
- Calendar-aware automatic titles.
- Speaker labels.
- Better local model management.
- Rules engine with reviewable automation.
- Export integrations: Markdown, PDF, Obsidian, Google Drive, email.
- Watch quick action for manual memo.
- Monthly privacy report showing what stayed local and what was sent remotely.

## 28. Design Acceptance Criteria

The UX is ready for implementation polish when:

- A new user can set up the app without confusing it with the official Pebble app.
- A user can tell in under 3 seconds whether recording is active.
- A user can stop recording from both watch and phone.
- A user can revoke receiver access.
- A user can see when audio is missing and why.
- A user can find today's transcript and understand whether it used local or cloud processing.
- Cloud transcription and remote AI are impossible to enable accidentally.
- Delete-all behavior is clear and complete.
- Android foreground service status is understandable.
- iOS background limitations are honestly represented.
- Settings are native and not a debug console.
- Diagnostics can support troubleshooting without exposing private content by default.


## 29. Final Product North Star

The best version of Pebble Audio Companion feels like a native phone app that happens to be powered by a Pebble watch. The watch gives the user a small, durable, always-ready microphone. The phone app gives the user confidence: it shows whether capture is active, stores audio durably, explains interruptions, creates transcripts, and lets AI help only within boundaries the user chose.

The app should not sell a fantasy of perfect memory. It should earn trust by being accurate about state, careful with privacy, and useful every day.
