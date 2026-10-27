import AppDB
import Foundation
import LiveAudio
import SearchKit
import SegmentStore
import Testing
import Transcription
import WireProtocol

// A conversation is an ordered list of PIECES — a range of each member segment's stored audio —
// and one segment routinely holds the end of one conversation and the start of the next. Every
// reader that walks "the conversation's segments" instead still compiles and still shows
// something plausible: the neighbour's words, under this conversation's title. So each reader
// is pinned here against the same small library, in which both segments are shared:
//
//     seg-a  |-- first ------------|-- second ---------------------|
//     seg-b  |-- second (cont.) ------------|-- third -------------|
//
// The grouping is made by the real grouper from the person's own two splits, so the pieces
// under test are the ones the app would actually be handed — including their ids.

/// The library above, and a fourth segment with audio missing from it. Not on the main actor:
/// the export and playback seams read it from `@Sendable` closures.
enum PieceLibrary {
    static let t0: UInt64 = 1_788_000_000_000
    static let segmentMs: Int64 = 60_000
    /// Where the second conversation starts in seg-a, and the third in seg-b: 1.5 s ahead of
    /// the turn that opens each.
    static let cutA: Int64 = 38_500
    static let cutB: Int64 = 28_500

    /// One minute of one stream, `index` minutes in. Closed, transcribed, and handed straight
    /// over to the next — the shape a rotation leaves.
    static func meta(
        _ segmentId: String, index: Int, wallMs: Int64 = segmentMs, storedMs: Int64 = segmentMs,
        gaps: [GapMeta] = []
    ) -> SegmentMeta {
        let first = UInt64(index) * UInt64(segmentMs) * 16
        return SegmentMeta(
            segmentId: segmentId, streamId: 1, protocolVersion: 1, codecIdRaw: 1, channels: 1,
            frameSamples: 320, sampleRateHz: 16_000, bitRateBps: 9_800, frameDurationMs: 20,
            startTimeMs: t0, startMonotonicMs: 0,
            // Received after it was recorded: `segmentStartMs` clamps to this, and a fixture
            // claiming 0 would pin every stamp in the suite to 1970.
            receivedAtMs: Int64(t0) + Int64(index + 1) * segmentMs,
            firstSampleIndex: first,
            lastSampleIndexExclusive: first + UInt64(wallMs) * 16,
            // Its newest sample arrived on time, so the late `receivedAtMs` is not a lagging clock.
            headReceivedAtMs: Int64(t0) + Int64(index) * segmentMs + wallMs,
            frameCount: storedMs / 20,
            gaps: gaps,
            closeReason: .rotated,
            transcriptionState: .complete)
    }

    static func turn(_ text: String, _ startMs: Int64, _ endMs: Int64, _ speaker: String)
        -> Transcription.TranscriptSegment
    {
        Transcription.TranscriptSegment(text: text, startMs: startMs, endMs: endMs, speaker: speaker)
    }

    static func transcript(_ segmentId: String, _ turns: [Transcription.TranscriptSegment])
        -> SegmentTranscript
    {
        SegmentTranscript(
            segmentId: segmentId, text: turns.map(\.text).joined(separator: " "),
            modeUsed: .remoteOnly, providerId: "soniox", createdAtMs: Int64(t0) + 200_000,
            segments: turns)
    }

    static let metas: [String: SegmentMeta] = [
        "seg-a": meta("seg-a", index: 0),
        "seg-b": meta("seg-b", index: 1),
    ]

    /// Alternating speakers, so the renderer keeps every turn a row of its own.
    static let transcripts: [String: SegmentTranscript] = [
        "seg-a": transcript(
            "seg-a",
            [
                turn("Morning standup notes first.", 2_000, 6_000, "1"),
                turn("Ship the build on Friday.", 10_000, 14_000, "2"),
                // 26 s of nothing, then the second conversation.
                turn("So about the holiday plans.", 40_000, 44_000, "1"),
                turn("We could fly on the ninth.", 50_000, 55_000, "2"),
            ]),
        "seg-b": transcript(
            "seg-b",
            [
                turn("Flights are cheaper midweek.", 1_000, 5_000, "1"),
                // 25 s of nothing, then the third.
                turn("Right, the budget review.", 30_000, 34_000, "2"),
                turn("Costs are up ten percent.", 40_000, 44_000, "1"),
            ]),
    ]

