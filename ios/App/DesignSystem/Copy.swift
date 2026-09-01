import Foundation

// TODO(M10): localization pass — convert every constant to `String(localized:)` with a
// per-key comment, and move interpolated functions onto `LocalizedStringResource` so
// plurals/format widths localize. Strings are intentionally plain constants until then.

/// The single approved string catalog (fixes teardown U9: vocabulary drift).
///
/// Sources, in authority order: the 20 approved artboards via
/// `docs/redesign/2026-08-30-mockup-spec-extraction.md` (per-screen specs + the closing
/// status-vocabulary list in §3) and plan Part 6.7 (approved-copy additions).
///
/// Rules (normative — copy changes are design changes):
/// - "Follow-ups", never "Actions".
/// - Protocol vocabulary (GATT, spool, checkpoint, sequence, stream id) never appears.
/// - Status-card families: dot + headline + ONE calm line + at most one action.
/// - Loss is explicit and calm; VAD silence is "quiet", never conflated with "missing".
enum Copy {

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Privacy (P0: state it once, calmly — and only if it is true)
    // ─────────────────────────────────────────────────────────────────────────

    /// Where audio and text actually go under the CURRENT modes.
    ///
    /// One place answers it, so the Settings footer and the About You explainer cannot drift
    /// apart or drift away from the code (U9). Callers pass the destinations they are actually
    /// configured for — `AppSettings.cloudTranscriptionDestination` /
    /// `remoteAiDestination`, which read the same predicates the providers are gated on — so
    /// "local only" is not a promise the app then quietly breaks, and a cloud mode names its
    /// provider instead of implying nothing leaves. No worst cases, no scare-mongering: the
    /// sentence is stated once, calmly, and it is true in either configuration.
    enum Privacy {
        /// The remote AI provider (`OpenAiChatAiProvider`) — the only one the AI modes use.
        static let remoteAi = "OpenAI"

        /// e.g. "Soniox and OpenAI". Duplicates collapse: one provider is one name.
        static func destinations(_ names: [String?]) -> String? {
            let unique = names.compactMap { $0 }.reduce(into: [String]()) { list, name in
                if !list.contains(name) { list.append(name) }
            }
            guard !unique.isEmpty else { return nil }
            return unique.count == 1 ? unique[0] : unique.joined(separator: " and ")
        }

