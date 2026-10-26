import Foundation
import GRDB
import SegmentStore
import Testing
import WireProtocol

@testable import AppDB

// Shared builders for AppDB tests: hand-built SegmentMeta values at 16 kHz / 320-sample
// frames, so 1 minute = 960_000 samples = 3_000 frames.

let testEpochMs: Int64 = 1_772_400_000_000

func minutesMs(_ n: Int64) -> Int64 { n * 60_000 }
func minutesSamples(_ n: UInt64) -> UInt64 { n * 960_000 }

let userStopClose = CloseReasonMeta(
    kind: CloseReasonMeta.kindStopped,
    stopReasonRaw: Int(StopReason.userDisabled.rawValue)
)

func makeSegment(
    id: String,
    stream: UInt32,
    startTimeMs: Int64,
    firstSample: UInt64 = 0,
    durationSamples: UInt64,
    close: CloseReasonMeta? = .interrupted,
    tz: String? = nil,
    gaps: [GapMeta] = []
) -> SegmentMeta {
    SegmentMeta(
        segmentId: id,
        streamId: stream,
        protocolVersion: 1,
        codecIdRaw: 1,
        channels: 1,
        frameSamples: 320,
        sampleRateHz: 16_000,
        bitRateBps: 9_800,
        frameDurationMs: 20,
        startTimeMs: UInt64(startTimeMs),
        startMonotonicMs: 0,
        receivedAtMs: startTimeMs + Int64(firstSample / 16),
        firstSequence: UInt32(firstSample / 320),
        lastSequence: UInt32((firstSample + durationSamples) / 320),
        firstSampleIndex: firstSample,
        lastSampleIndexExclusive: firstSample + durationSamples,
        frameCount: Int64(durationSamples / 320),
        gaps: gaps,
        closeReason: close,
        closedAtMs: startTimeMs + Int64((firstSample + durationSamples) / 16),
        recordedTimeZone: tz
    )
}

func lossGap(atSample sample: UInt64, minutes: UInt32, reasonRaw: Int? = 6) -> GapMeta {
    GapMeta(
        firstMissingSequence: UInt32(sample / 320),
        missingFrameCount: minutes * 3_000,
        firstMissingSampleIndex: sample,
        origin: GapMeta.originWatch,
        reasonRaw: reasonRaw
    )
}

func silenceGap(atSample sample: UInt64, minutes: UInt32) -> GapMeta {
    GapMeta(
        firstMissingSequence: UInt32(sample / 320),
        missingFrameCount: minutes * 3_000,
        firstMissingSampleIndex: sample,
        origin: GapMeta.originWatch,
        reasonRaw: Int(GapReason.silenceSuppressed.rawValue)
    )
}

func sequenceSkipGap(atSample sample: UInt64, minutes: UInt32) -> GapMeta {
    GapMeta(
        firstMissingSequence: UInt32(sample / 320),
        missingFrameCount: minutes * 3_000,
        firstMissingSampleIndex: sample,
        origin: GapMeta.originSequenceSkip
    )
}

// --- conversation-unit fixtures ----------------------------------------------------------------
//
// A conversation is an ordered list of PIECES of segments (`ConversationMember`), so the suites
// that exercise the grouper share the builders below: rotations that hand straight over (the
// commonest shape in the library), evidence with and without text, and the one invariant every
// grouping must satisfy whatever the policy — the pieces TILE the library.

/// `count` abutting rotations of one stream — `s0`, `s1`, … each `minutesEach` long — starting
/// at `startTimeMs`. The 5-minute chain window can never fire inside them because they touch.
func rotations(
    _ count: Int, minutesEach: UInt64 = 20, stream: UInt32 = 7,
    startTimeMs: Int64 = testEpochMs, prefix: String = "s"
) -> [SegmentMeta] {
    (0..<count).map { index in
        makeSegment(
            id: "\(prefix)\(index)", stream: stream, startTimeMs: startTimeMs,
            firstSample: minutesSamples(UInt64(index) * minutesEach),
            durationSamples: minutesSamples(minutesEach))
    }
}

