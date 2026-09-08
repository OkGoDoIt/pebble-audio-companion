import Foundation
import GRDB
import SegmentStore
import Testing
import WireProtocol

@testable import AppDB

// The quiet layer (see `ConversationBoundaries.swift`). Every case here is a shape that
// actually occurs in the captured library, and the deferral cases are the ones that decide
// whether this feature is safe: a boundary must never be decided from evidence that has not
// landed yet.

private let hour = minutesMs(60)

/// A member with a transcript: `speech` in minutes-from-the-member's-start pairs.
private func settled(
    _ id: String, _ speech: [(Int64, Int64)]
) -> SegmentSpeechEvidence {
    SegmentSpeechEvidence(
        segmentId: id, isSettled: true,
        speech: speech.map { SpeechSpan(startMs: minutesMs($0.0), endMs: minutesMs($0.1)) })
}

private func evidenceMap(_ items: [SegmentSpeechEvidence]) -> [String: SegmentSpeechEvidence] {
    Dictionary(uniqueKeysWithValues: items.map { ($0.segmentId, $0) })
}

@Suite struct ConversationBoundaryTests {
    let t0 = testEpochMs

    /// Three abutting 20-minute rotations — the commonest shape in the library, where the
    /// 5-minute chain window can never fire because the members touch.
    private func rotations(_ count: Int, minutesEach: UInt64 = 20, stream: UInt32 = 7)
        -> [SegmentMeta]
    {
        (0..<count).map { index in
            makeSegment(
                id: "s\(index)", stream: stream, startTimeMs: t0,
                firstSample: minutesSamples(UInt64(index) * minutesEach),
                durationSamples: minutesSamples(minutesEach))
        }
    }

    private func group(
        _ segments: [SegmentMeta],
        evidence: [String: SegmentSpeechEvidence] = [:],
        overrides: [String: BoundaryDecision] = [:],
        policy: BoundaryPolicy = .default,
        semanticSplits: Set<String> = [],
        open: String? = nil
    ) -> (conversations: [GroupedConversation], candidates: [BoundaryCandidate]) {
        ConversationGrouper.groupWithCandidates(
            segments: segments, pauses: [], openSegmentId: open, fallbackTimeZoneID: "UTC",
            evidence: evidence, overrides: overrides, policy: policy,
            semanticSplits: semanticSplits)
    }

    // MARK: - the quiet layer itself

    @Test func continuousTalkAcrossRotationsIsOneConversation() {
        // No stretch of no-speech anywhere: the members abut and everyone keeps talking.
        let segments = rotations(3)
        let evidence = evidenceMap([
            settled("s0", [(0, 20)]), settled("s1", [(0, 20)]), settled("s2", [(0, 20)]),
        ])
        #expect(group(segments, evidence: evidence).conversations.count == 1)
    }

    @Test func aLongSettledStretchWithNoSpeechEndsTheConversation() {
        // Talk, then 40 minutes in which nobody says anything, then talk again. The v1 rules
        // see three abutting rotations and one conversation; this is the case the whole layer
        // exists for.
        let segments = rotations(4)
        let evidence = evidenceMap([
            settled("s0", [(0, 18)]),
            settled("s1", []),
            settled("s2", []),
            settled("s3", [(18, 20)]),
        ])
        let result = group(segments, evidence: evidence)
        #expect(result.conversations.map(\.memberSegmentIds) == [["s0", "s1"], ["s2", "s3"]])
        #expect(result.conversations[1].startReason == .quiet)
        #expect(result.candidates.isEmpty)
    }

    @Test func quietUnderTheHardThresholdOnlyProducesACandidate() {
        // 20 minutes of nothing. Measured over Roger's library, stretches in the 8–25 minute
        // band are a real boundary about half the time — so the default is to leave it alone
        // and offer it to the reviewer.
        let segments = rotations(3, minutesEach: 10)
        let evidence = evidenceMap([
            settled("s0", [(0, 5)]), settled("s1", []), settled("s2", [(5, 10)]),
        ])
        let result = group(segments, evidence: evidence)
        #expect(result.conversations.count == 1)
        #expect(result.candidates.count == 1)
        #expect(result.candidates[0].newStartSegmentId == "s1")
        #expect(result.candidates[0].quietMs == minutesMs(20))
        #expect(result.candidates[0].lossFraction == 0)

        // The reviewer confirming that candidate is what splits it, and it is labelled as such.
        let confirmed = group(segments, evidence: evidence, semanticSplits: ["s1"])
        #expect(confirmed.conversations.map(\.memberSegmentIds) == [["s0"], ["s1", "s2"]])
        #expect(confirmed.conversations[1].startReason == .topicChange)
        // A verdict for a join that was never a candidate does nothing: the semantic layer can
        // only confirm boundaries the structure already proposed.
        #expect(group(segments, evidence: evidence, semanticSplits: ["s2"]).conversations.count == 1)
    }

