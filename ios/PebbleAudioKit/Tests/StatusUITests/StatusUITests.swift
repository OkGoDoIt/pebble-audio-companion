import Foundation
import Testing
import WireProtocol
import SegmentStore
import Receiver
@testable import StatusUI

// Port of `app/src/commonTest/.../ui/StatusUiTest.kt`, same names where the behaviour
// survived. Cases that pinned the KMP Today-timeline builder and the KMP in-memory library
// matcher went with them: the shipped app builds Today from conversations and searches through
// SearchKit's FTS5 index, so those helpers were a second engine nothing could reach.
//
// Assertions on strings the redesign replaced (plan Part 2-B #18: the status-card families'
// approved copy wins over the old KMP strings) are adapted to the new copy; every invariant
// assertion — protocol-vocabulary bans, raw-platform-error bans, recovery-action presence,
// paused-is-never-missing, the Today gap-summary thresholds — is kept exact.
//
// Structural adaptations mirroring the ported module (see Sources/StatusUI):
// - `AudioCompanionSettings(backgroundReceiverEnabled:)` -> `CaptureIntent` (.active / .off).
// - `AudioCompanionDiagnostics(pauseRequested:)` -> `storagePauseRequested:`.
// - Transcripts are plain text; annotations use StatusUI's display slice.

private func meta(
    _ segmentId: String,
    _ receivedAtMs: Int64,
    open: Bool = false,
    gaps: [GapMeta] = []
) -> SegmentMeta {
    SegmentMeta(
        segmentId: segmentId,
        streamId: 7,
        protocolVersion: 1,
        codecIdRaw: 1,
        channels: 1,
        frameSamples: 320,
        sampleRateHz: 16_000,
        bitRateBps: 9_800,
        frameDurationMs: 20,
        startTimeMs: UInt64(max(receivedAtMs, 0)),
        startMonotonicMs: 1_000,
        receivedAtMs: receivedAtMs,
        firstSampleIndex: 0,
        lastSampleIndexExclusive: 160_000, // 10 s
        frameCount: 500,
        gaps: gaps,
        closeReason: open ? nil : .rotated
    )
}

