import AppDB
import Foundation
import SegmentStore
import StatusUI
import Testing
import Transcription
import WireProtocol

@testable import Intelligence

// Stream SW: the two clock mistakes that keep coming back, pinned where Intelligence makes them.
//
// 1. `SegmentMeta.startTimeMs` anchors the STREAM — the wall clock of sample index 0 — not the
//    segment. Every reattach and every 15-minute rotation successor starts `firstSampleIndex`
//    samples later, so the raw field is the stream's birth clock. Over the 2026-09-08 backup
//    (774 segments) the two differ on 602 of them, 594 by more than a minute, by a median of
//    1 h 59 m and up to 24 h 21 m. `SegmentMeta.startWallMs` is the segment's own start.
//
// 2. A gap record routinely runs PAST the audio its segment covers: when the watch's liveness
//    watchdog trips it books the whole elapsed outage against whatever segment is still open.
//    `missingFrameCount` is therefore not this recording's loss, and counted raw it produced
//    prompt lines like "a 2 min 04 s recording, 53235700 ms missing".
//
// The fixtures here are deliberately shaped like real sidecars — a mid-stream segment has a
// non-zero `firstSampleIndex`, a `receivedAtMs` AFTER the audio it holds, and a frame count
// that agrees with its sample extent. An earlier stream was misled by a synthetic meta claiming
// `receivedAtMs: 0` (audio received in 1970), which made a wrong anchor look right; the corpus
// checks below exist so the real library gets a vote either way.

// MARK: - Physically possible fixtures

/// A segment that starts `startedSecondsIntoStream` into its stream and holds
/// `heldSeconds` of audio, with a `receivedAtMs` that could actually have happened.
private func swSegment(
    id: String,
    streamBirthMs: Int64,
    startedSecondsIntoStream: Int64,
    heldSeconds: Int64,
    gaps: [GapMeta] = [],
    receiveDelayMs: Int64 = 1_200,
    transcriptionState: TranscriptionState = .complete
) -> SegmentMeta {
    let rate: Int64 = 16_000
    let first = UInt64(startedSecondsIntoStream * rate)
    let last = UInt64((startedSecondsIntoStream + heldSeconds) * rate)
    // Gap frames are inside the wall span but hold no audio, so the frame count is the span
    // minus everything the gap records claim — which is what makes `SegmentMediaClock.isExact`
    // true, the same as a healthy sidecar.
    let gapFrames = gaps.reduce(Int64(0)) { $0 + Int64($1.missingFrameCount) }
    let frames = max(heldSeconds * 1_000 / 20 - gapFrames, 0)
    return SegmentMeta(
        segmentId: id,
        streamId: 1,
        protocolVersion: 1,
        codecIdRaw: 1,
        channels: 1,
        frameSamples: 320,
        sampleRateHz: 16_000,
        bitRateBps: 9_800,
        frameDurationMs: 20,
        startTimeMs: UInt64(streamBirthMs),
        startMonotonicMs: 1,
        receivedAtMs: streamBirthMs + (startedSecondsIntoStream + heldSeconds) * 1_000
            + receiveDelayMs,
        firstSampleIndex: first,
        lastSampleIndexExclusive: last,
        frameCount: frames,
        gaps: gaps,
        closeReason: .rotated,
        transcriptionState: transcriptionState
    )
}

private func swLossGap(
    afterSeconds: Int64, lastingSeconds: Int64, firstSampleIndex: UInt64
) -> GapMeta {
    GapMeta(
        firstMissingSequence: UInt32(afterSeconds * 50),
        missingFrameCount: UInt32(lastingSeconds * 50),
        firstMissingSampleIndex: firstSampleIndex,
        origin: GapMeta.originWatch,
        reasonRaw: Int(GapReason.transportReset.rawValue))
}

@Suite struct SWStreamAnchorTests {

    // MARK: The anchor itself

    /// The invariant every site below rests on, stated once on a sidecar that could exist.
    @Test func aMidStreamSegmentsOwnStartIsNotItsStreamsBirth() {
        let birth = Int64(1_788_193_700_000)
        let meta = swSegment(
            id: "seg-mid", streamBirthMs: birth, startedSecondsIntoStream: 3_600,
            heldSeconds: 900)
        #expect(Int64(meta.startTimeMs) == birth)
        #expect(meta.startWallMs == birth + 3_600_000)
        // And the raw field is not merely different, it is an hour wrong.
        #expect(meta.startWallMs - Int64(meta.startTimeMs) == 3_600_000)
    }

    // MARK: askGapSummary