/// A member whose transcript has landed: `minutes` are (start, end) pairs from the member's own
/// start. Timings only — no text, so the segmenter sees no features.
func settledEvidence(
    _ id: String, minutes speech: [(Int64, Int64)], words: Int = 0
) -> SegmentSpeechEvidence {
    SegmentSpeechEvidence(
        segmentId: id, isSettled: true,
        speech: speech.map {
            SpeechSpan(startMs: minutesMs($0.0), endMs: minutesMs($0.1), wordCount: words)
        })
}

/// A member whose transcript has landed, with the turns themselves.
func settledEvidence(_ id: String, turns: [SpeechSpan]) -> SegmentSpeechEvidence {
    SegmentSpeechEvidence(segmentId: id, isSettled: true, speech: turns)
}

/// A member still waiting for its transcript (or still open): nothing is known about it.
func unsettledEvidence(_ id: String) -> SegmentSpeechEvidence {
    SegmentSpeechEvidence(segmentId: id, isSettled: false, speech: [])
}

func evidenceMap(_ items: [SegmentSpeechEvidence]) -> [String: SegmentSpeechEvidence] {
    Dictionary(uniqueKeysWithValues: items.map { ($0.segmentId, $0) })
}

/// Two vocabularies with nothing in common, every word a content word to `ConversationLexicon`.
let sailingWords = [
    "harbour", "sailing", "anchor", "rigging", "keel", "mast", "tide", "jib", "rudder", "marina",
    "compass", "mooring", "spinnaker", "halyard", "buoy", "galley",
]
let cookingWords = [
    "recipe", "oven", "butter", "flour", "simmer", "garlic", "onion", "saucepan", "whisk",
    "roast", "pepper", "basil", "dough", "broth", "skillet", "paprika",
]

private func sentence(_ vocabulary: [String], _ index: Int, words: Int = 6) -> String {
    (0..<words).map { vocabulary[(index * 5 + $0 * 3) % vocabulary.count] }.joined(separator: " ")
}

/// Dense talk between two voices over `[fromMs, toMs)` of one member's stored audio: a turn
/// every ten seconds lasting eight, the speakers alternating, all about `vocabulary`.
func dialogueTurns(fromMs: Int64, toMs: Int64, vocabulary: [String] = sailingWords) -> [SpeechSpan] {
    var out: [SpeechSpan] = []
    var start = fromMs
    var index = 0
    while start + 8_000 <= toMs {
        out.append(
            SpeechSpan(
                startMs: start, endMs: start + 8_000, text: sentence(vocabulary, index),
                speaker: index % 2 == 0 ? "A" : "B"))
        start += 10_000
        index += 1
    }
    return out
}

/// One voice dictating over `[fromMs, toMs)`: a turn every twenty seconds lasting sixteen, with
/// spoken punctuation, all about `vocabulary`.
func dictationTurns(fromMs: Int64, toMs: Int64, vocabulary: [String] = cookingWords) -> [SpeechSpan] {
    var out: [SpeechSpan] = []
    var start = fromMs
    var index = 0
    while start + 16_000 <= toMs {
        out.append(
            SpeechSpan(
                startMs: start, endMs: start + 16_000,
                text: sentence(vocabulary, index) + " comma " + sentence(vocabulary, index + 1, words: 3)
                    + " full stop",
                speaker: "A"))
        start += 20_000
        index += 1
    }
    return out
}