private func isNotBlank(_ text: String) -> Bool {
    !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

/// Deterministic RNG for the large randomized classifier test (Swift's SystemRandom is not
/// seedable; exact values need not match Kotlin's Random(42), only stay reproducible).
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite struct StatusUiTest {

    @Test func watchReportedStateOverridesSessionView() {
        // The watch paused for dictation mid-stream: the phone must not claim Recording.
        let conflict = statusModel(
            state: .streaming(streamId: 7), intent: .active, watchServiceStateRaw: 4
        )
        #expect(conflict.family == .paused)
        #expect(conflict.headline.contains("microphone"), "\(conflict.headline)")

        // Watch-side toggle off while connected.
        let disabled = statusModel(
            state: .authorized, intent: .active, watchServiceStateRaw: 0
        )
        #expect(disabled.headline.contains("off on the watch"), "\(disabled.headline)")
        #expect(disabled.family == .notRecording)
        #expect(disabled.action == .start)

        // Deliberate watch-side pause: the redesign's Paused family with the filled resolving
        // action (KMP offered Start; [Resume] is the approved copy).
        let paused = statusModel(
            state: .authorized, intent: .active, watchServiceStateRaw: 5
        )
        #expect(paused.headline == StatusCopy.paused)
        #expect(paused.detail == StatusCopy.pausedLine) // paused, never "missing"
        #expect(paused.action == .resume)

        // Storage-policy pause keeps the storage copy.
        let storagePaused = statusModel(
            state: .streaming(streamId: 7),
            intent: .active,
            storagePauseRequested: true,
            watchServiceStateRaw: 5
        )
        #expect(storagePaused.headline.contains("storage"), "\(storagePaused.headline)")

        // Watch-side power policy is held by the watch and should not offer app resume.
        let powerSave = statusModel(
            state: .streaming(streamId: 7), intent: .active, watchServiceStateRaw: 8
        )
        #expect(powerSave.headline.contains("saving power"), "\(powerSave.headline)")
        #expect(powerSave.action == nil)

        // Unknown/streaming watch state defers to the session view (new headline: "Recording").
        let streaming = statusModel(
            state: .streaming(streamId: 7), intent: .active, watchServiceStateRaw: 3
        )
        #expect(streaming.headline == StatusCopy.recording)
        #expect(streaming.family == .recording)
    }

    @Test func watchServiceStateLabelsCoverAllStates() {
        for raw in 0...8 {
            #expect(isNotBlank(watchServiceStateLabel(raw)))
        }
        #expect(watchServiceStateLabel(nil) == "Not connected")
    }

    @Test func disconnectedAndDisabledIsOffWithStartAction() {
        let status = statusModel(state: .disconnected, intent: .off)
        // New approved family copy: "Not recording" / "Background audio is off."
        #expect(status.family == .notRecording)
        #expect(status.headline == StatusCopy.notRecording)
        #expect(status.detail == StatusCopy.notRecordingLine)
        #expect(status.action == .start)
        #expect(status.dot == .neutral)
    }

    @Test func disconnectedWhileEnabledIsWaitingForPebbleWithReconnect() {
        let status = statusModel(state: .disconnected, intent: .active)
        // New approved family copy: "Reconnecting…" (was "Waiting for Pebble").
        #expect(status.family == .reconnecting)
        #expect(status.headline == StatusCopy.reconnecting)
        // The user must always have a manual escape hatch out of a stuck link
        // ([Find Watch] attempts a connection — the ported Reconnect affordance).
        #expect(status.action == .findWatch)
    }

    @Test func connectingAndAuthorizingOfferReconnect() {
        let connecting = statusModel(state: .connecting, intent: .active)
        #expect(connecting.headline == "Connecting to your Pebble")
        #expect(connecting.action == .findWatch)

        let authorizing = statusModel(state: .authorizing, intent: .active)
        #expect(authorizing.action == .findWatch)
    }

    @Test func streamingIsRecordingWithStopAction() {
        let status = statusModel(state: .streaming(streamId: 9), intent: .active)
        // New headline "Recording" (was "Recording from Pebble"); the stop-capture semantic
        // stays on the model even though the drawn card shows no button (Today's transport
        // surface renders it).
        #expect(status.family == .recording)
        #expect(status.headline == StatusCopy.recording)
        #expect(status.action == .stop)
        #expect(status.dot == .active)

        // Known device name renders the approved connected-device sub-line.
        let named = statusModel(
            state: .streaming(streamId: 9), intent: .active, deviceName: "Pebble Time 2"
        )
        #expect(named.detail == "Pebble Time 2 · connected")
    }

    @Test func streamingUnderStoragePressureIsPaused() {
        let status = statusModel(
            state: .streaming(streamId: 9), intent: .active, storagePauseRequested: true
        )
        #expect(status.headline == "Paused: phone storage low")
        #expect(status.family == .paused) // paused, never "missing"
        #expect(status.dot == .attention)
    }

    @Test func powerSaveGapIsExplainedCalmly() {
        let text = gapDescription(
            GapMeta(
                firstMissingSequence: 1,
                missingFrameCount: 50,
                firstMissingSampleIndex: 320,
                origin: GapMeta.originWatch,
                reasonRaw: Int(GapReason.powerSave.rawValue)
            )
        )
        #expect(text == "watch was saving power")
    }

    @Test func silenceSuppressedGapIsExplainedAsQuietAudio() {
        let text = gapDescription(
            GapMeta(
                firstMissingSequence: 1,
                missingFrameCount: 50,
                firstMissingSampleIndex: 320,
                origin: GapMeta.originWatch,
                reasonRaw: Int(GapReason.silenceSuppressed.rawValue)
            )
        )
        #expect(text == "quiet audio was skipped")
    }

    @Test func suppressedSilenceIsNeverCountedAsLoss() {
        // A segment whose only "gaps" are voice-activity silence has nothing wrong: no
        // "interrupted" summary, and no time counted as missing.
        var silenceGaps = [GapMeta]()
        for index in 0..<3 {
            let sequence = UInt32(index * 100 + 1)
            silenceGaps.append(
                GapMeta(
                    firstMissingSequence: sequence,
                    missingFrameCount: 5_000,
                    firstMissingSampleIndex: UInt64(sequence) * 320,
                    origin: GapMeta.originWatch,
                    reasonRaw: Int(GapReason.silenceSuppressed.rawValue)
                )
            )
        }
        let quiet = meta("seg-quiet", 0, gaps: silenceGaps)
        #expect(totalGapMs(quiet) == 0)
        #expect(visibleLossGaps(quiet).isEmpty)
    }

    @Test func onlyGenuineLossIsNamedAlongsideSilence() {
        // Mixed: one real loss (mic conflict) plus skipped silence. The summary speaks only to
        // the loss; the silence adds neither time nor a second reason.
        let mixed = meta(
            "seg-mixed",
            0,
            gaps: [
                GapMeta(
                    firstMissingSequence: 1,
                    missingFrameCount: 100, // 2 s
                    firstMissingSampleIndex: 320,
                    origin: GapMeta.originWatch,
                    reasonRaw: Int(GapReason.micConflict.rawValue)
                ),
                GapMeta(
                    firstMissingSequence: 200,
                    missingFrameCount: 5_000,
                    firstMissingSampleIndex: 200 * 320,
                    origin: GapMeta.originWatch,
                    reasonRaw: Int(GapReason.silenceSuppressed.rawValue)
                ),
            ]
        )
        #expect(totalGapMs(mixed) == 2_000)
        let reasons = visibleLossGaps(mixed).map(gapDescription)
        #expect(reasons == ["watch dictation used the mic"])
    }

    @Test func duplicateSequenceSkipCoveredBySuppressedSilenceIsQuiet() {
        let quiet = GapMeta(
            firstMissingSequence: 100,
            missingFrameCount: 5_000,
            firstMissingSampleIndex: 100 * 320,
            origin: GapMeta.originWatch,
            reasonRaw: Int(GapReason.silenceSuppressed.rawValue)
        )
        let duplicateSkip = GapMeta(
            firstMissingSequence: 100,
            missingFrameCount: 5_000,
            firstMissingSampleIndex: 100 * 320,
            origin: GapMeta.originSequenceSkip
        )
        let segment = meta("seg-duplicate-quiet", 0, gaps: [quiet, duplicateSkip])

        #expect(totalGapMs(segment) == 0)
        #expect(visibleLossGaps(segment).isEmpty)
    }

    @Test func visibleLossGapsMatchesBruteForceOnLargeInput() {
        // visibleLossGaps used to be O(gaps^2) (every gap rescanned the whole list), which froze
        // the Today timeline for ~12 s once segments accumulated thousands of gap records. The
        // O(n log n) rewrite must stay semantically identical to the old per-gap rescan. Build a
        // big, varied gap set and compare against a brute-force reference of the original rule.
        var rng = SplitMix64(seed: 42)
        let gaps = (0..<2_000).map { _ -> GapMeta in
            let start = UInt32(Int.random(in: 0..<5_000, using: &rng))
            let count = UInt32(Int.random(in: 1..<500, using: &rng))
            let roll = Int.random(in: 0..<3, using: &rng)
            return GapMeta(
                firstMissingSequence: start,
                missingFrameCount: count,
                firstMissingSampleIndex: UInt64(start) * 320,
                origin: roll == 0 ? GapMeta.originSequenceSkip : GapMeta.originWatch,
                reasonRaw: roll == 1
                    ? Int(GapReason.silenceSuppressed.rawValue)
                    : Int(GapReason.micConflict.rawValue)
            )
        }
        func bruteForceVisible(_ all: [GapMeta]) -> [GapMeta] {
            all.filter { gap in
                if isSilenceGap(gap) { return false }
                if gap.origin != GapMeta.originSequenceSkip { return true }
                let start = UInt64(gap.firstMissingSequence)
                let end = start + UInt64(gap.missingFrameCount)
                return !all.contains { c in
                    isSilenceGap(c)
                        && UInt64(c.firstMissingSequence) <= start
                        && UInt64(c.firstMissingSequence) + UInt64(c.missingFrameCount) >= end
                }
            }
        }
        let segment = meta("seg-large", 0, gaps: gaps)
        #expect(bruteForceVisible(gaps) == visibleLossGaps(segment))
    }

    @Test func unrelatedSequenceSkipStillCountsAsMissing() {
        let quiet = GapMeta(
            firstMissingSequence: 100,
            missingFrameCount: 5_000,
            firstMissingSampleIndex: 100 * 320,
            origin: GapMeta.originWatch,
            reasonRaw: Int(GapReason.silenceSuppressed.rawValue)
        )
        let realSkip = GapMeta(
            firstMissingSequence: 6_000,
            missingFrameCount: 50,
            firstMissingSampleIndex: 6_000 * 320,
            origin: GapMeta.originSequenceSkip
        )
        let segment = meta("seg-real-skip", 0, gaps: [quiet, realSkip])

        #expect(totalGapMs(segment) == 1_000)
        #expect(visibleLossGaps(segment) == [realSkip])
        #expect(gapDescription(realSkip) == "phone briefly missed audio")
    }

    @Test func deniedMismatchExplainsForeignReceiver() {
        let status = statusModel(
            state: .denied(statusRaw: Int(AuthStatus.deniedMismatch.rawValue)),
            intent: .active
        )
        // New approved copy ("Authorized to another phone", extraction §2.19); the recovery
        // guidance must still name the watch-side Forget Receiver step.
        #expect(status.headline == StatusCopy.boundElsewhere)
        #expect(status.detail?.contains("Forget Receiver") == true)
        #expect(status.action != nil)
    }

    @Test func deniedDisabledOffersDeliberateRestart() {
        let status = statusModel(
            state: .denied(statusRaw: Int(AuthStatus.deniedDisabled.rawValue)),
            intent: .active
        )
        #expect(status.headline == "Background audio is off on the watch")
        #expect(status.action == .start)
    }

    @Test func noProtocolVocabularyInHeadlines() {
        let states: [ReceiverSessionState] = [
            .disconnected,
            .connectionFailed(kind: .linkRejected, detail: "Writing is not permitted."),
            .connecting,
            .authorizing,
            .pendingConsent,
            .pendingEnable,
            .denied(statusRaw: Int(AuthStatus.deniedDisabled.rawValue)),
            .authorized,
            .streaming(streamId: 1),
            .revoked(reasonRaw: 1),
        ]
        let banned = ["GATT", "AUTH", "checkpoint", "spool", "sequence", "stream id", "NimBLE"]
        for state in states {
            let status = statusModel(state: state, intent: .active)
            let text = status.headline + " " + (status.detail ?? "")
            for word in banned {
                #expect(
                    !text.contains(word),
                    "state \(state) copy must not mention '\(word)': \(text)"
                )
            }
        }
    }

    @Test func connectionFailedNeverLeaksRawPlatformErrorAndGuidesRecovery() {
        // The raw Core Bluetooth / GATT detail is diagnostics-only; it must never reach the user.
        let linkRejected = statusModel(
            state: .connectionFailed(kind: .linkRejected, detail: "Writing is not permitted."),
            intent: .active
        )
        let text = linkRejected.headline + " " + (linkRejected.detail ?? "")
        #expect(
            text.range(of: "not permitted", options: .caseInsensitive) == nil,
            "must not surface the raw platform error: \(text)"
        )
        // The stale-cache case is only fixed by re-discovery, so the copy must point at Bluetooth.
        #expect(
            (linkRejected.detail ?? "").range(of: "Bluetooth", options: .caseInsensitive) != nil,
            "LinkRejected copy should tell the user to power-cycle Bluetooth: \(text)"
        )
        #expect(linkRejected.action == .findWatch) // the manual-reconnect affordance

        // Every failure kind must produce non-empty, plain-language copy plus a recovery action.
        let kinds: [ConnectFailureKind] = [
            .bluetoothOff, .bluetoothUnauthorized, .bluetoothUnavailable,
            .watchUnreachable, .linkRejected, .unknown,
        ]
        for kind in kinds {
            let status = statusModel(
                state: .connectionFailed(kind: kind, detail: "raw detail \(kind)"),
                intent: .active
            )
            #expect(isNotBlank(status.headline), "kind \(kind) must have a headline")
            #expect(
                !(status.headline + (status.detail ?? "")).contains("raw detail"),
                "kind \(kind) must not echo the raw detail"
            )
            #expect(status.action != nil, "kind \(kind) must offer a recovery action")
        }
    }
}

