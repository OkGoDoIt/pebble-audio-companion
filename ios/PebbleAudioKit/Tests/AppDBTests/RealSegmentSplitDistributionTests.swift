import Foundation
import SegmentStore
import Testing

@testable import AppDB

// The distribution gate. `RealSegmentBoundaryTests` pins the INVARIANTS of the quiet layer
// (settled-only, deterministic, never fragmenting); this file pins the SHAPE of what the user
// actually sees, so a later change that quietly reintroduces a nine-hour "conversation" — or
// a sixteen-hour one holding thirty-two seconds of audio — fails loudly instead of shipping.
//
// Everything here was measured against a hand-labelled yardstick built by reading 93.5% of the
// library's 74,125 utterances: 95 `certain` boundaries, 55 `unsure`, and 149 deliberate
// NON-boundaries (the traps). Scored at ±3 minutes, on the 2026-09-08 backup:
//
//                                        certain   traps   median    p90    longest   >4h
//   v1 structural rules only              54/95   29/149  27m31s   4h58m   17h31m     16
//   shipped before this change            62/95   30/149  26m38s   2h54m   16h29m      9
//   + honest extent (no rule change)      62/95   30/149  14m57s   2h05m    8h59m      7
//   + flanking-flow guard                 62/95   29/149  14m57s   2h11m    8h59m      7
//   + quietSplitMs 25 min -> 15 min       67/95   34/149  14m54s   2h03m    7h38m      4
//
// The two failure shapes the labels insist on scoring separately behave very differently:
//   (a) SILENCE-PADDED (a few minutes of speech with hours of silent audio chained on, e.g.
//       2026-09-06: a 17.5-hour span holding 58 minutes of speech). Already 5 of 6 certain
//       boundaries before this change — what was broken there was the DURATION, not the
//       splitting, and the honest extent is what fixes it.
//   (b) GENUINELY DENSE (2026-08-15 is 84% speech over 9.1 hours). 1 of 8 certain boundaries
//       before, 4 of 8 after, at a cost of 2 traps out of 34. This is the hard half and it
//       stays hard: the true boundaries there are scene changes with no usable silence.
//
// The longest survivor, 7h38m, is not a bug: it is one long social evening that the label file
// records as ONE episode, with its internal activity shifts (one activity -> a second ->
// a third) recorded as zero-gap traps.

/// Deliberately its own variable rather than `PEBBLE_SEGMENT_BACKUP`: the numbers below are a
/// measured distribution over ONE corpus, so pointing this suite at a different snapshot would
/// not test a regression, it would test a different library. `RealSegmentBoundaryTests` pins
/// invariants and can run anywhere; this one pins a shape and names its corpus.
private let splitBackupPath =
    ProcessInfo.processInfo.environment["PEBBLE_SPLIT_BACKUP"]
    ?? NSHomeDirectory()
        + "/Desktop/PebbleAudioBackup/audio-companion-20260908-164136/segments"

private var splitTranscriptsPath: String {
    URL(fileURLWithPath: splitBackupPath)
        .deletingLastPathComponent()
        .appendingPathComponent("transcription/transcripts").path
}

private var splitBackupAvailable: Bool {
    FileManager.default.fileExists(atPath: splitBackupPath, isDirectory: nil)
        && FileManager.default.fileExists(atPath: splitTranscriptsPath, isDirectory: nil)
}

/// The durable transcript sidecar, with the text — the word counts feed the flanking-flow
/// guard, which is inert without them.
private struct SplitBackupTranscript: Decodable {
    struct Turn: Decodable {
        var startMs: Int64
        var endMs: Int64
        var text: String?
    }
    var segments: [Turn]?
}

private func loadSplitMetas() throws -> [SegmentMeta] {
    let decoder = JSONDecoder()
    return try FileManager.default
        .contentsOfDirectory(
            at: URL(fileURLWithPath: splitBackupPath), includingPropertiesForKeys: nil
        )
        .filter { $0.lastPathComponent.hasSuffix(".meta.json") }
        .map { try decoder.decode(SegmentMeta.self, from: Data(contentsOf: $0)) }
}