/// A segmenter policy that belongs to the TESTS: every number written out, none of them read
/// from `SegmenterPolicy.default`, which is a fit that is still being re-run. Tests that pin an
/// exact answer pass THIS, so retuning the default cannot move them; tests that state a
/// guarantee the shipped policy must keep run against both.
///
/// The numbers are round on purpose (a unit costs 8, plus 0.004 × the square of its minutes past
/// 40, plus 1.5 for each minute it falls short of 3), so an expected division can be worked out
/// by hand. Like the shipped policy it scores a unit by its mix of modes and not by its words or
/// its rhythm (`wordWeight` and `rhythmWeight` are 0).
var frozenSegmenterPolicy: SegmenterPolicy {
    var policy = SegmenterPolicy()
    policy.wordPrior = 0.3
    policy.vocabularySize = 2_000
    policy.wordWeight = 0
    policy.rhythmWeight = 0
    policy.dialogueWeight = 0.5
    policy.foreignWeight = 0.5
    policy.dictationWeight = 0.5
    policy.unitCost = 8.0
    policy.longFromMinutes = 40.0
    policy.longWeight = 0.004
    policy.shortBelowMinutes = 3.0
    policy.shortWeight = 1.5
    policy.pauseWeight = 6.0
    policy.pause2MinWeight = 0.0
    policy.pause5MinWeight = 2.0
    policy.pause8MinWeight = 0.0
    policy.turnRateWeight = 2.0
    policy.wordRateWeight = 0.0
    policy.dialogueShiftWeight = 3.0
    policy.foreignShiftWeight = 2.0
    policy.dictationShiftWeight = 1.0
    policy.greetingWeight = 3.0
    policy.windowMs = 5 * 60_000
    policy.maxUnitMs = 4 * 60 * 60_000
    return policy
}

/// Everything on — the long-quiet rule and the segmenter — with the frozen numbers.
var frozenPolicy: BoundaryPolicy { BoundaryPolicy(segmenter: frozenSegmenterPolicy) }

/// THE invariant of the unit model: every sample belongs to exactly one conversation.
///
/// For every segment, the pieces the conversations hold of it — taken in conversation order —
/// cover `[0, ∞)` of its stored audio exactly once: the first starts at the segment's first
/// frame, each next one starts exactly where the one before ended, and the last runs to the
/// segment's end. Inside one conversation the pieces are contiguous (only the first may start
/// late, only the last may end early, and no segment appears twice), the conversations come in
/// the library's own segment order, and no two share an id.
func expectPiecesTile(
    _ conversations: [GroupedConversation], segments: [SegmentMeta],
    _ label: @autoclosure () -> String = "",
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let note = Comment(rawValue: label())
    var pieces: [String: [ConversationMember]] = [:]
    for conversation in conversations {
        #expect(!conversation.members.isEmpty, note, sourceLocation: sourceLocation)
        #expect(
            Set(conversation.memberSegmentIds).count == conversation.members.count,
            "\(conversation.id) holds two pieces of one segment. \(note)",
            sourceLocation: sourceLocation)
        for (index, member) in conversation.members.enumerated() {
            if index > 0 {
                #expect(
                    member.startMediaMs == nil, "\(conversation.id): \(member). \(note)",
                    sourceLocation: sourceLocation)
            }
            if index < conversation.members.count - 1 {
                #expect(
                    member.endMediaMs == nil, "\(conversation.id): \(member). \(note)",
                    sourceLocation: sourceLocation)
            }
            if let end = member.endMediaMs {
                #expect(
                    end > (member.startMediaMs ?? 0), "empty piece \(member). \(note)",
                    sourceLocation: sourceLocation)
            }
            pieces[member.segmentId, default: []].append(member)
        }
    }
    #expect(
        Set(pieces.keys) == Set(segments.map(\.segmentId)), note, sourceLocation: sourceLocation)
    for segment in segments {
        guard let owned = pieces[segment.segmentId], let first = owned.first, let last = owned.last
        else { continue }
        #expect(
            first.startMediaMs == nil, "\(segment.segmentId) does not start at 0: \(owned). \(note)",
            sourceLocation: sourceLocation)
        #expect(
            last.endMediaMs == nil, "\(segment.segmentId) does not run to its end: \(owned). \(note)",
            sourceLocation: sourceLocation)
        for (before, after) in zip(owned, owned.dropFirst()) {
            #expect(
                before.endMediaMs != nil && before.endMediaMs == after.startMediaMs,
                "\(segment.segmentId) has a hole or an overlap: \(owned). \(note)",
                sourceLocation: sourceLocation)
        }
    }
    // Conversation order is segment order (received time, then id — the grouper's own sort).
    let ordered = segments.sorted {
        $0.receivedAtMs == $1.receivedAtMs
            ? $0.segmentId < $1.segmentId : $0.receivedAtMs < $1.receivedAtMs
    }.map(\.segmentId)
    var visited: [String] = []
    for id in conversations.flatMap(\.memberSegmentIds) where visited.last != id {
        visited.append(id)
    }
    #expect(visited == ordered, note, sourceLocation: sourceLocation)
    #expect(
        Set(conversations.map(\.id)).count == conversations.count,
        "duplicate ids \(conversations.map(\.id)). \(note)", sourceLocation: sourceLocation)
}