    static var turns: [String: [Transcription.TranscriptSegment]] {
        transcripts.mapValues(\.segments)
    }

    static var evidence: [String: SegmentSpeechEvidence] {
        var out: [String: SegmentSpeechEvidence] = [:]
        for (segmentId, meta) in metas {
            out[segmentId] = SegmentSpeechEvidence.of(
                meta,
                transcriptSpeech: transcripts[segmentId]?.segments.map {
                    SpeechSpan(
                        startMs: $0.startMs, endMs: $0.endMs, text: $0.text, speaker: $0.speaker)
                })
        }
        return out
    }

    /// Regroups the library into `db` the way the pipeline does.
    @discardableResult
    static func regroup(_ db: AppDatabase, policy: BoundaryPolicy = .quietOnly) async throws
        -> [GroupedConversation]
    {
        try await ConversationGrouper.rebuild(
            segments: Array(metas.values), pauses: [], openSegmentId: nil, evidence: evidence,
            policy: policy, db: db)
    }

    /// The three-conversation library: the person's splits in front of "So about the holiday
    /// plans." and "Right, the budget review."
    static func sharedLibrary() async throws -> AppDatabase {
        let db = try AppDatabase.inMemory()
        let edits = ConversationBoundaryEdits(database: db)
        try await edits.split(at: ConversationCut(segmentId: "seg-a", mediaMs: cutA))
        try await edits.split(at: ConversationCut(segmentId: "seg-b", mediaMs: cutB))
        try await regroup(db)
        return db
    }

    static let first = "conv-seg-a"
    static let second = "conv-seg-a-m38500"
    static let third = "conv-seg-b-m28500"

    static func pieces(of id: String, in db: AppDatabase) async throws -> [ConversationMember] {
        let detail = try await ConversationQueries(db: db).detail(id: id)
        return try #require(detail).pieces
    }

    static func walk(_ pieces: [ConversationMember]) async -> LiveWorld.WalkedMembers {
        await LiveWorld.walkMembers(
            pieces, metas: metas, transcripts: transcripts, assignments: [])
    }

    static func turnRows(_ walked: LiveWorld.WalkedMembers) -> [TranscriptTurn] {
        walked.transcript.compactMap { item in
            if case .turn(let turn) = item { return turn }
            return nil
        }
    }

    /// A frame log whose payloads say which frame of which segment they are.
    static func frames(_ segmentId: String) -> [FrameRecord] {
        let tag: UInt8 = segmentId == "seg-a" ? 0xA : 0xB
        return (0..<Int(segmentMs / 20)).map { index in
            FrameRecord(
                sequence: UInt32(index), sampleIndex: UInt64(index) * 320,
                payload: [tag, UInt8(index & 0xFF), UInt8(index >> 8)])
        }
    }

    static func frameIndex(_ payload: [UInt8]) -> Int { Int(payload[1]) | Int(payload[2]) << 8 }

    /// 100 s of wall time holding 60 s of audio: 20 s lost from 10 s, 20 s lost from 60 s —
    /// one loss in each half.
    static let gappyMeta = meta(
        "seg-g", index: 0, wallMs: 100_000, storedMs: 60_000,
        gaps: [loss(atWallMs: 10_000, durationMs: 20_000), loss(atWallMs: 60_000, durationMs: 20_000)])

    static func loss(atWallMs: Int64, durationMs: Int64) -> GapMeta {
        GapMeta(
            firstMissingSequence: UInt32(atWallMs / 20),
            missingFrameCount: UInt32(durationMs / 20),
            firstMissingSampleIndex: UInt64(atWallMs) * 16,
            origin: GapMeta.originWatch,
            reasonRaw: Int(GapReason.spoolOverflow.rawValue))
    }

