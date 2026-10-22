# Privacy model: every place data can go, and how the app says so

One model for the whole app. Any feature that can move audio, text or a question off the phone
or the watch is a **destination** here, and the Privacy screen, each feature's setup, and the
Delete All confirmation are all derived from the same inputs, so they can never disagree. Today
the stance in `ios/App/DesignSystem/Copy+PrivacyStance.swift` is a pairwise switch over
transcription and AI modes with two later additions (iCloud, server). It does not scale to the
combinations below, so it becomes a derivation over this list.

Owners: the archive-access work (server, assistants) and the Muse work (watch assistant) both
feed this model. Neither adds privacy wording of its own outside it.

## 1. Destinations

| # | Destination | What leaves | Who receives it | Turned on by | Default |
| --- | --- | --- | --- | --- | --- |
| D1 | Cloud transcription | recorded audio | the chosen provider (Soniox, OpenAI) | Transcription mode | as today |
| D2 | Cloud AI | transcript text, About You | the chosen provider (OpenAI, Apple Private Cloud Compute) | AI mode | as today |
| D3 | iCloud Drive | older audio files | the person's own iCloud | the iCloud rule | off |
| D4 | Siri & Spotlight | nothing leaves; titles, summaries or everything go into the on-device index | iOS on this phone | Siri & Spotlight can see | as today |
| D5 | Your Pebble Audio server | conversation text (titles, summaries, transcripts, notes, follow-ups, recaps); clips only if D5a | the person's own server (host named) | linking this phone and Sync on | off |
| D5a | Audio clips on request | a short clip, only when an assistant asks | the person's server, then the asking assistant | a choice inside D5 | off |
| D5b | Assistants may add | nothing leaves; follow-ups and notes come in | the phone | a choice inside D5 | off |
| D6 | Assistants reading your server | whatever they read through the server: text, and clips if D5a | each connected assistant by name (ChatGPT, Claude, Codex on Mac, Muse, …), from the server's `access` list | connecting the assistant in that assistant | none connected |
| D7 | Muse | the questions you ask Muse: typed ones as text, spoken ones (push-to-talk on the watch) as a short recording of what the watch microphone heard while the button was held; Muse's answers come back as text | Meta | pairing Muse | off |
| D7a | Muse reads your conversations | transcript excerpts for a time range or a search (including other people's words), a day or week recap, or the answer of this app's own Ask (then only that answer), only while Muse is answering a question you asked | Meta | "What Muse can see" in Settings › Muse: Ask first, Allowed, or Off | Ask first once paired |
| D7b | Muse acting on your watch | the outcome (done, declined, or timed out); alarm listing returns times, smart/regular mode, enabled state and repeat days; "what's playing" returns the track's title and artist | Meta | a switch per action in Settings › Muse: timer, alarm, music, Quiet Time, open a watch app, find my watch, pause or resume recording | on once paired |
| D7c | Muse reads your health | steps, distance, active minutes, calories, sleep, and heart rate from the watch's own activity data, for the range asked | Meta | "What Muse can see": Ask first, Allowed, or Off | Ask first once paired |
| D7d | Muse reads and adds to Calendar and Reminders | events or reminders in the range asked; an event or reminder you asked it to add (it never deletes) | Meta | "What Muse can see": Calendar and Reminders are separate sources, each Ask first, Allowed, or Off, each also needing iOS's own permission | Ask first once paired |
| D7e | Muse reads and adds follow-ups | your open follow-ups; a follow-up you asked it to add | Meta | "What Muse can see": Ask first, Allowed, or Off | Ask first once paired |

Invariants that stay commitments, whatever is on: the official Pebble app never receives audio;
nothing goes to this app's developer; diagnostic logs stay on the phone; nothing is used for
advertising or profiling by this app.

**Muse facts** (confirmed 2026-10-21 by the Muse session against branch `muse-link-app` and
muse.ai/privacy; nothing has run on a device yet):
- **Pairing, once.** After the wearer presses Yes on the watch, it advertises as `MuseGadget` plus
  six hex digits for up to five minutes (visible to anyone nearby while open). The Muse app
  connects and the watch relays setup bytes to this app. Meta receives the device name, a random
  node id generated once (not tied to watch or phone hardware), a fixed version string, and the
  developer SDK token. The app receives device tokens and the Muse account username; it then makes
  one HTTPS call to api.muse.ai to check the tokens. No recording data is involved, and the
  official Pebble app receives nothing.
- **Typed questions** (Settings › Muse › Try it): the question text goes to Meta and the answer
  comes back over an encrypted WebSocket. Meta also sees the phone's IP address and the client's
  user agent. The app keeps no copy of questions or answers; Diagnostics records connection steps,
  never question or answer text, never tokens. Whether questions appear in the Muse app's chat
  history is unverified; the model says only "go to Meta".
- **Paired but idle.** With "Muse's own messages" off: nothing reaches Meta; no background
  connection, no registration, no token refresh; tokens rotate only when a question is asked.
  With it on (the default since 2026-10-21, so messages Muse starts and late answers reach the
  watch): the phone keeps a connection to Meta open while Muse is set up. Meta then sees when the
  phone is online and its IP address; nothing the person says, records, or keeps goes over it
  unless they ask. Either way Meta knows the device exists (it is listed in the person's Muse
  devices). What crosses the open link while idle (from the code, 2026-10-21):
  - on each connect: an HTTPS device-token refresh to api.muse.ai (only when the access token is
    3 h old or more) and a VM fetch; a WSS connection with a Noise handshake to Meta's gadget
    host; `link.register` with the gadget id, display name, app version, platform, and the
    names, descriptions, and parameter schemas of the switches that are on (Off sources aren't
    listed); a subscribe to the watch's chat;
  - while up: a WebSocket ping from the phone every 20 s; everything else is inbound (that chat's
    events);
  - after a drop: reconnects backing off 5 s, 15 s, 45 s, up to 5 min;
  - nothing else: no audio, transcripts, messages, or data reads.
  Muse can only use the watch or read anything within 15 minutes of a question or pick on the
  watch; any other call is refused with "The person allows this only while you answer a
  question they asked on their Pebble watch." and no data. With the switch off, the link closes
  60 s after the last question.
- **Secrets** live in this phone's Keychain (`dev.audiocompanion.muse`, after first unlock, not
  iCloud-synced, included in encrypted backups). Forget Muse deletes the tokens and username and
  keeps the node id. Delete All Recordings does not unpair Muse (pairing is a connection, not
  recorded data), matching how it treats provider keys.