    @Test func gapSummarySpeaksInWordsNotMilliseconds() {
        let meta = swSegment(
            id: "seg-1", streamBirthMs: 1_788_193_700_000, startedSecondsIntoStream: 0,
            heldSeconds: 900,
            gaps: [swLossGap(afterSeconds: 60, lastingSeconds: 240, firstSampleIndex: 960_000)])
        #expect(
            askGapSummary(meta)
                == "1 gap, about 4 min missing; answer may be incomplete for this segment.")
    }

    /// The watchdog shape, which is what made the old arithmetic lie. A four-hour outage is
    /// booked against the eighteen-minute recording that was open when it began; only the part
    /// that overlaps the recording is the recording's loss, and the rest belongs to the hole
    /// BETWEEN recordings, which the timeline already shows.
    @Test func aWatchdogOutageIsNotThisRecordingsWholeLoss() throws {
        let meta = swSegment(
            id: "seg-outage", streamBirthMs: 1_788_193_700_000, startedSecondsIntoStream: 0,
            heldSeconds: 1_080,
            gaps: [
                // Starts 17 min in, runs for four hours — 3 h 43 m of it past the last sample.
                swLossGap(
                    afterSeconds: 1_020, lastingSeconds: 14_400, firstSampleIndex: 16_320_000)
            ])
        let summary = try #require(askGapSummary(meta))
        // A minute of overlap, not four hours.
        #expect(summary == "1 gap, about 1 min missing; answer may be incomplete for this segment.")
        // And never more than the recording claims to be long — the property the raw form
        // violated on 34 of the backup's segments.
        #expect(displayGapMs(meta) <= displaySegmentDurationMs(meta))
    }

    /// A gap that lies entirely outside the segment's audio says nothing about this recording,
    /// so it earns no note at all (25 of the backup's segments are in this shape).
    @Test func lossWhollyOutsideTheRecordingEarnsNoNote() {
        let meta = swSegment(
            id: "seg-after", streamBirthMs: 1_788_193_700_000, startedSecondsIntoStream: 0,
            heldSeconds: 20,
            gaps: [
                swLossGap(
                    afterSeconds: 600, lastingSeconds: 12_000, firstSampleIndex: 9_600_000)
            ])
        #expect(askGapSummary(meta) == nil)
    }

    // MARK: The classifier is no longer a copy

    /// `AskGapVisibility` was a hand-maintained replica of `StatusUI.GapVisibility`; Ask now
    /// calls the real one. This pins the seam so the copy cannot come back quietly — it is the
    /// same test SearchKit's dependency on StatusUI exists to make unnecessary.
    @Test func askUsesTheOneGapClassifier() {
        let silence = GapMeta(
            firstMissingSequence: 500, missingFrameCount: 9_000,
            firstMissingSampleIndex: 160_000, origin: GapMeta.originWatch,
            reasonRaw: Int(GapReason.silenceSuppressed.rawValue))
        let coveredSkip = GapMeta(
            firstMissingSequence: 600, missingFrameCount: 50,
            firstMissingSampleIndex: 192_000, origin: GapMeta.originSequenceSkip)
        let standaloneSkip = GapMeta(
            firstMissingSequence: 20_000, missingFrameCount: 25,
            firstMissingSampleIndex: 6_400_000, origin: GapMeta.originSequenceSkip)
        let loss = swLossGap(afterSeconds: 60, lastingSeconds: 2, firstSampleIndex: 960_000)
        let meta = swSegment(
            id: "seg-mixed", streamBirthMs: 1_788_193_700_000, startedSecondsIntoStream: 0,
            heldSeconds: 900, gaps: [silence, coveredSkip, standaloneSkip, loss])
        #expect(askVisibleLossGaps(meta) == visibleLossGaps(meta))
        #expect(askVisibleLossGaps(meta) == [standaloneSkip, loss])
    }

    // MARK: Ordering and citation anchors

    @Test func enrichmentOrdersConversationsByTheirOwnStartsNotTheirStreams() {
        // `conv-fresh` is a brand-new stream. `conv-later` is a rotation successor three hours
        // into a stream that was born two hours earlier — so it really happened an hour AFTER
        // conv-fresh, while its raw `startTimeMs` reads two hours BEFORE it. This is the shape
        // the backlog is full of, and it decides which three conversations a pass spends its
        // provider calls on.
        let birth = Int64(1_788_100_000_000)
        let fresh = EnrichmentConversation(
            conversationId: "conv-fresh", isOpen: false,
            members: [
                swSegment(
                    id: "seg-fresh", streamBirthMs: birth,
                    startedSecondsIntoStream: 0, heldSeconds: 600)
            ])
        let later = EnrichmentConversation(
            conversationId: "conv-later", isOpen: false,
            members: [
                swSegment(
                    id: "seg-later", streamBirthMs: birth - 7_200_000,
                    startedSecondsIntoStream: 10_800, heldSeconds: 600)
            ])
        #expect(fresh.members[0].startTimeMs > later.members[0].startTimeMs)
        #expect(fresh.members[0].startWallMs < later.members[0].startWallMs)
        #expect(
            [fresh, later].sorted(by: EnrichmentWorker.newestFirst).map(\.conversationId)
                == ["conv-later", "conv-fresh"])
    }

    /// `recordedAtMs` on a candidate is what "tomorrow" inside the conversation is relative to,
    /// and what the follow-up row's "play the moment this came from" is anchored on. It has to
    /// be the member's own start.
    @Test func aFollowUpCandidateIsStampedWithItsOwnRecordingsStart() async throws {
        let db = try AppDatabase.inMemory()
        let candidates = FollowUpCandidateStore(db: db)
        let state = try FollowUpExtractionStore(db: db)
        let birth = Int64(1_788_100_000_000)
        let member = swSegment(
            id: "seg-mid", streamBirthMs: birth, startedSecondsIntoStream: 5_400,
            heldSeconds: 900)
        let provider = SWScriptedProvider(
            response: """
                {"items": [
                  {"task": "Take Theo to the airport at 7:00",
                   "quote": "I got to take Theo at 7:00.",
                   "ifForgotten": "Theo misses his ride", "dueDate": "",
                   "confidence": "high"}
                ]}
                """)
        let worker = FollowUpWorker(
            candidates: candidates,
            state: state,
            router: AiModeRouter(local: provider, remote: nil, mode: { .localOnly }),
            nowMs: { member.startWallMs + 60_000 },
            timeZone: { TimeZone(identifier: "America/Detroit")! })
        let text =
            String(repeating: "We talked about the week and what is left to do. ", count: 5)
            + "I got to take Theo at 7:00."
        let written = try await worker.extract(
            [
                EnrichmentConversation(
                    conversationId: "conv-1", isOpen: false, members: [member])
            ],
            transcriptOf: {
                SegmentTranscript(
                    segmentId: $0, text: text, modeUsed: .localOnly, providerId: "local",
                    createdAtMs: 0)
            })

        #expect(written == 1)
        let rows = try await candidates.list(conversationId: "conv-1")
        #expect(rows.count == 1)
        // Its own start — an hour and a half after the stream was born.
        #expect(rows.first?.recordedAtMs == member.startWallMs)
        #expect(rows.first?.recordedAtMs != Int64(member.startTimeMs))
    }

    /// A recap narrates a day in order. Sorting the day's segments on the raw `startTimeMs`
    /// orders them by when their STREAMS began, which is a different sequence entirely once a
    /// stream spans a day — the evening read out before the morning.
    @Test func aRecapReadsTheDayInTheOrderItHappened() async throws {
        // 2026-09-04, America/Detroit. `seg-morning` is a fresh stream at 09:00; `seg-evening`
        // is nine hours into a stream born at 08:00, so it happened at 17:00 while its raw
        // anchor reads 08:00 — an hour BEFORE the morning recording.
        let eightAm = Int64(1_788_609_600_000)  // 2026-09-04 08:00 America/Detroit
        let morning = swSegment(
            id: "seg-morning", streamBirthMs: eightAm + 3_600_000,
            startedSecondsIntoStream: 0, heldSeconds: 900)
        let evening = swSegment(
            id: "seg-evening", streamBirthMs: eightAm,
            startedSecondsIntoStream: 32_400, heldSeconds: 900)
        #expect(evening.startTimeMs < morning.startTimeMs)
        #expect(evening.startWallMs > morning.startWallMs)

        let db = try AppDatabase.inMemory()
        let now = evening.startWallMs + 3_600_000
        let recorder = SWRunRecorder()
        // Deliberately handed to the engine in the WRONG order, so the assertion is about the
        // sort and not about the input.
        let engine = DailyRecapEngine(
            listSegments: { [evening, morning] },
            transcriptTextOf: { $0 == "seg-morning" ? "Morning standup." : "Evening debrief." },
            store: DailyRecapStore(db: db, nowMs: { now }),
            run: { await recorder.record($0) },
            prompt: AiPromptTemplate(
                id: "daily-summary", title: "Daily Summary",
                systemPrompt: "Summarize the day.", userPrompt: "Use transcripts."),
            fallbackTimeZoneID: "America/Detroit",
            nowMs: { now })

        try await engine.refreshDigests()

        let requests = await recorder.requests
        #expect(requests.count == 1)
        #expect(requests.first?.transcripts.map(\.segmentId) == ["seg-morning", "seg-evening"])
    }
}