    @Test func quietShorterThanTheCandidateFloorIsNotEvenOffered() {
        let segments = rotations(3, minutesEach: 3)
        let evidence = evidenceMap([
            settled("s0", [(0, 3)]), settled("s1", []), settled("s2", [(0, 3)]),
        ])
        let result = group(segments, evidence: evidence)
        #expect(result.conversations.count == 1)
        #expect(result.candidates.isEmpty)
    }

    // MARK: - delay is not silence

    @Test func aMemberStillTranscribingDefersTheBoundaryRatherThanSplitting() {
        // THE trap: watch audio backfills hours late and transcription lags behind capture, so
        // "no transcript yet" and "nobody spoke" look identical. Deferring costs nothing —
        // grouping is derived, and the next rebuild decides with the evidence in hand.
        let segments = rotations(4)
        let pending = SegmentSpeechEvidence(segmentId: "s2", isSettled: false, speech: [])
        let evidence = evidenceMap([
            settled("s0", [(0, 18)]), settled("s1", []), pending, settled("s3", [(18, 20)]),
        ])
        let deferred = group(segments, evidence: evidence)
        #expect(deferred.conversations.count == 1)
        #expect(deferred.candidates.isEmpty)

        // Same segments, same rules, once the transcript lands and says nobody spoke.
        let landed = evidenceMap([
            settled("s0", [(0, 18)]), settled("s1", []), settled("s2", []),
            settled("s3", [(18, 20)]),
        ])
        #expect(group(segments, evidence: landed).conversations.count == 2)
    }

    @Test func settlingRuleTreatsRetryableAndMissingTranscriptsAsUnknown() {
        var meta = makeSegment(
            id: "a", stream: 1, startTimeMs: t0, durationSamples: minutesSamples(10))

        meta.transcriptionState = .noSpeech
        #expect(SegmentSpeechEvidence.of(meta, transcriptSpeech: nil).isSettled)

        meta.transcriptionState = .complete
        #expect(SegmentSpeechEvidence.of(meta, transcriptSpeech: []).isSettled)
        // Complete but the transcript file is gone: a bookkeeping bug, not proof of silence.
        #expect(!SegmentSpeechEvidence.of(meta, transcriptSpeech: nil).isSettled)

        // Both of these are retried — `.disabled` becomes eligible again the moment a provider
        // is usable — so neither may stand in for "nobody spoke".
        for state in [TranscriptionState.failed, .disabled, .pending, .running, .uploading] {
            meta.transcriptionState = state
            #expect(!SegmentSpeechEvidence.of(meta, transcriptSpeech: []).isSettled)
        }

        // Still open: never settled, whatever the state says.
        var open = makeSegment(
            id: "b", stream: 1, startTimeMs: t0, durationSamples: minutesSamples(10),
            close: nil)
        open.transcriptionState = .noSpeech
        #expect(!SegmentSpeechEvidence.of(open, transcriptSpeech: nil).isSettled)
    }

    @Test func aLateBackfillSegmentRegroupsRatherThanLeavingAWrongSplit() {
        // The spool hands over a segment that belongs in the middle of the quiet stretch, and
        // it turns out to be full of speech. Because grouping is recomputed rather than
        // patched, the split simply stops existing.
        let segments = rotations(4)
        let before = evidenceMap([
            settled("s0", [(0, 18)]), settled("s1", []), settled("s2", []),
            settled("s3", [(18, 20)]),
        ])
        #expect(group(segments, evidence: before).conversations.count == 2)

        let backfilled = evidenceMap([
            settled("s0", [(0, 18)]), settled("s1", [(0, 20)]), settled("s2", [(0, 20)]),
            settled("s3", [(18, 20)]),
        ])
        #expect(group(segments, evidence: backfilled).conversations.count == 1)
    }