- **Meta's default:** training on interactions is on by default ("Help improve our AI models",
  Muse app › Settings › Data controls; Meta says the switch also applies to past interactions; no
  retention period is stated).
- **Spoken questions (push-to-talk, decided by Roger 2026-10-21, being built):** each question
  goes to Meta as a WAV voice note, the way Meta's own gadget firmware sends it; Muse transcribes
  it and echoes what it heard (the watch shows it as "You said"); answers come back as text. The
  note can include other voices near the watch while the button is held. When recording is on,
  the question is also in the normal recording (same microphone). Push-to-talk works while
  recording is off: while Muse is paired the app keeps the watch linked with capture paused, and
  the microphone is used only while the button is held (confirm in the Muse build's tests).
- **Muse acting on the watch (D7b):** while a question you asked is open, Muse may set a timer or
  create a regular or smart one-time alarm, list/edit/delete existing alarms, control music,
  turn Quiet Time on or off, open a watch app, find the watch, or pause or resume recording.
  Alarm listing sends times, smart/regular mode, enabled state and repeat days to Muse;
  other actions return their outcome (music can also return the track title and artist). Each action has a switch under "What
  Muse can do on your watch", on by default once paired. Muse's own option buttons are drawn as a
  picker on the watch; the option the wearer picks goes to Muse as their own message, the same as
  a typed or spoken question (D7) and the same as a tap in the Muse app (the separate "choose"
  action was removed 2026-10-21).
- **Data tools (D7a, D7c-D7e; decided by Roger 2026-10-21, being built on `muse-link-app`):** each
  source is Ask first (the default once paired), Allowed, or Off. Off means the gadget never
  registers that tool, so Muse does not know it exists. Under Ask first, Muse's first call puts a
  prompt on the watch (see section 4); Allow Once (the default) lets that question's reads through
  and asks again on the next question, Always Allow makes the source Allowed, Never Allow makes it
  Off, and Not Now refuses only that call (Roger, 2026-10-21). Nothing is read or sent except while a question asked on the
  watch is open. Health comes from the watch's own activity data, not from Apple Health.
  Calendar and Reminders also need iOS's own permission. The app never asks for it up front
  (Roger, 2026-10-21): only when a Muse question needs it, or when the person sets Calendar or
  Reminders to Allowed themselves in Settings › Muse (the app then asks at once). When a question
  needs it and the app lacks it, the watch says so and the request waits for the next time the
  app is opened (a background app cannot show the iOS prompt); see section 4.
- **Planned, not built:** drawing an image from a URL Muse chose (the phone would fetch it).

## 2. Inputs

```swift
struct PrivacyInputs: Equatable {
    var transcriptionDestination: String?   // D1, nil when local only
    var aiDestination: String?              // D2, nil when local only
    var iCloudAgeDays: Int?                 // D3
    var systemSearch: SystemSearchVisibility // D4
    var server: ServerState?                // D5, nil only when not linked (paused is a state, not nil)
    var museState: MuseState?               // D7, nil when not paired
}
struct ServerState: Equatable {
    var host: String
    var paused: Bool                        // Sync off; the server keeps what it has and assistants can still read it
    var scope: SharingScope                 // all, since(date), lastDays(n)
    var clipsAllowed: Bool                  // D5a
    var editsAllowed: Bool                  // D5b
    var assistants: [Assistant]             // D6, from GET /sync/status `access`, cached with its fetch time
}
struct Assistant: Equatable { var name: String; var canWrite: Bool; var lastUsedAt: Date? }
struct MuseState: Equatable {
    var spokenQuestions: Bool                        // = MuseGadgetService.asksFromWatch; D7 then names spoken questions
    var watchActions: Set<MuseWatchAction>           // D7b, the actions switched on
    var dataSources: [MuseDataSource: MuseAccess]    // D7a, D7c-D7e; a missing key reads as .off
    var staysConnected: Bool                         // "Muse's own messages": a standing connection to Meta
}
// Owned by the derivation (so main builds without the Muse branch); the Muse branch maps onto them.
enum MuseWatchAction: CaseIterable { case timer, alarm, music, quietTime, openApp, findWatch, recording }
enum MuseDataSource: CaseIterable { case conversations, health, calendar, reminders, followUps }  // in this order everywhere
enum MuseAccess { case ask, allowed, off }
```

The stance is a pure function of `PrivacyInputs`, pinned by tests over every combination of the
binary inputs (64 cases) plus representative provider names, so no combination can print a false
sentence.

## 3. What the Privacy screen shows

1. **Stance card**, headline plus one line:
   - nothing active except D4: "Everything stays on this phone", green dot.
   - exactly one destination: name it ("Audio goes to Soniox", "Text syncs to pebbleaudio.okgodoit.com", "Your questions to Muse go to Meta").

   **The D7 sentence, word for word** (used by the Muse screen and the Privacy screen):
   "The questions you ask Muse go to Meta: typed ones as text, spoken ones as a short recording.
   Its answers come back as text. Nothing goes while you aren't asking." While Muse stays
   connected to message the watch (`MuseState.staysConnected`), the last sentence is instead:
   "Muse stays connected so it can message your watch. Only your questions, and what you allow it
   to read, go to Meta." and the stance line under "Your questions to Muse go to Meta" is "Only
   your questions, and what you allow Muse to read, go to Meta." Training line, unchanged:
   "Meta may use your questions to improve its AI. You can turn that off in the Muse app." Before
   push-to-talk ships (spokenQuestions false), the first sentence is "The questions you ask Muse
   go to Meta as text." 

   **What Muse can see (D7a, D7c-D7e), word for word**, after the D7 sentence. Lists follow the
   `MuseDataSource` order with an Oxford comma; names are "your conversations", "your health
   data", "your calendar", "your reminders", and "your follow-ups". Each line appears only when
   its list is non-empty:
   - Allowed: "When you ask, Muse can also read <allowed> to answer. What it reads goes to Meta."
   - Ask first: "Muse asks on your watch before it reads <ask first>."
   - Conversations Allowed or Ask first: "Your conversations can include what other people said."
   - Calendar, Reminders, or Follow-ups Allowed or Ask first: "Muse can add <the ones that apply,
     as "events", "reminders", "follow-ups"> you ask for. It never deletes them."
   - Music on in D7b: "When you ask what's playing, the song's title and artist go to Meta."
   The Meta row's chips: "Your questions", then one chip per Allowed source ("Conversations",
   "Health", "Calendar", "Reminders", "Follow-ups"). Ask first and Off sources get no chip. Meta
   stays one destination in the headline's N, whatever Muse can see.
   - more than one: "Your data goes to N places you chose", neutral dot, and the line "Each is listed below." Never "Nothing else leaves this phone": the bundled third-party speech engine carries its own network stack, so that blanket claim cannot be verified from source (the reason `Copy+PrivacyStance.swift` has always left it out). N counts every destination, including each assistant that can read the server.
   - sync paused but the server still holds text: the server is still a destination (`ServerState.paused == true`). Its row reads "Sync is paused" and the stance never says "Everything stays on this phone" while anything sits on the server or any assistant can read it.