// MARK: - Minimal doubles (this file's own, so no other suite's harness is edited)

private final class SWScriptedProvider: AiProvider, @unchecked Sendable {
    let id = "sw-scripted"
    private let response: String

    init(response: String) { self.response = response }

    func isAvailable() async -> Bool { true }

    func run(_ request: AiRunRequest) async throws -> AiProviderResult {
        AiProviderResult(text: response, modelUsed: "sw-scripted-model")
    }
}

private actor SWRunRecorder {
    private(set) var requests: [AiRunRequest] = []

    func record(_ request: AiRunRequest) -> RoutedAiResult {
        requests.append(request)
        return RoutedAiResult(
            text: "Recap \(requests.count)", modeUsed: .localOnly, providerId: "sw-fake",
            modelUsed: "sw-fake-model", inputTokens: nil, outputTokens: nil)
    }
}

// MARK: - Against the real library

/// The corpus these numbers were measured on. Pointed at a different snapshot the assertions
/// still hold (they are invariants, not counts) — only the "the corpus exercises this" guards
/// name a size, and they are floors, not equalities.
private let swBackupPath =
    ProcessInfo.processInfo.environment["PEBBLE_SEGMENT_BACKUP"]
    ?? NSHomeDirectory()
        + "/Desktop/PebbleAudioBackup/audio-companion-20260908-184844/segments"