    @Test func theOpenSegmentNeverSettlesSoALiveConversationIsNotSplitAtItsTail() {
        let segments = rotations(3)
        let evidence = evidenceMap([
            settled("s0", [(0, 18)]),
            settled("s1", []),
            SegmentSpeechEvidence(segmentId: "s2", isSettled: false, speech: []),
        ])
        let result = group(segments, evidence: evidence, open: "s2")
        #expect(result.conversations.count == 1)
        #expect(result.conversations[0].isLive)
    }

    // MARK: - loss is not quiet

    @Test func aStretchThatIsMostlyMissingAudioNeedsTwiceAsMuchDeadAir() {
        // 26 minutes with nothing said, 20 of them a hole in the record. Missing audio is
        // evidence of our ignorance, not that nobody spoke — and a spool backfill can still
        // fill it, which would un-split the conversation later and orphan whatever the user
        // had tagged on the second half.
        var segments = rotations(6, minutesEach: 5)
        for index in 1...4 {
            segments[index].gaps = [
                lossGap(atSample: minutesSamples(UInt64(index) * 5), minutes: 5)
            ]
        }
        let evidence = evidenceMap([
            settled("s0", [(0, 2)]), settled("s1", []), settled("s2", []), settled("s3", []),
            settled("s4", []), settled("s5", [(3, 5)]),
        ])
        // Over the 25-minute quiet bar, under the 50-minute loss-dominated one.
        #expect(group(segments, evidence: evidence).conversations.count == 1)

        var relaxed = BoundaryPolicy.default
        relaxed.lossThresholdMultiplier = 1
        let split = group(segments, evidence: evidence, policy: relaxed)
        #expect(split.conversations.count == 2)
        // …and it is called what it is. Quiet and a hole in the record are never conflated.
        #expect(split.conversations[1].startReason == .interrupted)
    }

    @Test func vadSuppressedSilenceCountsAsQuietNotAsLoss() {
        // A `silenceSuppressed` gap is audio the watch knowingly skipped. It must not push the
        // stretch into the loss-dominated band and double the threshold.
        let segments = rotations(4)
        var withSilenceGaps = segments
        withSilenceGaps[1].gaps = [silenceGap(atSample: minutesSamples(20), minutes: 19)]
        withSilenceGaps[2].gaps = [silenceGap(atSample: minutesSamples(40), minutes: 19)]
        let evidence = evidenceMap([
            settled("s0", [(0, 18)]), settled("s1", []), settled("s2", []),
            settled("s3", [(18, 20)]),
        ])
        #expect(group(withSilenceGaps, evidence: evidence).conversations.count == 2)
    }

    // MARK: - shapes that must NOT split

    @Test func quietEntirelyInsideOneMemberNeverSplits() {
        // The rules apply between segments, never within one — a conversation is a set of whole
        // segments, so there is nowhere to cut.
        let segments = [
            makeSegment(
                id: "s0", stream: 7, startTimeMs: t0, durationSamples: minutesSamples(90))
        ]
        let evidence = evidenceMap([settled("s0", [(0, 2), (85, 90)])])
        #expect(group(segments, evidence: evidence).conversations.count == 1)
    }

    @Test func aRecordingWithNoSpeechAtAllIsLeftWhole() {
        // Every join looks equally like a boundary, so none of them is one. Chopping silence
        // into more silence helps nobody.
        let segments = rotations(6)
        let evidence = evidenceMap((0..<6).map { settled("s\($0)", []) })
        let result = group(segments, evidence: evidence)
        #expect(result.conversations.count == 1)
        #expect(result.candidates.isEmpty)
    }

    @Test func withNoEvidenceAtAllTheGroupingIsExactlyWhatItWas() {
        // Transcription off, or a library that has not been transcribed yet: the quiet layer
        // contributes nothing and the v1 rules stand alone.
        let segments = rotations(6)
        #expect(group(segments).conversations.count == 1)
        #expect(group(segments, policy: .structuralOnly).conversations.count == 1)
    }

    // MARK: - trimming dead air off the ends

    @Test func silenceBeforeTheFirstWordIsPeeledOffTheFront() {
        // The 17 h 31 m row in Roger's library: a 16-hour silent segment handed straight over
        // to an hour of real conversation. Splitting at the midpoint of that silence would
        // still leave both halves absurd; the cut belongs next to the speech.
        let segments = rotations(4)
        let evidence = evidenceMap([
            settled("s0", []), settled("s1", []), settled("s2", []), settled("s3", [(0, 20)]),
        ])
        let result = group(segments, evidence: evidence)
        #expect(result.conversations.map(\.memberSegmentIds) == [["s0", "s1", "s2"], ["s3"]])
        #expect(result.conversations[1].startReason == .quiet)
    }

