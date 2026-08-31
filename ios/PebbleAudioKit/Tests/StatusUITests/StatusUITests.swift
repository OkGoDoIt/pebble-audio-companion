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
        // Inside the segment's own 500-frame extent, and ahead of the silence gap so no single
        // silence record covers it. (It used to sit at sequence 6_000 — hours past the end of a
        // 10 s segment — which now clips to nothing, and never described a real recording.)
        let realSkip = GapMeta(
            firstMissingSequence: 10,
            missingFrameCount: 50,
            firstMissingSampleIndex: 10 * 320,
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
                    firstMissingSequence: 0,
                    missingFrameCount: 10_000_000,
                    firstMissingSampleIndex: 0,
                    origin: GapMeta.originSequenceSkip
                ),
            ]
        )

        #expect(displayGapMs(withHugeGap) == 10_000)
    }

    @Test func outageAfterTheLastFrameIsNotChargedToTheRecording() {
        // Field case (G17, 2026-08-31 1:54 PM row). The watch's liveness watchdog stopped capture
        // when the phone went away, and on revival ~3 h 45 min of "no audio exists" was recorded
        // as ONE TransportReset gap starting one sequence past the segment's last frame. Counting
        // it whole made totalGapMs 230 min against an 18 min recording, which displayGapMs then
        // clamped to the full duration — the row read "18 min · 18 min missing" for a recording
        // with 14 min of playable audio on disk. Only the loss inside the segment counts.
        let insideLoss = GapMeta(
            firstMissingSequence: 100,
            missingFrameCount: 50, // 1 s, inside the 10 s extent
            firstMissingSampleIndex: 100 * 320,
            origin: GapMeta.originWatch,
            reasonRaw: Int(GapReason.spoolOverflow.rawValue)
        )
        let outageAfterTheEnd = GapMeta(
            firstMissingSequence: 500, // == lastSequence + 1: entirely past the audio
            missingFrameCount: 675_300, // 3 h 45 min
            firstMissingSampleIndex: 500 * 320, // == lastSampleIndexExclusive
            origin: GapMeta.originWatch,
            reasonRaw: Int(GapReason.transportReset.rawValue)
        )
        let segment = meta("seg-outage", nowMs, gaps: [insideLoss, outageAfterTheEnd])

        #expect(totalGapMs(segment) == 1_000)
        #expect(displayGapMs(segment) == 1_000)
        // The record itself is untouched — diagnostics still see the whole outage.
        #expect(visibleLossGaps(segment).count == 2)
        #expect(gapDurationMs(outageAfterTheEnd, frameDurationMs: 20) == 13_506_000)
    }

    @Test func aGapStraddlingTheEndCountsOnlyItsRecordedPart() {
        // A gap that begins inside the audio and runs past it (the link died mid-recording and the
        // watch kept accruing pause time) contributes exactly the part that overlaps.
        let straddling = GapMeta(
            firstMissingSequence: 400, // 100 frames left in the 500-frame extent
            missingFrameCount: 100_000,
            firstMissingSampleIndex: 400 * 320,
            origin: GapMeta.originWatch,
            reasonRaw: Int(GapReason.transportReset.rawValue)
        )
        #expect(totalGapMs(meta("seg-straddle", nowMs, gaps: [straddling])) == 2_000)
    }

    @Test func aGapBeforeTheFirstFrameIsNotChargedToTheRecording() {
        // Leading gaps describe the hole before this recording began, not a hole in it.
        let leading = GapMeta(
            firstMissingSequence: 0,
            missingFrameCount: 50,
            firstMissingSampleIndex: 0,
            origin: GapMeta.originSequenceSkip
        )
        var segment = meta("seg-leading", nowMs, gaps: [leading])
        segment.firstSampleIndex = 100 * 320 // audio starts at frame 100
        #expect(totalGapMs(segment) == 0)
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

// The refusal taxonomy (`WatchLinkFault`). Tested the way `StatusUiTest` tests its copy layer,
// because it IS that layer: the same invariants apply — no protocol vocabulary in what a person
// reads, no raw code or platform text, and something to do for every failure they can act on.
@Suite struct WatchLinkFaultTest {

    private func info(min: Int, max: Int, state: UInt8 = 1) -> InfoSnapshot {
        InfoSnapshot(
            infoVersion: 1,
            protocolMin: min,
            protocolMax: max,
            serviceStateRaw: state,
            codecBitmap: 1,
            flags: 0
        )
    }

    @Test func deniedMismatchIsTheForgetReceiverCase() {
        // The one that matters in practice: the watch is bound to a DIFFERENT receiver, and only
        // the watch can let go. The approved onboarding wording is reused, not rewritten.
        let fault = WatchLinkFault.from(authStatusRaw: Int(AuthStatus.deniedMismatch.rawValue))
        #expect(fault == .boundToAnotherPhone)
        #expect(fault?.headline == StatusCopy.boundElsewhere)
        #expect(fault?.detail.contains("Forget Receiver") == true)
        #expect(fault?.needsWatchAction == true)

        // A watch that bound someone else in our place is the same situation and the same fix.
        #expect(
            WatchLinkFault.from(revokeReasonRaw: Int(RevokeReason.replaced.rawValue))
                == .boundToAnotherPhone
        )
    }

    @Test func everyWireRefusalCodeIsClassified() {
        // AUTH_RESULT: success and "ask the person" are not refusals; the rest are.
        #expect(WatchLinkFault.from(authStatusRaw: Int(AuthStatus.ok.rawValue)) == nil)
        #expect(
            WatchLinkFault.from(authStatusRaw: Int(AuthStatus.pendingUserConsent.rawValue)) == nil)
        #expect(
            WatchLinkFault.from(authStatusRaw: Int(AuthStatus.deniedDisabled.rawValue))
                == .captureOffOnWatch
        )
        #expect(
            WatchLinkFault.from(authStatusRaw: Int(AuthStatus.invalid.rawValue)) == .watchTrouble)
        // Firmware newer than this build may add codes; the honest answer is "unknown".
        #expect(WatchLinkFault.from(authStatusRaw: 99) == .unknown)

        // REVOKED.
        #expect(
            WatchLinkFault.from(revokeReasonRaw: Int(RevokeReason.userOnWatch.rawValue))
                == .authorizationRemoved
        )
        #expect(
            WatchLinkFault.from(revokeReasonRaw: Int(RevokeReason.appRequested.rawValue))
                == .releasedByThisPhone
        )
        #expect(WatchLinkFault.from(revokeReasonRaw: 0) == .unknown)

        // ERROR.
        for code in ProtocolErrorCode.allCases {
            let fault = WatchLinkFault.from(
                protocolError: ErrorMessage(errorCodeRaw: code.rawValue, detail: 0))
            #expect(fault != .unknown, "code \(code) must classify to something better")
        }
        #expect(
            WatchLinkFault.from(protocolError: ErrorMessage(errorCodeRaw: 200, detail: 0))
                == .unknown
        )
        #expect(
            WatchLinkFault.from(
                protocolError: ErrorMessage(
                    errorCodeRaw: ProtocolErrorCode.unauthorized.rawValue, detail: 0))
                == .authorizationRemoved
        )
    }

    @Test func versionNegotiationNamesTheSideThatIsBehind() {
        #expect(WatchLinkFault.versionFault(info: info(min: 2, max: 3), protoVersion: 1)
            == .appTooOldForWatch)
        #expect(WatchLinkFault.versionFault(info: info(min: 1, max: 1), protoVersion: 2)
            == .watchFirmwareTooOld)
        #expect(WatchLinkFault.versionFault(info: info(min: 1, max: 3), protoVersion: 2) == nil)
        #expect(WatchLinkFault.versionFault(info: nil, protoVersion: 1) == nil)

        // UNSUPPORTED_VERSION with an Info read in hand says which side; without one it admits
        // it does not know rather than guessing at the user's expense.
        let error = ErrorMessage(
            errorCodeRaw: ProtocolErrorCode.unsupportedVersion.rawValue, detail: 0)
        #expect(
            WatchLinkFault.from(protocolError: error, info: info(min: 2, max: 4), protoVersion: 1)
                == .appTooOldForWatch
        )
        #expect(WatchLinkFault.from(protocolError: error) == .versionMismatch)
    }

    @Test func deAuthorizedReceiverStopsSayingConnecting() {
        // The whole point: the session never reaches `.denied` when the watch answers with ERROR
        // and drops the link, so every pass through connect → authorize → resync is a legitimate
        // `.connecting`. Without the fault the card says "Connecting…" forever.
        let error = ErrorMessage(
            errorCodeRaw: ProtocolErrorCode.unauthorized.rawValue, detail: 0)
        let fault = WatchLinkFault.classify(state: .connecting, protocolError: error)
        #expect(fault == .authorizationRemoved)

        let bare = statusModel(state: .connecting, intent: .active)
        #expect(bare.headline == StatusCopy.connecting)

        let explained = statusModel(state: .connecting, intent: .active, linkFault: fault)
        #expect(explained.family == .needsAttention)
        #expect(explained.headline != StatusCopy.connecting)
        #expect(explained.headline == StatusCopy.linkAuthorizationRemoved)
        #expect(explained.action != nil)

        // It survives the loop: the same fault explains the disconnected and failed passes too.
        for state: ReceiverSessionState in [
            .disconnected, .authorizing, .connectionFailed(kind: .unknown, detail: "raw"),
        ] {
            let status = statusModel(state: state, intent: .active, linkFault: fault)
            #expect(status.headline == StatusCopy.linkAuthorizationRemoved, "\(state)")
        }
    }

    @Test func aWorkingLinkAndAWaitingPromptHaveNoFault() {
        let error = ErrorMessage(
            errorCodeRaw: ProtocolErrorCode.unauthorized.rawValue, detail: 0)
        // A stale error from a previous connection must not haunt a working one.
        #expect(WatchLinkFault.classify(state: .authorized, protocolError: error) == nil)
        #expect(
            WatchLinkFault.classify(state: .streaming(streamId: 4), protocolError: error) == nil)
        // The watch is asking the person: progress, not a refusal.
        #expect(WatchLinkFault.classify(state: .pendingConsent, protocolError: error) == nil)
        #expect(WatchLinkFault.classify(state: .pendingEnable, protocolError: error) == nil)

        // And even if a caller passes one, the prompt on the wrist is what the card says.
        let pending = statusModel(
            state: .pendingConsent, intent: .active, linkFault: .authorizationRemoved)
        #expect(pending.family == .confirmOnWatch)

        // Nothing to explain when the watch never complained.
        #expect(WatchLinkFault.classify(state: .connecting) == nil)
        // The watch's own error state is a fault even with no ERROR message on the wire.
        #expect(
            WatchLinkFault.classify(
                state: .connecting,
                watchServiceStateRaw: Int(ServiceState.error.rawValue)) == .watchTrouble
        )
    }

    @Test func aRefusalIsNotShoutedAtSomeoneWhoTurnedCaptureOff() {
        let status = statusModel(
            state: .disconnected, intent: .off, linkFault: .boundToAnotherPhone)
        #expect(status.family == .notRecording)
        #expect(status.headline == StatusCopy.notRecording)
    }

    @Test func everyFaultSpeaksPlainlyAndOffersSomethingToDo() {
        // Same invariants the connection-failure test pins, over the refusal vocabulary.
        let banned = [
            "GATT", "AUTH", "checkpoint", "spool", "sequence", "stream id", "NimBLE",
            "protocol", "characteristic", "0x", "receiver id", "notification",
        ]
        for fault in WatchLinkFault.allCases {
            let text = fault.headline + " " + fault.detail + " " + fault.shortReason
            #expect(isNotBlank(fault.headline), "\(fault) needs a headline")
            #expect(isNotBlank(fault.detail), "\(fault) needs a sentence")
            #expect(isNotBlank(fault.shortReason), "\(fault) needs a short verdict")
            for word in banned {
                #expect(!text.contains(word), "\(fault) copy must not mention '\(word)': \(text)")
            }
            // No raw code, status number or byte count ever reaches a person (B20).
            let hasDigit = text.contains { $0.isNumber }
            #expect(!hasDigit, "\(fault) copy must not carry a raw number: \(text)")
            // Every failure has a next move — the ones only the watch can fix name the watch,
            // and the ones that are ours point at the support report.
            #expect(fault.action != nil, "\(fault) must offer an action")
            if fault.needsWatchAction {
                #expect(
                    fault.detail.range(of: "watch", options: .caseInsensitive) != nil
                        || fault.detail.contains("Pebble"),
                    "\(fault) is only fixable on the watch and must say so: \(fault.detail)"
                )
            }
            // And the card it produces is a complete card.
            let model = fault.statusModel
            #expect(model.detail == fault.detail)
            #expect(model.action == fault.action)
            #expect(isNotBlank(fault.diagnosticLine))
        }
    }

    @Test func rawCodesLiveOnlyInTheDiagnosticTrace() {
        let error = ErrorMessage(
            errorCodeRaw: ProtocolErrorCode.unsupportedVersion.rawValue, detail: 77)
        let trace = watchLinkFaultTrace(
            protocolError: error, info: info(min: 2, max: 4), protoVersion: 1)
        #expect(trace?.contains("77") == true)
        #expect(trace?.contains("2–4") == true)

        // ... and never in what the card shows for the same failure.
        let fault = WatchLinkFault.from(
            protocolError: error, info: info(min: 2, max: 4), protoVersion: 1)
        #expect(fault == .appTooOldForWatch)
        #expect(!fault.headline.contains("77"))
        #expect(!fault.detail.contains("77"))

        #expect(watchLinkFaultTrace(protocolError: nil, info: nil) == nil)
    }
}