        /// The Settings-root footer sentence. `transcription` is the cloud provider audio is
        /// sent to (nil in transcription "Local only"); `ai` is the provider transcripts are
        /// sent to (nil in AI "Local only").
        static func dataFlow(transcription: String?, ai: String?) -> String {
            switch (transcription, ai) {
            case (nil, nil):
                return "Recordings and transcripts stay on this phone."
            case (let stt?, nil):
                return "Recordings are sent to \(stt) for transcription."
            case (nil, let ai?):
                return "Recordings stay on this phone; transcripts are sent to \(ai)."
            case (let stt?, let ai?) where stt == ai:
                return "Recordings and transcripts are sent to \(stt)."
            case (let stt?, let ai?):
                return "Recordings are sent to \(stt), transcripts to \(ai)."
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Status-card families (States · Status Card artboard + Part 6.7)
    // ─────────────────────────────────────────────────────────────────────────
    enum Status {
        // green dot · no action (live minute renders below on Today)
        static let recording = "Recording"
        /// Today status card sub-line: "Pebble Time 2 · connected".
        static func connected(device: String) -> String { "\(device) · connected" }
        /// Same line before the watch's advertised name has arrived. Says only what is known
        /// rather than naming a device we cannot name (the card used to render the constant
        /// "Pebble · connected" on every install, observed by nothing).
        static let connectedUnnamed = "Connected"
        /// Recording, with the watch confirming it is capturing and deliberately sending
        /// nothing — voice-activity silence it suppressed. Calm, and visibly not loss.
        static func connectedQuiet(device: String) -> String { "\(device) · quiet" }
        static let connectedQuietUnnamed = "Quiet right now"

        // attention dot · bordered [Find Watch] — the `.streaming` latch has outlived its
        // evidence (see `Receiver.StreamEvidence`). Never says recording stopped: we do not
        // always know that, and asserting it would be the same lie pointing the other way.
        static let notHearingAudio = "Connected, not hearing audio"
        static let notHearingAudioStoppedLine =
            "Your Pebble says it is no longer recording. Find Watch starts it again."
        static let notHearingAudioUnverifiedLine =
            "Nothing has arrived for a while and your Pebble hasn’t confirmed it is still recording."
        /// The StatusStates artboard's family line.
        static func recordingLine(device: String) -> String {
            "\(device) · connected · live minute shown above"
        }

        // attention dot · filled [Resume]
        static let paused = "Paused"
        static let pausedLine = "The watch is not capturing. Coverage shows this as paused, not missing."
        static let resume = "Resume"

        // attention dot · bordered [Find Watch]
        static let reconnecting = "Reconnecting…"
        static let reconnectingLine = "Your Pebble is out of range. It keeps recording and buffers a few minutes."
        static let findWatch = "Find Watch"

        // red dot · filled [Open Settings]
        static let bluetoothOff = "Bluetooth is off"
        static let bluetoothOffLine = "Turn on Bluetooth to receive audio from your watch."
        static let openSettings = "Open Settings"

        // neutral dot · filled [Start Recording]
        static let notRecording = "Not recording"
        static let notRecordingLine = "Background audio is off."
        static let startRecording = "Start Recording"

        // violet dot · no action
        static let confirmOnWatch = "Confirm on your watch"
        static let confirmOnWatchLine = "Your Pebble is asking to allow this phone to receive audio."

        // neutral dot · filled [Set Up Transcripts] — first-run/"Later" family (6.7),
        // shown until a transcription mode is configured.
        static let transcriptsOff = "Transcripts are off"
        static let transcriptsOffLine = "Recording is safe on this phone. Choose where transcripts happen."
        static let setUpTranscripts = "Set Up Transcripts"

        static let live = "Live"
    }

    // Watch refusals ("Authorized to another phone", "This watch no longer allows this phone",
    // …) are the one part of the catalog that does NOT live here. Their words belong to
    // `StatusUI.StatusCopy` because the status card is rendered from the kit, which cannot
    // import this target — and this file compiles into the widget extension, which links
    // nothing from the kit. `DesignSystem/WatchLinkFault+Copy.swift` is the app-side seam.

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Onboarding (Connect / Confirm / Transcripts + failure branches)
    // ─────────────────────────────────────────────────────────────────────────
    enum Onboarding {
        static let connectTitle = "Audio from your Pebble"
        static let connectBody =
            "Your watch records in the background and streams to this phone. You choose where transcription happens."
        static let connectButton = "Connect Watch"
        static let connectFootnote = "Requires the custom audio firmware."

        static let confirmTitle = "Confirm on your watch"
        static let waiting = "Waiting for your Pebble…"
        /// Sub-line while the phone is still looking for the watch (before any on-watch prompt).
        static let waitingLine = "Keep the watch nearby. This usually takes a few seconds."

        // Watch-face mock on the Confirm screen.
        static let watchFaceTitle = "AUDIO COMPANION"
        static let watchFacePrompt = "Allow this phone to receive watch audio?"
        static let watchFaceAllow = "Allow"
        static let watchFaceDecline = "Decline"

        static let transcriptsTitle = "Where should transcripts happen?"
        static let onPhoneTitle = "On this phone"
        // Approved deviation from the artboard's "700 MB model": the local engine is now
        // system-managed, so the size is not ours to promise (noted in the build report).
        static let onPhoneBody = "Private. Downloads a speech model on Wi-Fi."
        static let inCloudTitle = "In the cloud"
        static let inCloudBody = "Fast and accurate. You add a provider key."
        static let laterTitle = "Later"
        static let laterBody = "Audio is kept safely; transcribe whenever you decide."
        static let continueButton = "Continue"
        static let transcriptsFootnote = "You can change this any time in Settings."

        // Cloud key hand-off (6.7): one key screen before Today.
        /// Both providers are offered at once — one can transcribe while the other runs the AI,
        /// so a screen that only takes one key at a time hides half the product.
        static let addProviderKey = "Add your provider keys"
        /// The one calm sentence that explains the split (P0: no over-explaining).
        static let providerKeysLine =
            "Soniox only transcribes; OpenAI can transcribe and run the AI features — add one, "
            + "or one of each."
        static let sonioxRole = "transcription"
        static let openAiRole = "transcription and AI"
        static let keyPlaceholder = "API key"
        static let keyReplacePlaceholder = "Replace key"
        static let saveToKeychain = "Save to Keychain"
        static let skipForNow = "Skip for now"
        /// Back affordance on the key screen — names the actual parent step (B15).
        static let backToTranscripts = "Transcripts"

        /// Failure branches (States · Onboarding artboard + the 6.7 Bluetooth-denied branch).
        /// All recoverable → bordered actions.
        enum Failure {
            static let noPebbleFound = "No Pebble found"
            static let noPebbleFoundLine = "Make sure the watch is nearby and Bluetooth is on."

            static let cantSendAudio = "This Pebble can’t send audio"
            static let cantSendAudioLine = "It needs the custom audio firmware first."
            static let firmwareGuide = "Firmware Guide"

            static let declined = "Declined on your watch"
            static let declinedLine = "Nothing was set up. You can try again any time."

            static let boundElsewhere = "Authorized to another phone"
            static let boundElsewhereLine =
                "On the watch: Settings → Audio Companion → Forget Receiver, then try again."

            static let noAnswer = "No answer on the watch"
            static let noAnswerLine = "The request expired after a minute."
            static let askAgain = "Ask Again"

            static let bluetoothDenied = "Bluetooth access is off for this app"
            static let bluetoothDeniedLine = "Allow Bluetooth in Settings to receive audio."

            /// Phone-side Bluetooth switched off entirely — same words the status card uses.
            static let bluetoothOff = Copy.Status.bluetoothOff
            static let bluetoothOffLine = Copy.Status.bluetoothOffLine

            /// The watch's GATT server refused a handle: a stale iOS cache, typical right after
            /// flashing firmware. Retrying the same handles never clears it — only re-discovery.
            static let needsReconnect = "Your Pebble needs to reconnect"
            static let needsReconnectLine =
                "Turn Bluetooth off and back on, then try again. This can happen right after "
                + "updating the watch firmware."
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Provider-key checks (kit taxonomy → what to DO about it)
    // ─────────────────────────────────────────────────────────────────────────
    /// A typed key is checked against the provider automatically. The kit returns a taxonomy and
    /// no prose ON PURPOSE — both providers' 401 bodies quote the key back — so these lines are
    /// the only wording shown, and they never repeat provider text or any part of a key.
    /// `rejected` and `outOfCredit` deliberately give opposite advice.
    enum KeyCheck {
        static let checking = "Checking…"
        static let valid = "Key works."
        static let checkAgain = "Check Again"

        /// 401 — wrong key, or half a paste.
        static let rejected = "Not accepted. Check for a missing character and paste it again."
        /// 403 — real key, wrong permissions.
        static let notPermitted = "This key isn’t allowed to use this API. Check its permissions."
        /// 429 + quota — fixing the key is the wrong instinct here.
        static let outOfCredit = "The key works, but the account is out of credit."
        /// 429 — ordinary throttling.
        static let rateLimited = "Too many checks just now. Try again in a moment."
        /// 5xx — nothing is wrong with the key.
        static let providerUnavailable = "The provider is having trouble. The key may be fine."
        static let unreachable = "No connection, so the key couldn’t be checked."
        static let unexpected = "The key couldn’t be checked right now."

        /// The Settings key screen saves first and checks second — the check is guidance, not a
        /// gate — so its verdict is prefixed with what already happened.
        static func saved(_ verdict: String) -> String { "Saved. \(verdict)" }

        /// The same verdicts in one word, for the Settings key rows ("sk-…4f2a · no credit").
        enum Row {
            static let checking = "checking…"
            static let valid = "verified"
            static let rejected = "not accepted"
            static let notPermitted = "not permitted"
            static let outOfCredit = "no credit"
            static let rateLimited = "provider busy"
            static let providerUnavailable = "provider down"
            static let unreachable = "no connection"
            static let unexpected = "not checked"
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Transcription failures (kit taxonomy → what to DO about it)
    // ─────────────────────────────────────────────────────────────────────────
    /// Why one recording is sitting in the failed queue. Same contract as `KeyCheck`, for the
    /// same reason: the kit stores `lastError` for a log — developer prose with up to 240 bytes
    /// of the provider's response body in it, which for a 401 holds the request URL and can hold
    /// the key — so nothing here is ever the stored string. `TranscriptionFailureKind` classifies
    /// it and these are the only words shown (B20, U9).
    ///
    /// Each line ends where the reader's next move is: the ones they can fix name the thing to
    /// fix, and the ones they cannot say the app keeps trying, so nobody goes hunting for a
    /// setting that would not have helped. Where a cause is shared with a key check, the wording
    /// deliberately matches `KeyCheck` — one vocabulary, so "not accepted" means the same thing
    /// on both screens.
    enum TranscriptionFailure {
        static let keyRejected = "The provider didn’t accept your key. Check it in Transcription & AI."
        static let keyNotPermitted = "Your key isn’t allowed to use this API. Check its permissions."
        static let rateLimited = "The provider was busy, or the account is out of credit."
        static let providerTrouble = "The provider had trouble on its side."
        static let providerRefusedAudio = "The provider didn’t accept the recording."
        static let timedOut = "The provider took too long to answer."
        static let recordingTooLong = "This recording is too long for the provider to accept in one piece."
        static let noConnection = "It couldn’t reach the provider."
        static let modelMissing = "The on-device model couldn’t load. Check Local model in Transcription & AI."
        static let localEngineFailed = "On-device transcription failed on this recording."
        static let audioUnreadable = "The stored audio for this recording couldn’t be read."
        static let notConfigured = "No transcription provider was available. Check Transcription & AI."
        static let unknown = "It didn’t finish, and didn’t say why."

        // Whether it will try again is a SEPARATE fact from why it failed, and it is stated in
        // exactly one place per surface: the Diagnostics row carries it in its trailing
        // "3 tries · retrying", and a conversation's state card — which has no such column —
        // appends it to the reason with `line(_:retrying:)`. Baking "It keeps trying." into the
        // reasons themselves produced the contradiction "8 tries · stopped retrying" sitting
        // directly above "It keeps trying."
        static let keepsTrying = "It keeps trying."
        static let stoppedTrying = "It has stopped retrying."

        /// Reason + retry status as one calm line, for a surface with room for only one.
        static func line(_ reason: String, retrying: Bool) -> String {
            "\(reason) \(retrying ? keepsTrying : stoppedTrying)"
        }

        /// The same reasons in two or three words, for a Diagnostics row's trailing value.
        enum Row {
            static let keyRejected = "key not accepted"
            static let keyNotPermitted = "key not permitted"
            static let rateLimited = "provider busy"
            static let providerTrouble = "provider trouble"
            static let providerRefusedAudio = "upload refused"
            static let timedOut = "timed out"
            static let recordingTooLong = "too long to send"
            static let noConnection = "no connection"
            static let modelMissing = "model not loaded"
            static let localEngineFailed = "on-device failure"
            static let audioUnreadable = "audio unreadable"
            static let notConfigured = "no provider set up"
            static let unknown = "no reason recorded"
        }

        /// Attempt bookkeeping on a failed row, e.g. "3 tries · retrying".
        static func tries(_ count: Int, retrying: Bool) -> String {
            let tries = count == 1 ? "1 try" : "\(count) tries"
            return retrying ? "\(tries) · retrying" : "\(tries) · stopped retrying"
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Today
    // ─────────────────────────────────────────────────────────────────────────
    enum Today {
        static let title = "Today"
        static let ask = "Ask"
        static let pause = "Pause"

        static let recapTitle = "Today so far"
        static func updatedAt(_ time: String) -> String { "updated \(time)" }

        static func seeAll(_ count: Int) -> String { "See all \(count)" }
        static let conversationsSection = "Conversations"

        // The live row's second line when there are no words to quote yet. Short: it sits under
        // a title, beside a duration, on a row the eye passes over. The full sentence is on the
        // Recording-now screen (`Copy.Live`), and the status card above carries the link story.
        static let liveQuiet = "Quiet right now"
        static let liveNotHearing = "No audio arriving from the watch"
        static let liveTranscriptsOff = "Recording — transcription isn't set up"
        static let liveTranscriptionDown = "Recording — live words aren't coming through"

        /// Coverage card head, e.g. "4 hr 12 min recorded".
        static func recorded(_ duration: String) -> String { "\(duration) recorded" }
        /// Coverage card trailing, e.g. "1 min missing".
        static func missing(_ duration: String) -> String { "\(duration) missing" }

        static let axisMorning = "6 AM"
        static let axisNoon = "noon"
        static let axisEvening = "6 PM"
    }

    /// The four-state audio taxonomy legend (+ Paused, shown only on days containing a pause).
    enum Legend {
        static let transcribed = "Transcribed"
        static let captured = "Captured"
        static let quiet = "Quiet"
        static let missing = "Missing"
        static let paused = "Paused"
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Library + Search
    // ─────────────────────────────────────────────────────────────────────────
    enum Library {
        static let title = "Library"
        static let scopeAll = "All"
        static let searchPlaceholder = "Search or ask"
        static let moreTags = "more…"
        /// Folds into the row meta line, e.g. "7:02 PM · 1 hr 40 min · mostly quiet".
        static let mostlyQuiet = "mostly quiet"

        // "All ⌄" scope menu (6.7).
        static let filterAll = "All"
        static let filterUntranscribed = "Untranscribed"
        static let filterWithFollowUps = "With follow-ups"
        static let filterWithMissingAudio = "With missing audio"
    }

    enum Search {
        /// Hand-off row: sparkle + "Ask about “travel”".
        static func askAbout(_ query: String) -> String { "Ask about “\(query)”" }
        static let tagsSection = "Tags"
        static let conversationsSection = "Conversations"
        static let followUpsSection = "Follow-ups"
        static func conversationCount(_ count: Int) -> String {
            count == 1 ? "1 conversation" : "\(count) conversations"
        }
        /// Empty state (6.7).
        static func noMatches(_ query: String) -> String { "Nothing matches “\(query)”." }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Ask sheet (2.8 + 6.6)
    // ─────────────────────────────────────────────────────────────────────────
    enum Ask {
        static let title = "Ask"
        static let followUpPlaceholder = "Ask a follow-up"
        static let recentSection = "Recent"
        static let clearHistory = "Clear history"
        /// Leaves the open conversation (already saved) and starts an unrelated one.
        static let newConversation = "New"
        static let didNotGoThrough = "That didn’t go through."
        /// Recent row, e.g. "1 follow-up" / "3 follow-ups".
        static func followUpCount(_ count: Int) -> String {
            count == 1 ? "1 follow-up" : "\(count) follow-ups"
        }
        /// Answer footer, e.g. "2 moments · Coffee with Dana, Evening at home".
        /// Also the Saved Notes footer ("2 moments · 9:36 PM, 9:51 PM").
        static func moments(_ count: Int, _ list: String) -> String {
            count == 1 ? "1 moment · \(list)" : "\(count) moments · \(list)"
        }
        static let nothingToAskYet =
            "Nothing to ask about yet — recordings appear here after your first conversation."

        /// Shown under an answer that was built from part of the range, never under a complete
        /// one. Without it a partial answer looks exactly like a thorough one, and "I found
        /// nothing" reads as a verdict on the whole range instead of on a slice of it.
        static func partialCoverage(read: Int, inScope: Int) -> String {
            "Read \(read) of \(inScope) conversations — this range was too large to read in "
                + "full, so anything not mentioned may simply not have been reached."
        }

        // Scope picker (6.6).
        static let scopeToday = "Today"
        static let scopeYesterday = "Yesterday"
        static let scopeLast7Days = "Last 7 days"
        static let scopeEverything = "Everything"
        static let scopePickDates = "Pick dates…"
        /// Conversation-scoped pill, e.g. "Last 2 days".
        static func scopeLastDays(_ days: Int) -> String { "Last \(days) days" }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Conversation (detail, lifecycle cards, ⋯ menu, inline markers)
    // ─────────────────────────────────────────────────────────────────────────
    enum Conversation {
        // Bottom bar. "Follow-ups" — never "Actions".
        static let ask = "Ask"
        static let notes = "Notes"
        static let followUps = "Follow-ups"

        // ⋯ menu, destructive last.
        static let rename = "Rename"
        static let editTags = "Edit Tags"
        static let retranscribe = "Re-transcribe"
        static let exportAudio = "Export Audio…"
        static let delete = "Delete…"

        // Inline markers — interruptions render where they happened, never as banners.
        /// e.g. "quiet for 40 sec" / "quiet for 2 min".
        static func quietFor(_ duration: String) -> String { "quiet for \(duration)" }
        /// e.g. "2 sec missing · Bluetooth hiccup".
        static func missingMarker(_ duration: String) -> String {
            "\(duration) missing · Bluetooth hiccup"
        }
        // An interruption with more than one cause reads "(3 reasons)" and opens on a tap.
        // The row itself never spells the causes out — at three or four of them the transcript
        // would be more apology than words — so the breakdown lives behind the tap.
        static let showInterruptionReasons = "Shows what interrupted the audio"
        static let hideInterruptionReasons = "Hides what interrupted the audio"
        /// In-card provenance, e.g. "Transcribed with Soniox · yesterday 9:54 PM".
        static func provenance(provider: String, when: String) -> String {
            "Transcribed with \(provider) · \(when)"
        }

        // Arriving from a citation (a Saved Notes / Ask chip). The band says why the
        // transcript jumped, and offers the one thing you came to do.
        static let citedMoment = "The moment this cites"
        static let playFromHere = "Play from here"

        // Lifecycle cards (States · Conversation artboard).
        static let capturedWaiting = "Captured · waiting to transcribe"
        /// e.g. "3rd in line. Audio is safe on this phone."
        static func queueLine(_ ordinal: String) -> String {
            "\(ordinal) in line. Audio is safe on this phone."
        }
        static let transcribeNow = "Transcribe Now"
        static let transcribing = "Transcribing…"
        /// e.g. "Soniox · about a minute left".
        static func transcribingLine(provider: String, remaining: String) -> String {
            "\(provider) · about \(remaining) left"
        }
        static let didntFinish = "Transcription didn’t finish"
        static let didntFinishLine = "It retries on its own. The audio is safe."
        static let retryNow = "Retry Now"

        // Enrichment (AI title/summary/tags). Transcribing is done; AI has not caught up.
        // "Working on it" and "there is genuinely nothing here" must never look alike.
        static let summaryComing = "Transcribed · summary still to come"
        static let summaryComingLine =
            "AI is working through the backlog in the background. The transcript is already saved."
        static let noSummary = "No summary for this one"
        static let noSummaryLine = "AI is turned off, so titles, tags and summaries stay blank."
        static let summaryGaveUp = "Summary didn’t generate"
        static let summaryGaveUpLine = "AI tried a few times and stopped. The transcript is safe."
        /// Library row meta, appended after the duration: a row without a title says why.
        static let rowSummaryComing = "summary on the way"

        // Delete-undo snackbar (5 s).
        static let deleted = "Conversation deleted"

        /// Shown when the id resolves to nothing — a deleted conversation reached from a
        /// stale widget tap, Spotlight result, or notification.
        static let unavailable = "This conversation is no longer available."
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Live Conversation
    // ─────────────────────────────────────────────────────────────────────────
    enum Live {
        static let title = "Recording now"
        /// e.g. "Started 12:04 PM · 48 min so far".
        static func startedLine(time: String, elapsed: String) -> String {
            "Started \(time) · \(elapsed) so far"
        }
        /// The live engine as the provenance line names it.
        static let onDeviceSource = "on-device"
        /// Text no engine has claimed. Rare and defensive — but "on-device" is a claim, so an
        /// unknown source must never fall back to it.
        static let unknownSource = "engine unknown"
        /// e.g. "Live transcript · on-device · final transcript may differ". The source is named
        /// honestly — a cloud live transcript must not claim to be on-device.
        static func provenance(source: String = onDeviceSource) -> String {
            "Live transcript · \(source) · final transcript may differ"
        }
        /// The calm line before the first words arrive (one line, per the state-card rule).
        /// TRUE ONLY while audio is actually arriving — see `LiveTranscriptStatus` for the
        /// other four things this line used to be shown for.
        static let waiting = "Listening — words appear here as they are recognized."
        /// The watch is capturing but suppressing silence. Calm: quiet is not loss (Q6).
        static let quiet = "Quiet right now — the watch sends audio when it hears sound."
        /// Nothing is reaching the phone. Says what happens to the audio meanwhile, because the
        /// honest answer is reassuring: the watch holds it and re-sends it.
        static let notHearing =
            "No audio is arriving from the watch — what it records meanwhile is sent when the "
            + "link is back."
        /// Recording is safe without transcription, and that is the part to lead with.
        static let transcriptsOff =
            "Transcription isn't set up, so no words appear here. The audio is still recorded."
        /// The live engine specifically. The final transcript is a different path and still runs.
        static let transcriptionDown =
            "Live words aren't coming through right now. The recording is safe and will be "
            + "transcribed."
        static let pause = "Pause"
        static let stop = "Stop"
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Saved Notes + templates (2.16 + 6.9)
    // ─────────────────────────────────────────────────────────────────────────
    enum Notes {
        /// e.g. "Generated 9:54 PM · GPT-5.6 Luna · from this conversation".
        static func generatedLine(time: String, model: String) -> String {
            "Generated \(time) · \(model) · from this conversation"
        }
        static let copy = "Copy"
        static let regenerate = "Regenerate"
        static let updated = "Notes updated"

        // Template sheet (6.9).
        static let templateMeetingNotes = "Meeting notes"
        static let templateDecisions = "Decisions"
        static let templateFollowUpEmail = "Follow-up email"
        static let templateStudyNotes = "Study notes"
        static let templateInterviewHighlights = "Interview highlights"
        static let templateCustomPrompt = "Custom prompt…"
        static let saveAsTemplate = "Save as template"
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Tag Editor sheet (2.15)
    // ─────────────────────────────────────────────────────────────────────────
    enum Tags {
        static let title = "Tags"
        static let addTagPlaceholder = "Add tag…"
        static let suggestionsSection = "Suggestions"
        static let footer = "Tap a tag to rename it — the rename applies everywhere."
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Settings (root + the five pushed screens)
    // ─────────────────────────────────────────────────────────────────────────
    enum Settings {
        enum Root {
            static let title = "Settings"
            static let backgroundAudio = "Background audio"
            /// Watch card sub-line when healthy.
            static let recordingConnected = "Recording · connected"
            static let transcriptionAI = "Transcription & AI"
            static let storagePrivacy = "Storage & Privacy"
            static let aboutYou = "About You"
            static let diagnostics = "Diagnostics"
            /// Q9 alert, opt-in (default off).
            static let lossAlerts = "Alert me about missed audio"
            static let lossAlertsSub = "Only long gaps, at most one an hour."
            /// Shown instead of the sub-line when iOS notifications are off for the app.
            static let lossAlertsDenied = "Notifications are off in iOS Settings."
            /// Was "Recordings stay on this phone unless you choose a cloud provider." — which
            /// read as a standing promise on an install whose default modes are BOTH cloud, and
            /// which said nothing about transcripts going to the AI provider. It now says what
            /// the current modes actually do; `Copy.Privacy.dataFlow` is the one wording.
            static func footer(transcription: String?, ai: String?) -> String {
                Copy.Privacy.dataFlow(transcription: transcription, ai: ai)
            }
        }

        enum Watch {
            static let title = "Watch"
            static let firmware = "Firmware"
            /// e.g. "v4.36 · audio companion".
            static func firmwareValue(_ version: String) -> String { "\(version) · audio companion" }
            static let watchReports = "Watch reports"
            static let findWatch = "Find Watch"
            static let forgetWatch = "Forget This Watch…"
            static let footer = "Also revocable from the watch: Settings → Audio Companion."
        }

        enum TranscriptionAI {
            static let title = "Transcription & AI"
            static let transcriptionSection = "Transcription"
            static let aiSection = "AI"
            static let mode = "Mode"
            static let localModel = "Local model"
            static let cloudProvider = "Cloud provider"
            static let model = "Model"
            /// Key rows, e.g. "Soniox key" / "OpenAI key". Keys NEVER render inline.
            static func keyRow(provider: String) -> String { "\(provider) key" }

            static let cloudFirst = "Cloud first"
            static let remoteFirst = "Remote first"
            static let localOnly = "Local only"
            // Natural extensions of the approved mode vocabulary (the enums have four cases;
            // the artboards show three labels).
            static let localFirst = "Local first"
            static let cloudOnly = "Cloud only"
            static let remoteOnly = "Remote only"
            static let savedInKeychain = "saved in Keychain"
            /// Key-row value before any key exists (matches the "not installed" register).
            static let notSet = "not set"

            // Local-model row states (6.7). The row never acts on its own — it pushes the
            // language screen below, where a download starts only on an explicit choice.
            static let notInstalled = "not installed"
            static func downloading(_ percent: Int) -> String { "downloading · \(percent)%" }
            /// Next to a progress bar the word is already implied — just the number.
            static func percent(_ percent: Int) -> String { "\(percent)%" }
            static let downloadFailed = "download failed"
            static let waitingForWiFi = "waiting for Wi-Fi"
            /// The archive is here and unpacking. Real work, no byte progress to show.
            static let installing = "finishing up"
            /// The engine cannot run on this phone at all (unsupported language).
            static let unavailable = "not available here"

            // The selected model is one that has to be downloaded, and it is not here. The kit
            // transcribes with Apple Speech meanwhile rather than leaving the audio untouched,
            // and every surface that names the selection has to say so — a picker that shows a
            // model as chosen while a different engine is running is the exact silent
            // substitution this app keeps removing.
            /// Row value, e.g. "not installed · Apple Speech".
            static let notInstalledUsingAppleSpeech = "not installed · Apple Speech"
            /// The notice on the model screen, e.g. "Parakeet TDT 0.6B isn’t downloaded…".
            static func fallbackNotice(_ name: String) -> String {
                "\(name) isn’t downloaded, so Apple Speech is transcribing. "
                    + "Tap it to download and switch."
            }
            /// The same fact once the download is running: still true, but "tap it" would be
            /// telling the reader to start something that is already going.
            static func fallbackNoticeInProgress(_ name: String) -> String {
                "Apple Speech is transcribing until \(name) finishes downloading."
            }

            // Local-model screen: the pushed model catalog.
            static let installedValue = "installed"
            static let downloadAction = "Download"
            static let inUse = "In use"
            /// Destructive row naming exactly what goes, e.g. "Remove Parakeet TDT 0.6B…".
            static func removeModel(_ name: String) -> String { "Remove \(name)…" }
            static let removeModelButton = "Remove Model"
            static func removeModelNote(_ size: String) -> String { "Frees \(size)." }
            /// Apple Speech: the files are the system's, so removal is a release, not a delete.
            static let removeSystemModelNote = "iOS frees the files when it needs the space."
            static let wifiFootnote = "Downloads run on Wi-Fi only."

            static let testConnection = "Test Connection"
            /// e.g. "Connected · 2 min ago".
            static func connectedAgo(_ ago: String) -> String { "Connected · \(ago)" }
            /// Both Modes: this screen has two of them, and transcription "Local only" alone
            /// still sends every transcript to the AI provider. Naming one of them kept
            /// "everything on this phone" from being true.
            static let footer = "Set both Modes to “Local only” to keep everything on this phone."

            // API-key change flow (6.7). Three labelled sections — what is saved and whether
            // it works, how to replace it, how to remove it — rather than one undifferentiated
            // stack of cards. The masked key is the SUBJECT of its row, never the value of a
            // row titled "saved in Keychain".
            static let currentKeySection = "Current key"
            static let replaceKeySection = "Replace key"
            static let addKeySection = "Add key"
            static let saveKey = "Save Key"
            /// Under the current-key card: where the key lives, in the user's terms.
            static let keychainFootnote = "Stored in this phone’s Keychain."
            /// Under the field while a key is already stored — states what Save will do.
            static let keyChangeFootnote = "Saving replaces the key above."
            /// Under the field right after a save. The save is never gated on the check, so
            /// "saved" is stated plainly here and the provider's verdict is shown above.
            static let keySavedFootnote = "Saved to this phone’s Keychain."
            static let deleteKey = "Delete Saved Key…"
            static let deleteKeyButton = "Delete Saved Key"
            /// The honest consequence — named under the row, and again in the dialog.
            static func deleteKeyFootnote(provider: String) -> String {
                "Anything that uses your \(provider) key stops working until you add another."
            }
            static func deleteKeyMessage(provider: String) -> String {
                "This removes the \(provider) key from this phone’s Keychain. "
                    + "You’ll need to paste it again to use \(provider)."
            }

            // Key-check wording lives in `Copy.KeyCheck` — one catalog for both the onboarding
            // key screen and this one, so the two can never drift apart (U9).
        }

        enum Storage {
            static let title = "Storage & Privacy"
            static let recordings = "Recordings"
            static let freeSpace = "Free space"
            static let keepAudio = "Keep audio"
            /// Keep-audio options: 7 · 14 · 30 · 90 · 180 · 365 days (6.7).
            static func keepDays(_ days: Int) -> String { "\(days) days" }
            static let autoExport = "Auto-export WAV files"
            static let autoExportSub = "Plain audio copies in the export folder"
            static let exportAll = "Export All Audio"
            /// Inline completion line for [Export All Audio] and the conversation's Export
            /// Audio… (B10). A single-segment conversation is one file, so it must not read
            /// "Exported 1 files".
            static func exported(_ count: Int) -> String {
                count == 1 ? "Exported 1 file" : "Exported \(count) files"
            }
            static let deleteAll = "Delete All Recordings…"
            static let footer = "You are responsible for following local recording laws."

            // Storage limit. Off by default: an invisible size cap used to delete recordings
            // before "Keep audio" ever did, which made the visible rule a lie. The rule is
            // stated whether or not a limit is set, so nothing disappears unexplained.
            static let storageLimit = "Storage limit"
            static let noLimit = "No limit"
            static func usedOfLimit(used: String, limit: String) -> String {
                "\(used) of \(limit) used"
            }
            static let limitFooter =
                "Recordings are removed once they pass Keep audio. With a storage limit set, the "
                + "oldest fully-transcribed recordings also go when the total goes over it — "
                + "recovered audio last."
        }

        enum AboutYou {
            static let title = "About You"
            /// Explainer sits ON TOP of the cards on this screen.
            ///
            /// It used to end "Stays on this phone." flatly, and that was false out of the box:
            /// this text is the Soniox recognition context, the OpenAI STT prompt and the
            /// grounding block on every remote AI call, and both modes default to cloud. It is
            /// still true in local-only modes, so the sentence follows the modes rather than
            /// asserting one of them.
            static func explainer(destinations: String?) -> String {
                let lead = "Helps transcription and AI get names and jargon right."
                guard let destinations else { return "\(lead) Stays on this phone." }
                return "\(lead) It goes to \(destinations) with the audio and transcripts "
                    + "they handle."
            }
            static let contacts = "Contacts"
            static let calendar = "Calendar"
            /// e.g. "142 people imported".
            static func peopleImported(_ count: Int) -> String { "\(count) people imported" }
            /// e.g. "next 3 weeks".
            static func nextWeeks(_ weeks: Int) -> String { "next \(weeks) weeks" }
            /// Import-row value before anything is imported (matches "not installed").
            static let notImported = "not imported"
            static let clearImported = "Clear Imported Context…"
        }

        enum Diagnostics {
            static let title = "Diagnostics"
            static let receiver = "Receiver"
            static let receiverRecording = "Recording from Pebble"
            static let watchReports = "Watch reports"
            static let transcriptionQueue = "Transcription queue"
            /// e.g. "0 waiting · 0 failed" / "3 waiting · held in the background · 0 failed".
            ///
            /// `heldInBackground` is why nothing moved: local transcription and AI are deferred
            /// while the app is not in the foreground. The runtime has always computed that flag
            /// and no surface ever read it, so a queue that was simply waiting for the user to
            /// open the app looked identical to one that was stuck.
            static func queueValue(
                waiting: Int, failed: Int, heldInBackground: Bool = false
            ) -> String {
                var line = "\(waiting) waiting"
                if waiting > 0, heldInBackground { line += " · held in the background" }
                return line + " · \(failed) failed"
            }
            /// Audio the watch tried to hand over and the link would not take, counted by the
            /// watch itself. Named for the event, not the mechanism: the wire calls it
            /// backpressure, and that word never reaches a screen.
            ///
            /// It is the one thing that separates two failures that look identical from here —
            /// climbing while audio goes missing means the link could not keep up; flat while
            /// audio goes missing means this phone stopped acknowledging and the watch's buffer
            /// never freed — and they have opposite fixes.
            static let watchCouldNotSend = "Watch couldn’t send"
            /// e.g. "1487 times" / "never" / "not reported by this watch".
            ///
            /// The last case is NOT "never": firmware older than this counter leaves the field
            /// zero, so reading it as a count would answer the question confidently and wrongly.
            static func watchCouldNotSendValue(_ count: UInt32?) -> String {
                guard let count else { return "not reported by this watch" }
                switch count {
                case 0: return "never"
                case 1: return "once"
                default: return "\(count) times"
                }
            }
            /// The support-report line: the number plus how to read it, because the person
            /// reading a pasted report is exactly the person who has to act on it.
            static func watchCouldNotSendReport(_ count: UInt32?) -> String {
                guard let count else {
                    return "Watch couldn’t send: not reported by this watch "
                        + "(firmware older than the counter — not the same as never)"
                }
                return "Watch couldn’t send: \(count) times since the watch started "
                    + "(with audio missing: climbing = the link couldn’t keep up, "
                    + "flat = this phone stopped acknowledging)"
            }

            static let aiEnrichment = "AI titles & summaries"
            /// e.g. "writing 12 more" / "12 waiting" / "all caught up". Background work, so
            /// it reports a backlog, never a progress bar.
            static func enrichmentValue(waiting: Int, running: Bool) -> String {
                guard waiting > 0 else { return "all caught up" }
                return running ? "writing · \(waiting) to go" : "\(waiting) waiting"
            }
            /// Section over the failed-task rows. Named for what it holds, so an empty queue
            /// simply has no section rather than a reassuring "0 problems".
            static let failures = "Didn’t transcribe"
            static let recentSegments = "Recent segments"
            // Plain-language segment states — never key=value dumps.
            static let segmentRecordingNow = "recording now"
            static let segmentContinued = "continued"
            static let segmentContinuedDetail = "reattached after a blip"
            static let segmentStopped = "stopped"
            static let supportReport = "Support Report"
            static let detailedLogs = "Detailed Logs"
            /// Before anything has happened there is nothing to show — say so, calmly.
            static let noLogs = "Nothing logged yet."
            static let footer = "Counters and gap metadata only — never audio or transcript text."

            /// The refusal row. Present only when the watch actually said no — an absent row
            /// is the calm way to say "nothing is wrong with the link".
            static let watchLink = "Watch link"

            // Rebuild Search Index. The index is derived data, so losing it costs nothing but
            // the time to write it again — which is exactly what the row has to say, because
            // "rebuild" next to "Delete All Data" reads like a destructive button otherwise.
            static let rebuildIndex = "Rebuild Search Index"
            static let rebuildIndexBusy = "Rebuilding…"
            static let rebuildIndexFooter =
                "Rebuilds what Search and Spotlight look through. Recordings, transcripts and "
                + "notes are not touched. Takes a few seconds for a large library."
            static func rebuildIndexDone(_ count: Int) -> String {
                count == 1
                    ? "Rebuilt · 1 conversation indexed"
                    : "Rebuilt · \(count) conversations indexed"
            }
            static let rebuildIndexFailed = "Couldn’t rebuild the index. Try again."
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Notifications (Q9 loss notification, 6.7)
    // ─────────────────────────────────────────────────────────────────────────
    enum Notifications {
        static let lossTitle = "Some audio was missed"
        /// e.g. duration "20 minutes". Deep-links to Today.
        static func lossBody(duration: String) -> String {
            "Your Pebble couldn’t reach this phone for about \(duration) — audio in that window is missing."
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Empty states (6.7 — one calm line + one action, per the state-card rule)
    // ─────────────────────────────────────────────────────────────────────────
    enum Empty {
        /// First-run Today; the status card carries the action.
        static let todayFirstRun = "Ready when you are."
        /// Startup recovery / the one-time import from the old app. On a migrated first launch
        /// that takes tens of seconds, during which the library genuinely reads as empty — and
        /// "Ready when you are." told a user with hundreds of recordings that they had none.
        static let todayRecovering = "Getting your recordings ready…"
        static let library = "Recordings appear here after your first conversation."
        static let followUpsAllDone = "All caught up."
        // No-search-matches lives in Search.noMatches(_:).
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Q11 coverage-strip popover (one line, auto-dismisses)
    // ─────────────────────────────────────────────────────────────────────────
    enum Popover {
        /// e.g. "quiet 2:10–2:14 PM".
        static func quietSpan(_ range: String) -> String { "quiet \(range)" }
        /// e.g. "missing 40 sec — Bluetooth".
        static func missingSpan(_ duration: String) -> String { "missing \(duration) — Bluetooth" }
        /// e.g. "paused 1:00–1:20 PM".
        static func pausedSpan(_ range: String) -> String { "paused \(range)" }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Home Screen / Lock Screen widgets + Control Center (6.8)
    // ─────────────────────────────────────────────────────────────────────────
    //
    // A widget is the only surface the user sees without opening the app, so it answers this
    // product's core question — "is it actually recording right now?" — and never overclaims.
    // Vocabulary is reused from `Status` wherever a state already has an approved word; only
    // the widget-specific chrome lives here.
    enum Widgets {
        // Gallery entries. Names are what the user scrolls past in the widget picker, so each
        // says what it is FOR, not what it contains.
        static let statusName = "Recording status"
        static let statusDescription = "Whether your Pebble is recording, for how long, and a button to pause or resume."
        static let nowName = "Recording now"
        static let nowDescription = "The conversation being recorded: its title, the last thing heard, and recent activity."
        static let followUpsName = "Follow-ups"
        static let followUpsDescription = "Open follow-ups from your conversations. Tap one to open it."
        static let coverageName = "Day coverage"
        static let coverageDescription = "A diagnostic strip of the whole day — what was recorded, quiet, and missing. Start with Recording status if you want to see or change what is happening now."

        /// Shown while a requested change has not been confirmed by the app yet. The trailing
        /// ellipsis is the honesty: the switch moved, the watch has not answered.
        static let resuming = "Resuming…"
        static let pausing = "Pausing…"

        /// The snapshot is too old to be presented as the live state — say when it is from
        /// rather than assert a state the app has not confirmed since.
        static func asOf(_ time: String) -> String { "as of \(time)" }
        /// …and put the state itself in the past tense while you are at it. "Recording" beside
        /// "as of 9:12 AM" still reads, at a glance, as a microphone that is on right now.
        static func lastSeen(_ state: String) -> String { "Last seen: \(state)" }
        /// Nothing has ever been written (fresh install, widget added before first launch).
        static let noData = "Open Pebble Audio to get started."

        /// Live-conversation chrome.
        static let untitledConversation = "This conversation"
        /// Short form of `Live.waiting` — a widget has one line, not a sentence and a half.
        static let listening = "Listening…"
        static let nothingRecording = "Nothing recording right now."

        /// Follow-ups count, e.g. "4 open".
        static func openCount(_ count: Int) -> String { "\(count) open" }

        /// Accessibility labels for the interactive control (the button itself is an icon).
        static let pauseHint = "Pause capture"
        static let resumeHint = "Resume capture"
        static let startHint = "Start recording"
        /// Recent-activity bars are decorative next to the words that already say the state.
        static let activityLabel = "Recent activity"
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Shared verbs
    // ─────────────────────────────────────────────────────────────────────────
    enum Common {
        static let cancel = "Cancel"
        static let done = "Done"
        static let save = "Save"
        static let edit = "Edit"
        static let undo = "Undo"
        static let retry = "Retry"
        static let tryAgain = "Try Again"
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Accessibility (spoken-only; uses the same approved vocabulary)
    // ─────────────────────────────────────────────────────────────────────────
    enum A11y {
        static func removeTag(_ name: String) -> String { "Remove \(name)" }
        static let sendQuestion = "Send question"
        static let play = "Play"
        static let pausePlayback = "Pause playback"
        static let more = "More actions"
        static let share = "Share"
        static let followUpDone = "Done"
        static let followUpNotDone = "Not done"
        static let followUpHint = "Double tap to change"
        static let waveformLabel = "Live minute waveform"
        static let coverageLabel = "Day coverage"
        static let coverageHint = "Double tap for a breakdown of the day"
        static func filterChip(_ name: String, count: Int?) -> String {
            guard let count else { return name }
            return "\(name), \(count) conversation\(count == 1 ? "" : "s")"
        }
        static func tag(_ name: String) -> String { "Tag: \(name)" }
        static func scope(_ label: String) -> String { "Search scope: \(label)" }
        static let scopeHint = "Double tap to change how far back Ask looks"
        static let newConversationHint = "Double tap to start a new Ask conversation"
        /// The waiting turn reads as an answer on its way, not as a stalled screen.
        static func askThinking(_ question: String) -> String {
            "\(question). Answering…"
        }

        /// One transcript turn as a single VoiceOver element, e.g.
        /// "9:46 AM, Dana, let's move the walkthrough" — the time is always spoken, even when
        /// the visual rail suppresses a repeated minute.
        static func transcriptTurn(time: String?, speaker: String?, text: String) -> String {
            [time, speaker, text].compactMap { $0 }.joined(separator: ", ")
        }
        /// Suffix for the turn still being transcribed.
        static let turnInProgress = "still being transcribed"
        /// One inline marker row, e.g. "9:48 AM, quiet for 2 min".
        static func transcriptMarker(time: String?, text: String) -> String {
            [time, text].compactMap { $0 }.joined(separator: ", ")
        }

        /// One opened cause, e.g. "watch buffer filled while disconnected, 45 min · 3 times".
        static func transcriptMarkerReason(text: String, detail: String) -> String {
            "\(text), \(detail)"
        }

        /// Live-minute summary, e.g. "42 seconds recorded, 10 seconds quiet, 8 seconds missing".
        static func waveformSummary(recordedSec: Int, quietSec: Int, missingSec: Int) -> String {
            var parts: [String] = ["\(recordedSec) seconds recorded"]
            if quietSec > 0 { parts.append("\(quietSec) seconds quiet") }
            if missingSec > 0 { parts.append("\(missingSec) seconds missing") }
            return parts.joined(separator: ", ")
        }

        /// Day-coverage summary from span fractions (whole percents).
        static func coverageSummary(
            recordedPct: Int, quietPct: Int, missingPct: Int, pausedPct: Int
        ) -> String {
            var parts: [String] = ["\(recordedPct)% recorded"]
            if quietPct > 0 { parts.append("\(quietPct)% quiet") }
            if missingPct > 0 { parts.append("\(missingPct)% missing") }
            if pausedPct > 0 { parts.append("\(pausedPct)% paused") }
            return "Day coverage: " + parts.joined(separator: ", ")
        }
    }
}