    @Test func silenceAfterTheLastWordIsPeeledOffTheBack() {
        let segments = rotations(4)
        let evidence = evidenceMap([
            settled("s0", [(0, 20)]), settled("s1", []), settled("s2", []), settled("s3", []),
        ])
        #expect(
            group(segments, evidence: evidence).conversations.map(\.memberSegmentIds)
                == [["s0"], ["s1", "s2", "s3"]])
    }

    // MARK: - the user always wins

    @Test func joinOverrideUndoesAUserStopSplit() {
        // "A manual stop is a strong signal, but not an absolute one." Rather than guessing
        // when a stop-then-resume was really one conversation, the app splits — which is what
        // Stop plainly means — and one tap puts it back, durably.
        let a = makeSegment(
            id: "a", stream: 1, startTimeMs: t0, durationSamples: minutesSamples(10),
            close: userStopClose)
        let b = makeSegment(
            id: "b", stream: 2, startTimeMs: t0 + minutesMs(11),
            durationSamples: minutesSamples(4))
        #expect(group([a, b]).conversations.count == 2)
        #expect(group([a, b]).conversations[1].startReason == .userStop)

        let rejoined = group([a, b], overrides: ["b": .join])
        #expect(rejoined.conversations.map(\.memberSegmentIds) == [["a", "b"]])
    }

    @Test func joinOverrideAlsoDefeatsALongGapAndAnAutomaticQuietSplit() {
        // The override is the user's own answer, so it beats every rule in both directions.
        let a = makeSegment(
            id: "a", stream: 1, startTimeMs: t0, durationSamples: minutesSamples(10))
        let b = makeSegment(
            id: "b", stream: 2, startTimeMs: t0 + hour, durationSamples: minutesSamples(4))
        #expect(group([a, b]).conversations.count == 2)
        #expect(group([a, b], overrides: ["b": .join]).conversations.count == 1)

        let segments = rotations(4)
        let evidence = evidenceMap([
            settled("s0", [(0, 18)]), settled("s1", []), settled("s2", []),
            settled("s3", [(18, 20)]),
        ])
        #expect(group(segments, evidence: evidence).conversations.count == 2)
        #expect(
            group(segments, evidence: evidence, overrides: ["s2": .join]).conversations.count == 1)
    }

    @Test func splitOverrideCutsWhereNothingElseWould() {
        let segments = rotations(3)
        let evidence = evidenceMap([
            settled("s0", [(0, 20)]), settled("s1", [(0, 20)]), settled("s2", [(0, 20)]),
        ])
        let result = group(segments, evidence: evidence, overrides: ["s1": .split])
        #expect(result.conversations.map(\.memberSegmentIds) == [["s0"], ["s1", "s2"]])
        #expect(result.conversations[1].startReason == .manual)
    }

    // MARK: - persistence and id stability

    @Test func startReasonRoundTripsThroughTheDatabase() async throws {
        let db = try AppDatabase.inMemory()
        let segments = rotations(4)
        let evidence = evidenceMap([
            settled("s0", [(0, 18)]), settled("s1", []), settled("s2", []),
            settled("s3", [(18, 20)]),
        ])
        let first = try await ConversationGrouper.rebuild(
            segments: segments, pauses: [], openSegmentId: nil, fallbackTimeZoneID: "UTC",
            evidence: evidence, db: db)
        #expect(first.map(\.startReason) == [nil, .quiet])

        let persisted = try await db.reader.read { try ConversationGrouper.fetchAll($0) }
        #expect(persisted == first)

        // Same input twice ⇒ same ids, same reasons, same rows.
        let second = try await ConversationGrouper.rebuild(
            segments: segments, pauses: [], openSegmentId: nil, fallbackTimeZoneID: "UTC",
            evidence: evidence, db: db)
        #expect(second == first)
    }

    @Test func aNewSplitLeavesTheFirstHalfWithTheOriginalId() async throws {
        // Annotations, tags and follow-ups are keyed by conversation id. When a split appears
        // later (the transcript finally landed), the first half must keep what the user has
        // attached to it; only the new second half starts empty.
        let db = try AppDatabase.inMemory()
        let segments = rotations(4)
        let unsettled = evidenceMap([
            settled("s0", [(0, 18)]),
            SegmentSpeechEvidence(segmentId: "s1", isSettled: false, speech: []),
            SegmentSpeechEvidence(segmentId: "s2", isSettled: false, speech: []),
            settled("s3", [(18, 20)]),
        ])
        let before = try await ConversationGrouper.rebuild(
            segments: segments, pauses: [], openSegmentId: nil, fallbackTimeZoneID: "UTC",
            evidence: unsettled, db: db)
        #expect(before.map(\.id) == ["conv-s0"])

        let landed = evidenceMap([
            settled("s0", [(0, 18)]), settled("s1", []), settled("s2", []),
            settled("s3", [(18, 20)]),
        ])
        let after = try await ConversationGrouper.rebuild(
            segments: segments, pauses: [], openSegmentId: nil, fallbackTimeZoneID: "UTC",
            evidence: landed, db: db)
        #expect(after.map(\.id) == ["conv-s0", "conv-s2"])
    }

    @Test func overridesArePersistentAndReadByTheRebuild() async throws {
        let db = try AppDatabase.inMemory()
        let store = BoundaryOverrideStore(db: db)
        let a = makeSegment(
            id: "a", stream: 1, startTimeMs: t0, durationSamples: minutesSamples(10),
            close: userStopClose)
        let b = makeSegment(
            id: "b", stream: 2, startTimeMs: t0 + minutesMs(11),
            durationSamples: minutesSamples(4))

        let split = try await ConversationGrouper.rebuild(
            segments: [a, b], pauses: [], openSegmentId: nil, fallbackTimeZoneID: "UTC", db: db)
        #expect(split.count == 2)

        try await store.set(segmentId: "b", decision: .join, atMs: t0)
        #expect(try await store.decision(forSegment: "b") == .join)
        let joined = try await ConversationGrouper.rebuild(
            segments: [a, b], pauses: [], openSegmentId: nil, fallbackTimeZoneID: "UTC", db: db)
        #expect(joined.map(\.memberSegmentIds) == [["a", "b"]])

        // Clearing it hands the join back to the rules — every manual decision is undoable.
        try await store.set(segmentId: "b", decision: nil)
        let restored = try await ConversationGrouper.rebuild(
            segments: [a, b], pauses: [], openSegmentId: nil, fallbackTimeZoneID: "UTC", db: db)
        #expect(restored.count == 2)

        // Retention removed the segment: the decision goes with it.
        try await store.set(segmentId: "b", decision: .join)
        try await store.forget(segmentIds: ["b"])
        #expect(try await store.all().isEmpty)
    }

    @Test func aCachedSemanticVerdictIsAppliedByTheRebuildAndExpiresWhenTheQuietMoves() async throws {
        let db = try AppDatabase.inMemory()
        let reviews = BoundaryReviewStore(db: db)
        let segments = rotations(3, minutesEach: 10)
        let evidence = evidenceMap([
            settled("s0", [(0, 5)]), settled("s1", []), settled("s2", [(5, 10)]),
        ])
        let candidates = try await ConversationGrouper.rebuildDetailed(
            segments: segments, pauses: [], openSegmentId: nil, fallbackTimeZoneID: "UTC",
            evidence: evidence, db: db
        ).candidates
        #expect(candidates.map(\.newStartSegmentId) == ["s1"])

        try await reviews.save([
            BoundaryReview(
                segmentId: "s1", isBoundary: true, quietMs: minutesMs(20),
                reason: "different people", createdAtMs: t0)
        ])
        let split = try await ConversationGrouper.rebuild(
            segments: segments, pauses: [], openSegmentId: nil, fallbackTimeZoneID: "UTC",
            evidence: evidence, db: db)
        #expect(split.map(\.memberSegmentIds) == [["s0"], ["s1", "s2"]])
        #expect(split[1].startReason == .topicChange)

        // A verdict measured against a materially different quiet is not reused.
        try await reviews.save([
            BoundaryReview(
                segmentId: "s1", isBoundary: true, quietMs: minutesMs(90), createdAtMs: t0)
        ])
        let stale = try await ConversationGrouper.rebuild(
            segments: segments, pauses: [], openSegmentId: nil, fallbackTimeZoneID: "UTC",
            evidence: evidence, db: db)
        #expect(stale.count == 1)
    }
}