private func loadSplitEvidence(_ metas: [SegmentMeta]) -> [String: SegmentSpeechEvidence] {
    let decoder = JSONDecoder()
    var out: [String: SegmentSpeechEvidence] = [:]
    for meta in metas {
        let url = URL(fileURLWithPath: splitTranscriptsPath)
            .appendingPathComponent("\(meta.segmentId).transcript.json")
        let speech: [SpeechSpan]? = (try? Data(contentsOf: url))
            .flatMap { try? decoder.decode(SplitBackupTranscript.self, from: $0) }
            .map {
                ($0.segments ?? []).map { turn in
                    SpeechSpan(
                        startMs: turn.startMs, endMs: turn.endMs,
                        wordCount: (turn.text ?? "").split(whereSeparator: \.isWhitespace).count)
                }
            }
        out[meta.segmentId] = SegmentSpeechEvidence.of(meta, transcriptSpeech: speech)
    }
    return out
}

private func spokenWords(
    _ conversation: GroupedConversation, metas: [String: SegmentMeta],
    evidence: [String: SegmentSpeechEvidence]
) -> Int {
    conversation.memberSegmentIds.reduce(0) { total, id in
        total + (evidence[id]?.speech.reduce(0) { $0 + $1.wordCount } ?? 0)
    }
}

@Suite struct RealSegmentSplitDistributionTests {

    private func grouped(_ policy: BoundaryPolicy = .default) throws -> (
        metas: [String: SegmentMeta], evidence: [String: SegmentSpeechEvidence],
        conversations: [GroupedConversation]
    ) {
        let metas = try loadSplitMetas()
        let evidence = loadSplitEvidence(metas)
        return (
            Dictionary(uniqueKeysWithValues: metas.map { ($0.segmentId, $0) }),
            evidence,
            ConversationGrouper.group(
                segments: metas, pauses: [], openSegmentId: nil, fallbackTimeZoneID: "UTC",
                evidence: evidence, policy: policy)
        )
    }

    /// THE headline: no conversation the user can open is a phantom, and the monsters are gone.
    @Test(.enabled(if: splitBackupAvailable))
    func theDisplayedLengthsAreHonestAndTheMonstersAreGone() throws {
        let (metas, evidence, conversations) = try grouped()
        let spans = conversations.map { $0.endMs - $0.startMs }.sorted()

        // Before this change the longest row in the library was 16 h 29 m and held 32 seconds
        // of audio; the longest with any speech in it was 9 h 06 m. Measured after: 7 h 38 m.
        #expect(spans.last ?? 0 < 8 * 3_600_000)
        // Nine conversations exceeded four hours; measured after: four, and every one of them
        // is a real occasion read end to end by hand.
        #expect(spans.filter { $0 > 4 * 3_600_000 }.count <= 5)
        // p90 was 2 h 54 m; measured after: 2 h 03 m.
        #expect(spans[Int(Double(spans.count) * 0.9)] < 2 * 3_600_000 + 30 * 60_000)

        // The phantom test proper: a row with nothing said in it can never be long, because its
        // extent is now the audio actually received. The worst case in this library was a
        // single segment displaying 16 h 29 m for 1,634 frames of audio.
        //
        // "Nothing said" means no speech RUNS, which is not the same as no words: 1.2% of the
        // library's turns carry timings and empty text (the recogniser heard voice and produced
        // no transcript for it). Those are evidence of when someone spoke, so they anchor the
        // extent like any other run — this branch is for the members that produced no timing at
        // all, where the only honest length left is the audio we hold.
        for conversation in conversations {
            let members = conversation.memberSegmentIds.compactMap { metas[$0] }
            let silent = members.allSatisfy {
                ConversationBoundaryDetector.spokenRuns($0, evidence[$0.segmentId]).isEmpty
            }
            guard silent, members.allSatisfy({ evidence[$0.segmentId]?.isSettled == true })
            else { continue }
            let audio = members.reduce(Int64(0)) { $0 + ConversationGrouper.segmentAudioMs($1) }
            #expect(conversation.endMs - conversation.startMs <= audio)
            #expect(spokenWords(conversation, metas: metas, evidence: evidence) == 0)
        }
    }

    /// The extent may only ever SHRINK the container, and only onto real speech. This is what
    /// stops a "fix" that shortens a conversation past the words it contains.
    @Test(.enabled(if: splitBackupAvailable))
    func everyExtentSitsInsideItsContainerAndCoversEverySpokenWord() throws {
        let (metas, evidence, conversations) = try grouped()
        for conversation in conversations {
            let members = conversation.memberSegmentIds.compactMap { metas[$0] }
            guard let first = members.first else { continue }
            let containerStart = ConversationGrouper.segmentStartMs(first)
            let containerEnd = members.map(ConversationGrouper.segmentEndMs).max() ?? containerStart
            #expect(conversation.startMs >= containerStart)
            #expect(conversation.endMs <= max(containerEnd, containerStart))
            #expect(conversation.endMs >= conversation.startMs)

            // Every word that was said is inside the extent — the trim only ever eats silence.
            let allSettled = members.allSatisfy { evidence[$0.segmentId]?.isSettled == true }
            guard allSettled else { continue }
            for meta in members {
                for run in ConversationBoundaryDetector.spokenRuns(meta, evidence[meta.segmentId]) {
                    #expect(run.startMs >= conversation.startMs)
                    #expect(run.endMs <= conversation.endMs)
                }
            }
        }
    }