@Suite struct TimelineTest {
    private let dayMs: Int64 = 24 * 3_600_000
    private let nowMs: Int64 = 1_750_000_000_000 // fixed reference time

    @Test func segmentTitleCleansStoredMarkdownAnnotationTitle() {
        let title = segmentTitle(
            meta("seg-markdown-title", nowMs),
            transcriptText: nil,
            annotation: SegmentAnnotation(
                segmentId: "seg-markdown-title",
                title: "**TITLE:** Troubleshooting account setup",
                createdAtMs: nowMs
            )
        )

        #expect(title == "Troubleshooting account setup")
    }

    @Test func displayGapMsCapsImpossibleTotalsToSegmentDuration() {
        let withHugeGap = meta(
            "seg-gap",
            nowMs,
            gaps: [
                GapMeta(
                    firstMissingSequence: 10,
                    missingFrameCount: 10_000_000,
                    firstMissingSampleIndex: 3_200,
                    origin: GapMeta.originSequenceSkip
                ),
            ]
        )

        #expect(displayGapMs(withHugeGap) == 10_000)
    }

    @Test func segmentTitlePrefersTranscriptSnippet() {
        let segment = meta("seg-1", nowMs)
        #expect(segmentTitle(segment, transcriptText: nil) == "Conversation")
        #expect(segmentTitle(segment, transcriptText: "Hello there") == "Hello there")
        let long = Array(repeating: "word", count: 40).joined(separator: " ")
        #expect(segmentTitle(segment, transcriptText: long).hasSuffix("…"))
        #expect(segmentTitle(meta("seg-2", nowMs, open: true), transcriptText: nil) == "Recording now")
    }

    @Test func segmentTitleUsesLivePreviewForOpenRecordingUntilFinalTranscriptExists() {
        let open = meta("seg-1", nowMs, open: true)

        #expect(
            segmentTitle(open, transcriptText: nil, liveText: "Please tell me if it's working")
                == "Please tell me if it's working"
        )
        #expect(
            segmentTitle(open, transcriptText: "Final transcript wins", liveText: "newer preview")
                == "Final transcript wins"
        )
    }

    @Test func segmentDurationPrefersSampleCounters() {
        #expect(segmentDurationMs(meta("seg-1", nowMs)) == 10_000)
    }

}

@Suite struct FormattingTest {
    @Test func durationsReadNaturally() {
        #expect(Formatting.duration(38_000) == "38 sec")
        #expect(Formatting.duration(5 * 60_000) == "5 min")
        #expect(Formatting.duration(72 * 60_000) == "1 hr 12 min")
    }

    @Test func storageSizesReadNaturally() {
        #expect(Formatting.storageSize(1_610_612_736) == "1.5 GB")
        #expect(Formatting.storageSize(320 * 1024 * 1024) == "320 MB")
        #expect(Formatting.storageSize(12_288) == "12 KB")
    }
}