    /// Timings on the STORED-audio clock, as a durable transcript's are.
    static let gappyTurns: [SearchKit.TranscriptSegment] = [
        SearchKit.TranscriptSegment(text: "Before the first loss.", startMs: 2_000, endMs: 4_000, speaker: "1"),
        SearchKit.TranscriptSegment(text: "After the first loss.", startMs: 12_000, endMs: 14_000, speaker: "2"),
        SearchKit.TranscriptSegment(text: "Before the second loss.", startMs: 36_000, endMs: 38_000, speaker: "1"),
        SearchKit.TranscriptSegment(text: "After the second loss.", startMs: 45_000, endMs: 47_000, speaker: "2"),
    ]

    static func gappyPiece(_ piece: ConversationMember?) -> MemberTranscript {
        TranscriptItems.member(
            segmentId: "seg-g", meta: gappyMeta, segments: gappyTurns, assignments: [],
            timebase: .media, piece: piece)
    }

    static func missingRows(_ built: MemberTranscript) -> Int {
        built.items.filter { if case .missing = $0 { return true } else { return false } }.count
    }
}

@Suite("conversation pieces") @MainActor
struct ConversationPiecesTests {
    @Test func museTimeRangeKeepsConversationOwnershipAndDoesNotLeakUntimedText() throws {
        let member = ConversationMember(segmentId: "seg-a", startMediaMs: PieceLibrary.cutA)
        let meta = PieceLibrary.metas["seg-a"]!
        let piece = ConversationText.piece(member, of: PieceLibrary.transcripts["seg-a"])!
        let start = Int64(PieceLibrary.t0)
        let result = AppMuseData.transcriptInWindow(piece, member: member, meta: meta,
            window: (start + 45_000)..<(start + 60_000))
        #expect(result.transcript.text == "We could fly on the ninth.")
        #expect(!result.transcript.text.contains("standup"))
        var untimed = piece; untimed.segments = []
        let excluded = AppMuseData.transcriptInWindow(untimed, member: member, meta: meta,
            window: (start + 45_000)..<(start + 60_000))
        #expect(excluded.transcript.text.isEmpty && excluded.timingIncomplete)
        let complete = AppMuseData.transcriptInWindow(untimed, member: member, meta: meta,
            window: start..<(start + 60_000))
        #expect(complete.transcript.text == untimed.text)
    }

    typealias Library = PieceLibrary

    // MARK: - The grouping under test is the one described above