    /// The extent is a display correction, not a semantic one: it must not move a single
    /// boundary. This is why it could ship on its own, and why it is tested on its own.
    @Test(.enabled(if: splitBackupAvailable))
    func theHonestExtentChangesNoMembership() throws {
        let metas = try loadSplitMetas()
        let evidence = loadSplitEvidence(metas)
        let withEvidence = ConversationGrouper.group(
            segments: metas, pauses: [], openSegmentId: nil, fallbackTimeZoneID: "UTC",
            evidence: evidence, policy: .structuralOnly)
        let withoutEvidence = ConversationGrouper.group(
            segments: metas, pauses: [], openSegmentId: nil, fallbackTimeZoneID: "UTC",
            policy: .structuralOnly)
        #expect(withEvidence.map(\.memberSegmentIds) == withoutEvidence.map(\.memberSegmentIds))
        // …and it really does shorten things: without evidence there is nothing to anchor on,
        // so those extents are the old container edges.
        let anchored = withEvidence.reduce(Int64(0)) { $0 + ($1.endMs - $1.startMs) }
        let containers = withoutEvidence.reduce(Int64(0)) { $0 + ($1.endMs - $1.startMs) }
        #expect(anchored < containers)
    }

    /// The flanking-flow guard earns its place: it refuses cuts, never invents them, and the
    /// refused ones are still offered to the reviewer rather than dropped on the floor.
    @Test(.enabled(if: splitBackupAvailable))
    func theFlankingFlowGuardOnlyEverWithholdsASplit() throws {
        let metas = try loadSplitMetas()
        let evidence = loadSplitEvidence(metas)
        func run(_ policy: BoundaryPolicy) -> (conversations: [GroupedConversation],
            candidates: [BoundaryCandidate])
        {
            ConversationGrouper.groupWithCandidates(
                segments: metas, pauses: [], openSegmentId: nil, fallbackTimeZoneID: "UTC",
                evidence: evidence, policy: policy)
        }
        let guarded = run(.default)
        let unguarded = run(
            BoundaryPolicy(
                quietSplitMs: BoundaryPolicy.default.quietSplitMs,
                quietCandidateMs: BoundaryPolicy.default.quietCandidateMs,
                flankFlowWordsPerMinute: 0))
        #expect(guarded.conversations.count < unguarded.conversations.count)
        // A withheld split becomes a candidate: the evidence is not thrown away, it is handed
        // to the layer that can read what was actually said.
        #expect(guarded.candidates.count > unguarded.candidates.count)
        // And it is a pure refusal — the guarded grouping is a strict merge of the unguarded
        // one, never a different set of cuts.
        let unguardedStarts = Set(unguarded.conversations.compactMap(\.memberSegmentIds.first))
        let guardedStarts = Set(guarded.conversations.compactMap(\.memberSegmentIds.first))
        #expect(guardedStarts.isSubset(of: unguardedStarts))
    }

    /// Word counts are optional evidence: without them the guard is inert, and nothing else
    /// changes. A caller that cannot supply them must still get a sane grouping.
    @Test(.enabled(if: splitBackupAvailable))
    func withoutWordCountsTheGroupingIsTheUnguardedOne() throws {
        let metas = try loadSplitMetas()
        let evidence = loadSplitEvidence(metas)
        let countless = evidence.mapValues { known in
            SegmentSpeechEvidence(
                segmentId: known.segmentId, isSettled: known.isSettled,
                speech: known.speech.map { SpeechSpan(startMs: $0.startMs, endMs: $0.endMs) })
        }
        let withCounts = ConversationGrouper.group(
            segments: metas, pauses: [], openSegmentId: nil, fallbackTimeZoneID: "UTC",
            evidence: countless, policy: .default)
        let unguarded = ConversationGrouper.group(
            segments: metas, pauses: [], openSegmentId: nil, fallbackTimeZoneID: "UTC",
            evidence: countless,
            policy: BoundaryPolicy(flankFlowWordsPerMinute: 0))
        #expect(withCounts.map(\.memberSegmentIds) == unguarded.map(\.memberSegmentIds))
    }
}
