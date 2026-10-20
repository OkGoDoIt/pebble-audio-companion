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
| D7 | Muse on your watch | the questions you ask Muse (typed in the app or spoken on the watch, sent as text) | Meta | pairing Muse | off |
| D7a | Muse may look things up in your recordings | excerpts Muse asks for while answering | Meta | a choice inside D7 | off |

Invariants that stay commitments, whatever is on: the official Pebble app never receives audio;
nothing goes to this app's developer; diagnostic logs stay on the phone; nothing is used for
advertising or profiling by this app.

**Muse facts to confirm (owner: the Muse session):** what exactly goes to Meta in each Muse
feature, now and planned (typed questions; spoken questions as text or WAV; the transcript of a
spoken question; any watch command results; `recordings.search` excerpts), where the gadget
tokens live, what Meta does with interactions by default (training on by default per the Muse
memo, switchable under Data controls), and whether anything reaches Meta when Muse is paired but
not being asked. Fill in D7 and D7a from that.

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
struct MuseState: Equatable { var lookupsAllowed: Bool }   // D7a; more fields from the Muse session
```

The stance is a pure function of `PrivacyInputs`, pinned by tests over every combination of the
binary inputs (64 cases) plus representative provider names, so no combination can print a false
sentence.

## 3. What the Privacy screen shows

1. **Stance card**, headline plus one line:
   - nothing active except D4: "Everything stays on this phone", green dot.
   - exactly one destination: name it ("Audio goes to Soniox", "Text syncs to pebbleaudio.okgodoit.com", "Your questions to Muse go to Meta").
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
   is governed by them, not by this app.").

## 4. Turning things on

Every destination from D5 on is opt-in and off by default, and each is turned on in its own
setup, which always has three parts before anything moves: what it does (one line), exactly what
leaves and who receives it (from this model, same sentences as the Privacy screen), and a primary
button that says what it starts ("Link This Phone", "Pair with Muse"). Choices inside a feature
(D5a, D5b, D7a) are separate switches, off until switched on. Turning a destination off says what
stays where it went ("Your server keeps what it already has").

## 5. Copy rules

Heading plus at most one line per state; name receivers by name; say "text", "audio", "a clip",
"your questions", never mechanisms (no MCP, OAuth, token, gadget, batch); no reassurance nobody
asked for; Oxford comma; American spelling.