    @Test func theLibraryIsThreeConversationsSharingBothSegments() async throws {
        let db = try await Library.sharedLibrary()
        let first = try await Library.pieces(of: Library.first, in: db)
        let second = try await Library.pieces(of: Library.second, in: db)
        let third = try await Library.pieces(of: Library.third, in: db)
        #expect(first == [ConversationMember(segmentId: "seg-a", endMediaMs: Library.cutA)])
        #expect(
            second == [
                ConversationMember(segmentId: "seg-a", startMediaMs: Library.cutA),
                ConversationMember(segmentId: "seg-b", endMediaMs: Library.cutB),
            ])
        #expect(third == [ConversationMember(segmentId: "seg-b", startMediaMs: Library.cutB)])
    }

    // MARK: - 1. What a conversation shows

    /// A conversation made of two partial pieces shows its own turns and nothing else, and is
    /// as long as its pieces — not its two whole segments (which would be two minutes).
    @Test func aConversationOfTwoPartialPiecesShowsOnlyItsOwnTurns() async throws {
        let db = try await Library.sharedLibrary()
        let pieces = try await Library.pieces(of: Library.second, in: db)
        let walked = await Library.walk(pieces)

        #expect(
            Library.turnRows(walked).map(\.text) == [
                "So about the holiday plans.", "We could fly on the ninth.",
                "Flights are cheaper midweek.",
            ])
        // 21.5 s of seg-a and 28.5 s of seg-b.
        #expect(walked.mediaMs == (Library.segmentMs - Library.cutA) + Library.cutB)
        #expect(walked.mediaMs == 50_000)
    }

    /// Every position is on the CONVERSATION's timeline: the earlier pieces' lengths, plus how
    /// far into its own piece the turn is. Not how far into its segment — the 38.5 s of seg-a
    /// before the piece are another conversation's audio, and the player never holds them.
    @Test func turnsSitOnTheConversationsOwnTimeline() async throws {
        let db = try await Library.sharedLibrary()
        let pieces = try await Library.pieces(of: Library.second, in: db)
        let rows = Library.turnRows(await Library.walk(pieces))

        #expect(rows.map(\.mediaOffsetMs) == [1_500, 11_500, 21_500 + 1_000])
        #expect(rows.map(\.mediaEndMs) == [5_500, 16_500, 21_500 + 5_000])
        // The stamps beside them are still the wall clock the words were said at.
        let secondsIn = rows.compactMap(\.startedAt).map {
            Int64(($0.timeIntervalSince1970 * 1000).rounded()) - Int64(Library.t0)
        }
        #expect(secondsIn == [40_000, 50_000, 61_000])
    }

    /// The neighbours sharing those segments show the rest, and between the three of them
    /// every turn appears exactly once.
    @Test func theNeighboursShowTheRestAndNothingTwice() async throws {
        let db = try await Library.sharedLibrary()
        var shown: [String] = []
        var total: Int64 = 0
        for id in [Library.first, Library.second, Library.third] {
            let pieces = try await Library.pieces(of: id, in: db)
            let walked = await Library.walk(pieces)
            shown += Library.turnRows(walked).map(\.text)
            total += walked.mediaMs
        }
        #expect(
            shown == Library.transcripts["seg-a"]!.segments.map(\.text)
                + Library.transcripts["seg-b"]!.segments.map(\.text))
        // The pieces tile the two segments: no audio is in two conversations, or in none.
        #expect(total == 2 * Library.segmentMs)

        let firstPieces = try await Library.pieces(of: Library.first, in: db)
        let firstRows = Library.turnRows(await Library.walk(firstPieces))
        #expect(
            firstRows.map(\.text) == ["Morning standup notes first.", "Ship the build on Friday."])
        let thirdPieces = try await Library.pieces(of: Library.third, in: db)
        let thirdRows = Library.turnRows(await Library.walk(thirdPieces))
        #expect(thirdRows.map(\.text) == ["Right, the budget review.", "Costs are up ten percent."])
        // The third starts 28.5 s into seg-b, so its first turn is 1.5 s in — not 30.
        #expect(thirdRows.first?.mediaOffsetMs == 1_500)
    }

    /// What Spotlight indexes and Siri is handed: the same cut, as text.
    @Test func aConversationsTextIsItsPiecesOnly() async throws {
        let db = try await Library.sharedLibrary()
        let pieces = try await Library.pieces(of: Library.second, in: db)
        let text = ConversationText.joined(pieces) { Library.transcripts[$0] }
        #expect(
            text == """
                So about the holiday plans. We could fly on the ninth.
                Flights are cheaper midweek.
                """)
    }

    // MARK: - 2. What it plays and exports

    /// The player is handed each piece's own frames: 50 s of audio is 2,500 frames, starting
    /// at the frame the conversation starts on and stopping where the next one begins.
    @Test func playbackIsThePiecesFrames() async throws {
        let db = try await Library.sharedLibrary()
        let pieces = try await Library.pieces(of: Library.second, in: db)
        let payloads = ConversationAudio.payloads(of: pieces, readFrames: Library.frames)

        #expect(payloads.count == 2_500)
        #expect(payloads.first == [0xA, UInt8(1_925 & 0xFF), UInt8(1_925 >> 8)])
        #expect(payloads.last.map(Library.frameIndex) == 1_424)
        #expect(payloads.last?.first == 0xB)
        // The scrubber, the rows and the player agree on how long that is.
        let timeline = ConversationTimeline(members: pieces, metas: Library.metas)
        #expect(timeline.durationMs == Int64(payloads.count) * 20)
        let walked = await Library.walk(pieces)
        #expect(walked.mediaMs == timeline.durationMs)
    }

    /// Between them the three conversations play every frame of both segments exactly once.
    @Test func noFrameIsPlayedByTwoConversations() async throws {
        let db = try await Library.sharedLibrary()
        var played: [[UInt8]] = []
        for id in [Library.first, Library.second, Library.third] {
            let pieces = try await Library.pieces(of: id, in: db)
            played += ConversationAudio.payloads(of: pieces, readFrames: Library.frames)
        }
        #expect(played == Library.frames("seg-a").map(\.payload) + Library.frames("seg-b").map(\.payload))
    }

    /// The open segment's sidecar lags its frame log, so an open-ended piece plays whatever
    /// has actually landed, and a range past the end of the log is simply short.
    @Test func aPieceIsCutAgainstTheFramesThatExist() {
        let log = Array(Library.frames("seg-a").prefix(100))
        let openEnded = ConversationAudio.payloads(
            of: [ConversationMember(segmentId: "seg-a", startMediaMs: 1_000)],
            readFrames: { _ in log })
        #expect(openEnded.count == 50)
        let pastTheEnd = ConversationAudio.payloads(
            of: [ConversationMember(segmentId: "seg-a", startMediaMs: 1_000, endMediaMs: 9_000)],
            readFrames: { _ in log })
        #expect(pastTheEnd.count == 50)
    }

    /// A piece exported on its own: the conversation's range of the recording, under a name
    /// that is not the recording's — the automatic pass skips any segment whose WAV exists,
    /// so a piece written under the segment's name would stand in for all of it.
    @Test func exportWritesThePieceUnderItsOwnName() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("piece-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let decoded = DecodedFrames()
        let exporter = AudioExportManager(
            exportRoot: root,
            listSegments: { Array(Library.metas.values) },
            readMeta: { Library.metas[$0] },
            readFrames: { Library.frames($0) },
            decodePcm: { _, frames in
                decoded.record(frames.count)
                return AsyncThrowingStream { continuation in
                    continuation.yield(Data(count: frames.count * 640))
                    continuation.finish()
                }
            })

        let piece = try await exporter.exportSegment(
            "seg-a", fromMediaMs: Library.cutA, toMediaMs: nil)
        let whole = try await exporter.exportSegment("seg-a", fromMediaMs: nil, toMediaMs: nil)

        #expect(decoded.counts == [1_075, 3_000])
        let pieceName = try #require(piece.files.first?.path).split(separator: "/").last
        let wholeName = try #require(whole.files.first?.path).split(separator: "/").last
        #expect(pieceName != wholeName)
        #expect(pieceName?.hasSuffix("-38500-60000ms.wav") == true)
        // 44-byte header + 1,075 frames of 320 16-bit samples.
        #expect(piece.files.first?.bytes == Int64(44 + 1_075 * 640))
    }

    // MARK: - 3. Where a citation lands

    /// A citation is a segment and a wall time. In the second half of a shared segment it
    /// belongs to the conversation that owns that half — and its scrubber position is counted
    /// over THAT conversation's pieces.
    @Test func aCitationInTheSecondHalfOfASharedSegmentOpensTheConversationThatOwnsIt()
        async throws
    {
        let db = try await Library.sharedLibrary()
        let queries = ConversationQueries(db: db)
        func position(_ segmentId: String, atMediaMs mediaMs: Int64?) async throws
            -> LiveWorld.CitedPosition
        {
            let startMs = mediaMs.map {
                ConversationGrouper.segmentStartMs(Library.metas[segmentId]!) + $0
            }
            let cited = await LiveWorld.citedPosition(
                of: AskCitation(
                    segmentId: segmentId, number: 1, startMs: startMs,
                    endMs: startMs.map { $0 + 5_000 }),
                queries: queries,
                loadMetas: { ids in Library.metas.filter { ids.contains($0.key) } })
            return try #require(cited)
        }

        // "We could fly on the ninth." — 50 s into seg-a, which the FIRST conversation starts.
        let flying = try await position("seg-a", atMediaMs: 50_000)
        #expect(flying.detail.row.id == Library.second)
        #expect(flying.mediaOffsetMs == 50_000 - Library.cutA)

        // The first half of the same segment is still the first conversation's.
        let build = try await position("seg-a", atMediaMs: 10_000)
        #expect(build.detail.row.id == Library.first)
        #expect(build.mediaOffsetMs == 10_000)

        // The second half of seg-b: the third conversation, 11.5 s in.
        let costs = try await position("seg-b", atMediaMs: 40_000)
        #expect(costs.detail.row.id == Library.third)
        #expect(costs.mediaOffsetMs == 40_000 - Library.cutB)

        // The first half of seg-b is the SECOND conversation's second piece: its 21.5 s of
        // seg-a come first on the scrubber.
        let flights = try await position("seg-b", atMediaMs: 1_000)
        #expect(flights.detail.row.id == Library.second)
        #expect(flights.mediaOffsetMs == 22_500)

        // A citation with no time (older citations, imports) means the segment's first
        // instant — so for seg-b it is the conversation that owns the segment's START.
        let untimed = try await position("seg-b", atMediaMs: nil)
        #expect(untimed.detail.row.id == Library.second)
        #expect(untimed.mediaOffsetMs == 21_500)
    }

    /// The wall time of a citation comes back through the segment's gap records before it is
    /// compared with a piece's bounds, which are on the stored-audio clock.
    @Test func aCitedWallTimeIsConvertedToTheClockPiecesAreCutOn() {
        // 100 s of wall time holding 60 s of audio: 20 s lost from 10 s, 20 s lost from 60 s.
        let meta = Library.gappyMeta
        let startMs = ConversationGrouper.segmentStartMs(meta)
        func cited(_ wallMs: Int64) -> Int64 {
            LiveWorld.citedMediaMs(
                AskCitation(segmentId: "seg-g", number: 1, startMs: startMs + wallMs), meta: meta)
        }
        #expect(cited(5_000) == 5_000)
        #expect(cited(32_000) == 12_000)
        #expect(cited(85_000) == 45_000)
        #expect(
            LiveWorld.citedMediaMs(AskCitation(segmentId: "seg-g", number: 1), meta: meta) == 0)
    }

    /// The owner of a moment, over rows already read — for naming a citation's source.
    @Test func theOwnerOfAMomentIsThePieceThatContainsIt() async throws {
        let db = try await Library.sharedLibrary()
        let owners = try await ConversationQueries(db: db).membersBySegment()
        let pieces = try #require(owners["seg-a"])
        #expect(LiveWorld.owner(of: 0, in: pieces)?.conversationId == Library.first)
        #expect(LiveWorld.owner(of: Library.cutA - 1, in: pieces)?.conversationId == Library.first)
        #expect(LiveWorld.owner(of: Library.cutA, in: pieces)?.conversationId == Library.second)
        // A stale offset past every piece still belongs somewhere: the last one.
        #expect(LiveWorld.owner(of: 10 * Library.segmentMs, in: pieces)?.conversationId == Library.second)
        #expect(LiveWorld.owner(of: 0, in: []) == nil)
    }

    // MARK: - 4. Quiet and missing rows

    /// Each half of a shared segment shows the interruption that happened in it, once, and
    /// puts its tick where it falls on that conversation's own scrubber.
    @Test func eachPieceShowsOnlyTheGapsInsideIt() {
        let whole = Library.gappyPiece(nil)
        #expect(Library.missingRows(whole) == 2)
        #expect(whole.missingMediaOffsets == [10_000, 40_000])
        #expect(whole.mediaMs == 60_000)

        let early = Library.gappyPiece(ConversationMember(segmentId: "seg-g", endMediaMs: 30_000))
        #expect(Library.missingRows(early) == 1)
        #expect(early.missingMediaOffsets == [10_000])
        #expect(early.mediaMs == 30_000)

        let late = Library.gappyPiece(ConversationMember(segmentId: "seg-g", startMediaMs: 30_000))
        #expect(Library.missingRows(late) == 1)
        // 40 s into the segment's audio is 10 s into this piece.
        #expect(late.missingMediaOffsets == [10_000])
        #expect(late.mediaMs == 30_000)
        let lateTurns: [TranscriptTurn] = late.items.compactMap {
            if case .turn(let turn) = $0 { return turn }
            return nil
        }
        #expect(lateTurns.map(\.text) == ["Before the second loss.", "After the second loss."])
        #expect(lateTurns.map(\.mediaOffsetMs) == [6_000, 15_000])
    }

    /// A loss sitting exactly where one conversation hands over to the next is the END of the
    /// one it interrupted — shown once, there, and not at the top of the one that began after.
    @Test func aGapAtTheCutBelongsToTheConversationItInterrupted() {
        // The first loss sits at 10 s of stored audio.
        let before = Library.gappyPiece(ConversationMember(segmentId: "seg-g", endMediaMs: 10_000))
        let after = Library.gappyPiece(ConversationMember(segmentId: "seg-g", startMediaMs: 10_000))
        #expect(before.missingMediaOffsets == [10_000])
        #expect(after.missingMediaOffsets == [30_000])
    }

    /// The live preview is timed on the WALL clock, so it is cut by the piece's wall window —
    /// the same range, on the other clock.
    @Test func aLivePreviewIsCutOnTheWallClock() {
        // The same four turns, as a preview would time them: gaps included.
        let preview: [SearchKit.TranscriptSegment] = [
            SearchKit.TranscriptSegment(text: "Before the first loss.", startMs: 2_000, endMs: 4_000),
            SearchKit.TranscriptSegment(text: "After the first loss.", startMs: 32_000, endMs: 34_000),
            SearchKit.TranscriptSegment(text: "Before the second loss.", startMs: 56_000, endMs: 58_000),
            SearchKit.TranscriptSegment(text: "After the second loss.", startMs: 85_000, endMs: 87_000),
        ]
        let late = TranscriptItems.member(
            segmentId: "seg-g", meta: Library.gappyMeta, segments: preview, assignments: [],
            timebase: .wall, piece: ConversationMember(segmentId: "seg-g", startMediaMs: 30_000))
        let texts: [String] = late.items.compactMap {
            if case .turn(let turn) = $0 { return turn.text }
            return nil
        }
        #expect(texts == ["Before the second loss.", "After the second loss."])
    }

    // MARK: - 5. The live conversation

    /// The live conversation usually starts partway through a recording. Its timeline strip
    /// is clipped to the conversation's own start, so the 38.5 s of seg-a that belong to the
    /// conversation before it are not counted as recorded here.
    @Test func theLiveTimelineStartsWhereTheConversationDoes() {
        let startMs = Int64(Library.t0) + Library.cutA
        let nowMs = Int64(Library.t0) + Library.segmentMs
        let spans = LiveTimeline.spans(
            metas: [Library.metas["seg-a"]!], pauses: [], startMs: startMs, nowMs: nowMs,
            timeZoneID: "UTC")

        #expect(spans.first?.startMs == startMs)
        #expect(spans.allSatisfy { $0.startMs >= startMs && $0.endMs <= nowMs })
        #expect(LiveTimeline.total(spans, .recorded) == Library.segmentMs - Library.cutA)
    }

    // MARK: - 6. Ask and notes

    /// The text a conversation-scoped question reads, and the stretch of the day it is dated
    /// at: the piece's, not the segment's.
    @Test func aScopedQuestionReadsAndDatesThePiece() async throws {
        let db = try await Library.sharedLibrary()
        let pieces = try await Library.pieces(of: Library.second, in: db)
        let owned = Dictionary(uniqueKeysWithValues: pieces.map { ($0.segmentId, $0) })
        let cut = LiveWorld.cut(Library.transcripts, to: owned)

        #expect(cut["seg-a"]?.text == "So about the holiday plans. We could fly on the ninth.")
        #expect(cut["seg-b"]?.text == "Flights are cheaper midweek.")
        // No pieces named: recordings are read whole (a date-scoped question).
        #expect(LiveWorld.cut(Library.transcripts, to: [:]) == Library.transcripts)

        let t0 = Int64(Library.t0)
        let a = LiveWorld.wallExtent(of: owned["seg-a"], meta: Library.metas["seg-a"]!)
        #expect(a.0 == t0 + Library.cutA)
        #expect(a.1 == t0 + Library.segmentMs)
        let b = LiveWorld.wallExtent(of: owned["seg-b"], meta: Library.metas["seg-b"]!)
        #expect(b.0 == t0 + Library.segmentMs)
        #expect(b.1 == t0 + Library.segmentMs + Library.cutB)
        let whole = LiveWorld.wallExtent(of: nil, meta: Library.metas["seg-a"]!)
        #expect(whole.0 == t0)
        #expect(whole.1 == t0 + Library.segmentMs)
    }
}

/// What the fake decoder was asked to decode, in order.
private final class DecodedFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Int] = []

    func record(_ count: Int) { lock.withLock { recorded.append(count) } }
    var counts: [Int] { lock.withLock { recorded } }
}
