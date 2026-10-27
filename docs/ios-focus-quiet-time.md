# iPhone Focus and watch Quiet Time

Design chosen by Roger on October 27, 2026: option A in
`mockups/focus/directions.html`, a grouped section directly in Settings → Watch.
Use existing `ListCard`, type, colors, spacing, and disclosure controls.

## Setup and behavior

1. In Pebble Audio → Settings → Watch, turn on **Follow iPhone Focus** (off by default).
2. In iPhone Settings → Focus, choose Do Not Disturb, Sleep, Work, or a custom Focus.
3. Add Filter → Pebble Audio, enable **Quiet Time**, and tap Add. Repeat for other Focus modes.

The Focus filter defaults to false when iOS removes the active configuration. Its suggested
configuration is true when adding a filter. A filter invocation never changes the app's opt-in.
A Focus with no Pebble filter releases the phone's Quiet Time contribution.

The phone sends only an on/off request, never the Focus name. Quiet Time uses the watch's normal
notification rules; it does not copy iOS's allowed people/apps, alter alarms, or change recording.
The user's manual Quiet Time and schedules remain intact. A deliberate manual Off on the watch
can override the current Focus until it ends; repeating the same phone request preserves that
choice. A new connection or Focus on transition starts a new phone contribution.

The current authorized Bluetooth connection is required. Disconnect, forgetting the receiver,
and revocation release only the phone contribution. Reconnect reads the current system filter
before applying it. Older firmware is detected by capability bit 7 and shows an update-needed
state; the app never falls back to overwriting manual Quiet Time.

Focus can keep the existing quiet Bluetooth link while app recording is off, independently of
Muse's link preference. It never arms a watch recording-enable prompt. Turning the watch's Audio
Companion service itself off still prevents authorization, as before.

## iOS research and limits

Apple's [Focus Filters guide](https://developer.apple.com/documentation/AppIntents/defining-your-app-s-focus-filter)
and [WWDC22 explanation](https://developer.apple.com/videos/play/wwdc2022/10121/) establish the
system-owned per-Focus configuration, default-value reset on deactivation, background extension,
and App Group handoff. `QuietTimeFocusFilter` uses this supported path.

[`INFocusStatusCenter`](https://developer.apple.com/documentation/intents/infocusstatuscenter)
exposes notification availability, not a list of named Focus modes. Apple presents that API in
its [communication notification integration](https://developer.apple.com/documentation/usernotifications/implementing-communication-notifications).
It is not the appropriate picker or a reliable replacement for per-Focus filters here. We request
no Focus Status or communication entitlement, use no private Settings URL, and require no
Shortcuts automation.

The extension persists the latest filter and signals the app. It does not open a second BLE
client or launch the UI. Darwin notification delivery alone cannot wake a suspended/terminated
app. A running app applies changes immediately; otherwise the durable latest value is consumed
when the app next runs, including an existing heartbeat or Bluetooth/lifecycle wake. A foreground
or reconnect also queries [`SetFocusFilterIntent.current`](https://developer.apple.com/documentation/appintents/setfocusfilterintent/current).
Force-quitting the companion prevents a guarantee of immediate watch synchronization. There is
no timer, background audio hold, or extra polling task added solely for Focus.

## Contract and safety

`PHONE_FOCUS_STATE` (`0x10`, token, bool) is a strict three-byte, idempotent, authorized control
message advertised by `CAPABILITY_PHONE_FOCUS` (bit 7). The ACK is emitted after applying the
phone contribution on the watch system task. See protocol section 4.7 in both repositories.

One serialized app writer coalesces changes. Late ACKs from an old connection cannot mark a new
connection synced. Failed or lost ACKs remain pending and can safely retry the same desired state.
A failed current-filter lookup never turns stale persisted On into a new watch request. A newer
extension invocation takes priority over a query already in flight. Debug and Release store Focus
preferences separately despite their shared App Group.

## Validation and visual review

- The real-app simulator test exercises the opt-in switch, setup disclosure, scrolling, and
  persistence across relaunch. Captures are in `mockups/focus/built/focus-setting-*.png` and
  `focus-setup-expanded.png`.
- Native view captures at 375, 820, and 1024 points cover light and dark appearances. These
  render the same screen content in a temporary UIKit host, with scrolling removed for the
  full-content still image. The phone UI test above exercises the actual scrolling screen.
  The temporary renderer is excluded from the shipping app.
- State-machine tests cover opt-in, old firmware, an in-flight On followed by Off, newer Focus
  events, reconnect/late ACKs, retries, and failed system queries. Receiver tests verify the
  Focus and Muse link requirements remain independent while recording stays off.
- Firmware tests verify strict decoding, unauthorized rejection, disconnect cleanup, manual
  overrides, and preserving manual/scheduled Quiet Time. Release packages pass the existing
  audio/analytics gates. The watch feature has not yet been flashed or exercised on hardware.

A physical iPhone/watch test is still required for iOS Focus delivery while locked and
backgrounded, and for full end-to-end behavior. Simulator/build success does not establish
background delivery latency or battery use.