extension ConversationMember {
    /// `s3` for a whole segment, `s3[..1078500)` / `s3[1078500..)` / `s3[100..200)` for a piece —
    /// so an expectation reads as the grouping it describes.
    var brief: String {
        if isWhole { return segmentId }
        return "\(segmentId)[\(startMediaMs.map(String.init) ?? "")..\(endMediaMs.map(String.init) ?? ""))"
    }
}

extension GroupedConversation {
    var brief: [String] { members.map(\.brief) }

    /// The conversation as the database holds it. `isProvisional` is a property of one grouping
    /// pass and is not persisted, so a grouping read back reads as settled.
    var asStored: GroupedConversation {
        var copy = self
        copy.isProvisional = false
        return copy
    }
}

/// Takes the archive sync's migration back out of a fully migrated database, so a test can
/// build "the database as an earlier release left it" by dropping later columns: the sync's
/// triggers name those columns, and SQLite refuses to drop a column a trigger reads.
func removeArchiveSync(_ db: GRDB.Database) throws {
    // Voice identity came later and its transactional triggers also write the outbox. Rewind
    // that additive migration too; leaving its triggers behind makes SQLite reject unrelated
    // ALTER TABLE statements once the outbox they reference has been removed.
    for name in try String.fetchAll(
        db, sql: "SELECT name FROM sqlite_master WHERE type = 'trigger' AND (name LIKE 'identity_%' OR name LIKE 'voice_%')")
    {
        try db.execute(sql: "DROP TRIGGER \(name)")
    }
    for table in ["voice_history_plans", "voice_auto_attributions", "voice_jobs", "voice_suppressions",
                  "voice_examples", "voice_source_revocations", "voice_sources", "voice_runs",
                  "voice_recognition_config", "voice_archive_revocations", "voice_archive_state",
                  "voice_sample_situations"] {
        try db.execute(sql: "DROP TABLE IF EXISTS \(table)")
    }
    try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier IN ('voice-recognition-v1','voice-archive-provenance-v1','voice-sample-situations-v1')")
    try db.execute(sql: "DROP TABLE IF EXISTS speaker_corrections")
    try db.execute(sql: "DROP TABLE IF EXISTS speaker_identity_state")
    try db.execute(
        sql: "DELETE FROM grdb_migrations WHERE identifier = 'speaker-identity-foundation-v1'")
    for name in try String.fetchAll(
        db, sql: "SELECT name FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'sync_%'")
    {
        try db.execute(sql: "DROP TRIGGER \(name)")
    }
    try db.execute(sql: "DROP TABLE IF EXISTS sync_outbox")
    try db.execute(sql: "DROP TABLE IF EXISTS sync_outbox_state")
    if try db.columns(in: "notes").contains(where: { $0.name == "origin" }) {
        try db.execute(sql: "ALTER TABLE notes DROP COLUMN origin")
    }
    try db.execute(
        sql: "DELETE FROM grdb_migrations WHERE identifier = 'archive-sync-outbox-v1'")
}
