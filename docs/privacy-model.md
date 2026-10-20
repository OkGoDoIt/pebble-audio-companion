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
| D7b | Muse acting on your watch | only the outcome: done, declined, timed out, or the option chosen | Meta | a switch per action in Settings › Muse (timer, alarm, choice picker) | on once paired (no personal data leaves) |
| D7a | Muse may look things up in your recordings (planned) | transcript excerpts, including other people's words, only while Muse is answering a question you asked | Meta | a choice inside D7 | off |

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
- **Paired but idle: nothing reaches Meta.** No background connection, no registration, no token
  refresh; tokens rotate only when a question is asked. Meta knows the device exists (it is listed
  in the person's Muse devices).
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
  a one-off alarm, or show a choice picker; only the outcome goes back. Each action has a switch
  under "What Muse can do on your watch", on by default once paired.
- **Planned, not built:** drawing an image from a URL Muse chose (the phone would fetch it), and
  D7a lookups.

## 2. Inputs

```swift
struct PrivacyInputs: Equatable {
    var transcriptionDestination: String?   // D1, nil when local only
    var aiDestination: String?              // D2, nil when local only
    var iCloudAgeDays: Int?                 // D3
    var systemSearch: SystemSearchVisibility // D4
    var server: ServerState?                // D5, nil when not linked or sync paused
    var museState: MuseState?               // D7, nil when not paired
}
struct ServerState: Equatable {
    var host: String
    var clipsAllowed: Bool                  // D5a
    var editsAllowed: Bool                  // D5b
    var assistants: [Assistant]             // D6, from GET /sync/status `access`, cached with its fetch time
}
struct Assistant: Equatable { var name: String; var canWrite: Bool; var lastUsedAt: Date? }
struct MuseState: Equatable {
    var spokenQuestions: Bool               // = MuseGadgetService.asksFromWatch; D7 then names spoken questions
    var watchActions: Set<MuseWatchAction>  // D7b, the actions switched on (timer, alarm, choice)
    var lookupsAllowed: Bool                // D7a, false until that feature ships and is switched on
}
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
   Its answers come back as text. Nothing goes while you aren't asking." Training line, unchanged:
   "Meta may use your questions to improve its AI. You can turn that off in the Muse app." Before
   push-to-talk ships (spokenQuestions false), the first sentence is "The questions you ask Muse
   go to Meta as text." 
   - more than one: "Your data goes to N places you chose", neutral dot, and the line "Each is listed below. Nothing else leaves this phone."
2. **Where it goes**, one row per active destination, in the order of the table, each row: who
   receives it, what goes (Audio, Text, Clips when asked, Your questions), and a chevron to the
   screen that controls it. Inactive destinations are not listed.
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
(D5a, D5b, D7a) are separate switches, off until switched on. Turning a destination off says what
stays where it went ("Your server keeps what it already has").

## 5. Copy rules

These rules cover every screen a person reads. One exception: a credential the person must fetch
from a vendor (Muse's SDK token) is named the way the vendor names it, on that feature's own
screen, so it can be found there (Roger, 2026-10-21: setting up Muse happens entirely on the Muse
screen). Heading plus at most one line per state; name receivers by name; say "text", "audio", "a clip",
"your questions", never mechanisms (no MCP, OAuth, token, gadget, batch); no reassurance nobody
asked for; Oxford comma; American spelling.