2. **Where it goes**, one row per destination the PHONE sends to (D1, D2, D3, D5, D7), in the
   order of the table, each row: who receives it, what goes (Audio, Text, Clips when asked, Your
   questions), and a chevron to the screen that controls it. Inactive destinations are not listed.
   D6 (assistants reading the server) is not repeated here; it appears once, under "Who can read
   your archive", and still counts in the headline's N.
3. **Who can read your archive**, only when D5 is on: each assistant by name with what it may do
   ("Can read", "Can read and add"), when it last read, and a row to manage them. With D5 on and
   no assistant: "No assistant is connected yet." The list says when it was last fetched if the
   server could not be reached ("As of 2:14 PM").
4. **Siri & Spotlight can see**, unchanged.
5. **Commitments**, derived: the "no server of its own" line changes when D5 is on; a line about
   what each vendor may keep is added for D1, D2, D6 and D7 ("What ChatGPT, Claude, and Meta keep
   is governed by them, not by this app."); with D7 on, one more line: "Meta may use your
   questions to improve its AI. You can turn that off in the Muse app."

## 4. Turning things on

Every destination from D5 on is opt-in and off by default, and each is turned on in its own
setup, which always has three parts before anything moves: what it does (one line), exactly what
leaves and who receives it (from this model, same sentences as the Privacy screen), and a primary
button that says what it starts ("Link This Phone", "Pair with Muse"). Choices inside a feature
(D5a, D5b) are separate switches, off until switched on. Muse's data sources (D7a, D7c-D7e) are
Ask first once paired: nothing is read until the person allows it on the watch, the first time
Muse asks. The watch prompt, word for word: "Let Muse read your <calendar | reminders |
follow-ups | health data>? What it reads goes to Meta." For conversations: "Let Muse read your
conversations? What it reads, including what others said, goes to Meta." Buttons: Allow Once
(highlighted), Always Allow, Not Now, Never Allow.

When the person allows Calendar or Reminders on the watch but iOS has not given the app access
yet, Muse's call answers that access is still needed, and the watch shows, word for word: "Open
Pebble Audio on your iPhone to give it access to your <calendar | reminders>." The next time the
app comes to the foreground, it shows the iOS permission prompt for that source (once; Not Now on
the watch never queues one). If iOS access was refused before, the watch says instead: "Pebble
Audio can't read your <calendar | reminders>. You can allow it in iPhone Settings." and the
source's row in Settings › Muse reads "No access in iPhone Settings" with an Open Settings button.
Setting Calendar or Reminders to Allowed by hand in Settings › Muse asks iOS at that moment;
leaving it at Ask first never does.

**What Muse is told** (Roger, 2026-10-21). While the person has not answered yet (the watch
prompt, or the iOS prompt after "Open Pebble Audio on your iPhone…"), Muse's call stays open
and gets no reply; when the person answers, the call goes on with the read or ends with the
answer below. Only if no answer comes before a time limit a little under Muse's own limit for
a call does it end as "not answered" (Muse ends a data call at about two minutes whatever
`timeout_ms` says, measured 125 s on 2026-10-21, so the app registers 120 s
(`dataCallLimitSeconds`) and a held call ends at 110 s, `MuseTools.holdLimitSeconds`; the question's answer deadline is 240 s, so a
held call never closes the question first). Every ending tells Muse plainly what happened, so it
neither retries what was refused nor gives up on what is only pending:
- Never Allow on the watch, or the source is Off: denied. "The person does not allow Muse to
  read their <source>. Do not ask for it again." (An Off source is also never registered.)
- Not Now on the watch: declined for now. "The person said not now. Do not ask for their
  <source> again in this conversation."
- iOS access refused: no system access. "Pebble Audio has no access to the person's <source>
  in iPhone Settings. They can allow it there. Do not ask again until they do."
- No answer in time: not answered. "The person has not answered yet. You can ask again
  later."
These are outcomes only, like D7b: no data goes with them.

Settings › Muse lists them under "What Muse can see" (rows "Your conversations",
"Health", "Calendar", "Reminders", "Follow-ups"; values "Ask first", "Allowed", "Off"; the
conversations row's subtitle "Includes what other people said."), with the footer "Muse reads
these only while answering a question you asked on your watch. What it reads goes to Meta." Turning a destination off says what
stays where it went ("Your server keeps what it already has").

## 5. Copy rules

These rules cover every screen a person reads. One exception: a credential the person must fetch
from a vendor (Muse's SDK token) is named the way the vendor names it, on that feature's own
screen, so it can be found there (Roger, 2026-10-21: setting up Muse happens entirely on the Muse
screen). Heading plus at most one line per state; name receivers by name; say "text", "audio", "a clip",
"your questions", never mechanisms (no MCP, OAuth, token, gadget, batch); no reassurance nobody
asked for; Oxford comma; American spelling.
