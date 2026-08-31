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
    // MARK: Status-card families (States · Status Card artboard + Part 6.7)
    // ─────────────────────────────────────────────────────────────────────────
    enum Status {
        // green dot · no action (live minute renders below on Today)
        static let recording = "Recording"
        /// Today status card sub-line: "Pebble Time 2 · connected".
        static func connected(device: String) -> String { "\(device) · connected" }
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
        static let waiting = "Listening — words appear here as they are recognized."
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
            static let footer = "Recordings stay on this phone unless you choose a cloud provider."
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
            /// The engine cannot run on this phone at all (unsupported language).
            static let unavailable = "not available here"

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
            static let footer = "Set Mode to “Local only” to keep everything on this phone."

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
            /// Inline completion line for [Export All Audio] (B10).
            static func exported(_ count: Int) -> String { "Exported \(count) files" }
            static let deleteAll = "Delete All Recordings…"
            static let footer = "You are responsible for following local recording laws."
        }

        enum AboutYou {
            static let title = "About You"
            /// Explainer sits ON TOP of the cards on this screen.
            static let explainer =
                "Helps transcription and AI get names and jargon right. Stays on this phone."
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
            /// e.g. "0 waiting · 0 failed".
            static func queueValue(waiting: Int, failed: Int) -> String {
                "\(waiting) waiting · \(failed) failed"
            }
            static let aiEnrichment = "AI titles & summaries"
            /// e.g. "writing 12 more" / "12 waiting" / "all caught up". Background work, so
            /// it reports a backlog, never a progress bar.
            static func enrichmentValue(waiting: Int, running: Bool) -> String {
                guard waiting > 0 else { return "all caught up" }
                return running ? "writing · \(waiting) to go" : "\(waiting) waiting"
            }
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