private var swBackupAvailable: Bool {
    FileManager.default.fileExists(atPath: swBackupPath, isDirectory: nil)
}

private func swLoadBackupMetas() throws -> [SegmentMeta] {
    let decoder = JSONDecoder()
    return try FileManager.default
        .contentsOfDirectory(
            at: URL(fileURLWithPath: swBackupPath), includingPropertiesForKeys: nil
        )
        .filter { $0.lastPathComponent.hasSuffix(".meta.json") }
        .compactMap { try? decoder.decode(SegmentMeta.self, from: Data(contentsOf: $0)) }
}

@Suite(.enabled(if: swBackupAvailable, "no PebbleAudioBackup on this machine"))
struct SWRealLibraryAnchorTests {

    /// The gap note the model reads can never claim more missing time than the recording is
    /// long. On the raw `missingFrameCount` this failed on 34 of the 774 segments — the worst
    /// by 657x, a 3 h 21 m claim on an 18 s recording.
    @Test func noGapNoteOverClaimsAgainstTheRealLibrary() throws {
        let metas = try swLoadBackupMetas()
        #expect(metas.count > 100, "the corpus should be the real library, not a stub")
        var noted = 0
        var wouldHaveOverClaimed = 0
        for meta in metas {
            let honest = displayGapMs(meta)
            let length = displaySegmentDurationMs(meta)
            let raw = askVisibleLossGaps(meta).reduce(Int64(0)) {
                $0 + Int64($1.missingFrameCount) * Int64(meta.frameDurationMs)
            }
            if length > 0, raw > length { wouldHaveOverClaimed += 1 }
            guard let summary = askGapSummary(meta) else { continue }
            noted += 1
            #expect(honest > 0, "\(meta.segmentId) got a gap note with nothing missing")
            #expect(
                length <= 0 || honest <= length,
                "\(meta.segmentId) claims \(honest) ms missing from a \(length) ms recording")
            // The words are the honest number's words, never raw milliseconds.
            let expected =
                honest < 1_000 ? "under a second" : "about \(Formatting.duration(honest))"
            #expect(summary.contains(expected), "\(meta.segmentId): \(summary)")
            #expect(!summary.contains("ms "), "\(meta.segmentId) shipped raw units: \(summary)")
        }
        #expect(noted > 0, "no segment in the corpus has visible loss — check the corpus")
        // Guard rail on the guard rail: if this ever reaches zero the corpus stopped
        // exercising the bug and the test above stopped proving anything.
        #expect(
            wouldHaveOverClaimed > 0,
            "the raw arithmetic no longer over-claims anywhere in this corpus")
    }

    /// Ask's visible-loss set is StatusUI's, segment for segment, over the whole library. This
    /// is what the deleted `AskGapVisibility` replica could not promise.
    @Test func askAndStatusUiClassifyEveryRealGapTheSameWay() throws {
        let metas = try swLoadBackupMetas()
        var withGaps = 0
        for meta in metas where !meta.gaps.isEmpty {
            withGaps += 1
            #expect(askVisibleLossGaps(meta) == visibleLossGaps(meta), "\(meta.segmentId)")
        }
        #expect(withGaps > 0)
    }

    /// The anchor error is real in this library and `startWallMs` is the one that respects the
    /// ceiling (`receivedAtMs`): audio cannot have been recorded after the phone received it.
    @Test func theRealLibraryDisagreesWithTheStreamAnchor() throws {
        let metas = try swLoadBackupMetas()
        let differing = metas.filter { $0.startWallMs != Int64($0.startTimeMs) }
        let overAMinute = differing.filter {
            abs($0.startWallMs - Int64($0.startTimeMs)) >= 60_000
        }
        #expect(differing.count > metas.count / 2)
        #expect(overAMinute.count > 100)
        for meta in metas {
            #expect(
                meta.startWallMs <= meta.receivedAtMs,
                "\(meta.segmentId) claims to have been recorded after it arrived")
        }
    }
}
