import AppDB
import Foundation
import SegmentStore
import Testing
import WireProtocol

// Opening a conversation at a wall-clock moment (History plan 7.9).

@Suite("history moment: the row a moment lands on")
struct HistoryMomentRowTests {
    /// Rows at 10:00:00, 10:01:00 (quiet), 10:05:00, 10:06:00, as epoch ms offsets from `t0`.
    static let t0: Int64 = 1_727_690_400_000

    static func at(_ offsetMs: Int64) -> Date {
        Date(timeIntervalSince1970: Double(t0 + offsetMs) / 1000)
    }

    static func turn(_ id: String, _ offsetMs: Int64?) -> TranscriptItem {
        .turn(
            TranscriptTurn(
                id: id, speakerLabel: "S1", name: "Roger", role: .you, text: id,
                startedAt: offsetMs.map(at)))
    }

    static func quiet(_ id: String, _ offsetMs: Int64) -> TranscriptItem {
        .quiet(TranscriptMarker(id: id, text: "quiet for 4 min", startedAt: at(offsetMs)))
    }

    static let transcript: [TranscriptItem] = [
        turn("a", 0),
        quiet("q", 60_000),
        turn("b", 300_000),
        turn("c", 360_000),
    ]

    private func row(_ offsetMs: Int64, in transcript: [TranscriptItem] = transcript) -> String? {
        MomentResolver.rowIndex(in: transcript, atWallMs: Self.t0 + offsetMs)
            .map { transcript[$0].id }
    }

    @Test func beforeTheFirstRowLandsOnTheFirst() {
        #expect(row(-3_600_000) == "a")
    }

    @Test func exactlyOnARowLandsOnIt() {
        #expect(row(0) == "a")
        #expect(row(300_000) == "b")
    }

    @Test func betweenRowsLandsOnTheOneBefore() {
        #expect(row(30_000) == "a")
        #expect(row(330_000) == "b")
    }

    /// Inside a quiet stretch: the marker that says so, not the words before it.
    @Test func insideAGapLandsOnTheMarkerThatDescribesIt() {
        #expect(row(200_000) == "q")
    }

    /// A gap with no marker (between two members, say) lands on the last words before it.
    @Test func insideAnUnmarkedGapLandsOnTheLastRowBeforeIt() {
        let transcript = [Self.turn("a", 0), Self.turn("b", 3_600_000)]
        #expect(row(1_800_000, in: transcript) == "a")
    }

    @Test func afterTheLastRowLandsOnTheLast() {
        #expect(row(86_400_000) == "c")
    }

    @Test func anEmptyTranscriptHasNowhereToLand() {
        #expect(MomentResolver.rowIndex(in: [], atWallMs: Self.t0) == nil)
    }

    /// Rows with no stamp (a mock fixture, an untimed tail) are not compared; if nothing has a
    /// stamp there is nothing to land on.
    @Test func untimedRowsAreSkipped() {
        let untimed = [Self.turn("x", nil), Self.turn("y", nil)]
        #expect(MomentResolver.rowIndex(in: untimed, atWallMs: Self.t0) == nil)
        let mixed = [Self.turn("x", nil), Self.turn("a", 0), Self.turn("y", nil)]
        #expect(row(500, in: mixed) == "a")
    }

    /// By time, not by position: an out-of-order row does not capture the landing.
    @Test func theLatestStampAtOrBeforeWinsWhateverItsPosition() {
        let transcript = [
            Self.turn("a", 0), Self.turn("b", 600_000), Self.turn("stray", 60_000),
            Self.turn("c", 1_200_000),
        ]
        #expect(row(700_000, in: transcript) == "b")
        #expect(row(100_000, in: transcript) == "stray")
    }

    /// Equal stamps: the later row going back, the earlier row going forward.
    @Test func equalStampsResolveToTheLastBeforeAndTheFirstAfter() {
        let transcript = [
            Self.turn("a1", 0), Self.turn("a2", 0), Self.turn("b1", 60_000),
            Self.turn("b2", 60_000),
        ]
        #expect(row(10, in: transcript) == "a2")
        #expect(row(-10, in: transcript) == "a1")
    }

    /// A 24-hour conversation is thousands of rows; the lookup is one pass.
    @Test func aDayLongTranscriptResolvesToTheRightRow() {
        let transcript = (0..<6_000).map { Self.turn("r\($0)", Int64($0) * 14_400) }
        #expect(row(12 * 3_600_000 + 1, in: transcript) == "r3000")
        #expect(row(24 * 3_600_000, in: transcript) == "r5999")
    }
}

// MARK: - The shared scrubber walk

/// Citations and moments go through one hop (`LiveWorld.position(ofSegment:atWallMs:)`): the
/// wall time onto the segment's stored-audio clock (`LiveWorld.mediaMs(ofWallMs:meta:)`), then
/// its place on the conversation's pieces laid end to end (`ConversationTimeline`). For a
/// conversation of WHOLE segments that must still land exactly where the member walk it
/// replaced did, which is what this suite pins; `HistoryMomentPieceTests` below pins the pieces.
@Suite("history moment: the scrubber walk citations and moments share")
struct HistoryMomentScrubberTests {
    static let t0: Int64 = 1_727_690_400_000

    /// `wallMs` of wall time at 16 kHz / 20 ms frames starting at `startMs`, holding `storedMs`
    /// of audio. Received as it ended, so `startWallMs` is the sample-derived start.
    static func meta(
        _ id: String, startMs: Int64, wallMs: Int64 = 60_000, storedMs: Int64? = nil,
        gaps: [GapMeta] = [], extents: Bool = true
    ) -> SegmentMeta {
        SegmentMeta(
            segmentId: id, streamId: 1, protocolVersion: 1, codecIdRaw: 1, channels: 1,
            frameSamples: 320, sampleRateHz: 16_000, bitRateBps: 16_000, frameDurationMs: 20,
            startTimeMs: UInt64(startMs), startMonotonicMs: 0,
            receivedAtMs: startMs + wallMs,
            firstSampleIndex: extents ? 0 : nil,
            lastSampleIndexExclusive: extents ? UInt64(wallMs) * 16 : nil,
            frameCount: (storedMs ?? wallMs) / 20,
            gaps: gaps)
    }

    static func gap(atMs: Int64, durationMs: Int64) -> GapMeta {
        GapMeta(
            firstMissingSequence: UInt32(atMs / 20), missingFrameCount: UInt32(durationMs / 20),
            firstMissingSampleIndex: UInt64(atMs) * 16, origin: GapMeta.originWatch,
            reasonRaw: Int(GapReason.spoolOverflow.rawValue))
    }

    /// `LiveWorld.citationTarget`'s member walk exactly as it stood before it was factored out
    /// (f45e099), kept here as the oracle the shared hop must reproduce for whole segments.
    static func legacyOffset(
        citationStartMs: Int64?, citedId: String, members: [String],
        metas: [String: SegmentMeta]
    ) -> Int64? {
        var mediaBeforeMemberMs: Int64 = 0
        var mediaOffsetMs: Int64?
        for member in members {
            guard let meta = metas[member] else { continue }
            let mediaMs = segmentStoredAudioMs(meta)
            if member == citedId {
                guard mediaMs > 0 else { break }
                let memberStartMs = ConversationGrouper.segmentStartMs(meta)
                let clock = SegmentMediaClock(meta)
                let into = min(
                    max((citationStartMs ?? memberStartMs) - memberStartMs, 0), clock.wallSpanMs)
                mediaOffsetMs =
                    mediaBeforeMemberMs
                    + (clock.isExact ? clock.media(fromWall: into) : min(into, clock.mediaSpanMs))
                break
            }
            mediaBeforeMemberMs += mediaMs
        }
        return mediaOffsetMs
    }

    /// Asserts parity with the oracle and returns the shared function's answer.
    @discardableResult
    static func offset(
        _ wallMs: Int64?, in member: String, _ members: [String], _ metas: [SegmentMeta],
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> Int64? {
        let byId = Dictionary(uniqueKeysWithValues: metas.map { ($0.segmentId, $0) })
        let shared = byId[member].flatMap { meta in
            ConversationTimeline(members: members.map { ConversationMember(segmentId: $0) }, metas: byId)
                .offset(segmentId: member, mediaMs: LiveWorld.mediaMs(ofWallMs: wallMs, meta: meta))
        }
        let legacy = legacyOffset(
            citationStartMs: wallMs, citedId: member, members: members, metas: byId)
        #expect(
            shared == legacy,
            "shared \(String(describing: shared)) vs legacy \(String(describing: legacy))",
            sourceLocation: sourceLocation)
        return shared
    }

    /// Exact clock: 10 s of loss at 20 s. 30 s of wall time in is 20 s of stored audio.
    @Test func anExactClockConvertsThroughTheGapRecords() {
        let a = Self.meta(
            "a", startMs: Self.t0, storedMs: 50_000,
            gaps: [Self.gap(atMs: 20_000, durationMs: 10_000)])
        #expect(SegmentMediaClock(a).isExact)
        #expect(Self.offset(Self.t0 + 30_000, in: "a", ["a"], [a]) == 20_000)
        #expect(Self.offset(Self.t0 + 25_000, in: "a", ["a"], [a]) == 20_000)  // inside the gap
        #expect(Self.offset(Self.t0 + 10_000, in: "a", ["a"], [a]) == 10_000)
    }

    /// Inexact clock (the records account for none of the missing half): the wall offset
    /// passes through, clamped to the stored audio, rather than being stretched by a guess.
    @Test func anInexactClockPassesTheOffsetThroughClamped() {
        let a = Self.meta("a", startMs: Self.t0, storedMs: 30_000)
        #expect(!SegmentMediaClock(a).isExact)
        #expect(Self.offset(Self.t0 + 20_000, in: "a", ["a"], [a]) == 20_000)
        #expect(Self.offset(Self.t0 + 45_000, in: "a", ["a"], [a]) == 30_000)
    }

    /// Several members: every member before the named one adds its STORED audio.
    @Test func earlierMembersAddTheirStoredAudio() {
        let a = Self.meta("a", startMs: Self.t0, storedMs: 30_000)  // inexact, 30 s stored
        let b = Self.meta(
            "b", startMs: Self.t0 + 120_000, storedMs: 50_000,
            gaps: [Self.gap(atMs: 0, durationMs: 10_000)])
        let c = Self.meta("c", startMs: Self.t0 + 300_000)
        let members = ["a", "b", "c"]
        let metas = [a, b, c]
        // 30 s of a, then 15 s into b of which the first 10 s were lost: 5 s.
        #expect(Self.offset(Self.t0 + 135_000, in: "b", members, metas) == 35_000)
        // a and b whole (30 s + 50 s), then 1 s into c.
        #expect(Self.offset(Self.t0 + 301_000, in: "c", members, metas) == 81_000)
        #expect(Self.offset(nil, in: "c", members, metas) == 80_000)
    }

    /// Outside the member's span, the position clamps to its edges.
    @Test func timesOutsideTheMemberClampToItsEdges() {
        let a = Self.meta("a", startMs: Self.t0)
        let b = Self.meta("b", startMs: Self.t0 + 600_000)
        #expect(Self.offset(Self.t0 + 300_000, in: "b", ["a", "b"], [a, b]) == 60_000)
        #expect(Self.offset(Self.t0 + 10_000_000, in: "b", ["a", "b"], [a, b]) == 120_000)
    }

    /// A member that holds no frames. With sample extents its stored audio is read as its wall
    /// span (`segmentStoredAudioMs`), the same number the transcript walk and the player use; with
    /// none it holds nothing, and a moment in it has nowhere to cue.
    @Test func aMemberWithNoFrames() {
        let empty = Self.meta("e", startMs: Self.t0, storedMs: 0)
        let hollow = Self.meta("h", startMs: Self.t0, storedMs: 0, extents: false)
        let b = Self.meta("b", startMs: Self.t0 + 120_000)
        #expect(Self.offset(Self.t0 + 120_000, in: "b", ["e", "b"], [empty, b]) == 60_000)
        #expect(Self.offset(Self.t0 + 1_000, in: "h", ["h", "b"], [hollow, b]) == nil)
        #expect(Self.offset(Self.t0 + 120_000, in: "b", ["h", "b"], [hollow, b]) == 0)
    }

    /// A member with no sidecar contributes nothing, and cannot itself be landed in.
    @Test func aMissingSidecarIsSkipped() {
        let b = Self.meta("b", startMs: Self.t0 + 120_000)
        #expect(Self.offset(Self.t0 + 121_000, in: "b", ["gone", "b"], [b]) == 1_000)
        #expect(Self.offset(Self.t0, in: "gone", ["gone", "b"], [b]) == nil)
        #expect(Self.offset(Self.t0, in: "stranger", ["b"], [b]) == nil)
    }
}

// MARK: - Which recording

@Suite("history moment: which recording a time belongs to")
struct HistoryMomentSegmentTests {
    typealias Span = MomentResolver.Span
    typealias Window = MomentResolver.Window
    static let minute: Int64 = 60_000

    static func span(
        _ id: String, _ startMin: Int64, _ endMin: Int64, in conversation: String = "c1",
        frames: Bool = true
    ) -> Span {
        Span(
            segmentId: id, conversationId: conversation, startMs: startMin * minute,
            endMs: endMin * minute, hasFrames: frames)
    }

    static func window(_ id: String, _ startMin: Int64, _ endMin: Int64) -> Window {
        Window(conversationId: id, range: (startMin * minute)..<(endMin * minute))
    }

    private func pick(_ atMin: Int64, _ spans: [Span], _ windows: [Window] = [], plusMs: Int64 = 0)
        -> String?
    {
        MomentResolver.segment(atWallMs: atMin * Self.minute + plusMs, in: spans, windows: windows)?
            .segmentId
    }

    @Test func aTimeInsideOneRecordingPicksIt() {
        let spans = [Self.span("a", 0, 10), Self.span("b", 10, 20)]
        #expect(pick(5, spans) == "a")
        // Abutting: the boundary belongs to the one starting there.
        #expect(pick(10, spans) == "b")
    }

    @Test func overlappingRecordingsPickTheLatestStart() {
        let spans = [Self.span("a", 0, 30), Self.span("b", 20, 40), Self.span("c", 25, 26)]
        #expect(pick(22, spans) == "b")
        #expect(pick(25, spans, plusMs: 1) == "c")
        #expect(pick(27, spans) == "b")
        #expect(pick(10, spans) == "a")
    }

    @Test func aTieOnStartPrefersTheRecordingWithFrames() {
        let spans = [Self.span("a", 0, 10, frames: false), Self.span("b", 0, 10, frames: true)]
        #expect(pick(5, spans) == "b")
        #expect(pick(5, Array(spans.reversed())) == "b")
        // And with nothing else to choose by, the lower id — never the listing order.
        let twins = [Self.span("y", 0, 10), Self.span("x", 0, 10)]
        #expect(pick(5, twins) == "x")
        #expect(pick(5, Array(twins.reversed())) == "x")
    }

    @Test func aRecordingWithNoLengthHoldsItsInstant() {
        #expect(pick(7, [Self.span("p", 7, 7)]) == "p")
    }

    /// Between two recordings of one conversation (a reconnect): where the audio resumes.
    @Test func aGapInsideAConversationLandsWhereTheAudioResumes() {
        let spans = [
            Self.span("a", 0, 10), Self.span("b", 50, 60),
            // Another conversation's recording sitting in the gap is not this conversation's.
            Self.span("x", 30, 31, in: "c2"),
        ]
        let windows = [Self.window("c1", 0, 60), Self.window("c2", 30, 31)]
        #expect(pick(20, spans, windows) == "b")
        #expect(pick(40, spans, windows) == "b")
    }

    /// A conversation window can run past its last recording (a live one, a closing gap):
    /// nothing resumes, so the recording before the time.
    @Test func aGapAtTheEndOfAConversationLandsOnTheRecordingBefore() {
        let spans = [
            Self.span("a", 0, 10), Self.span("b", 12, 20), Self.span("n", 200, 210, in: "c2"),
        ]
        let windows = [Self.window("c1", 0, 60)]
        #expect(pick(40, spans, windows) == "b")
    }

    @Test func beforeEverythingLandsOnTheFirstRecordingOnlyWhenNear() {
        let spans = [Self.span("a", 100, 110), Self.span("b", 120, 130)]
        #expect(pick(90, spans) == "a")
        #expect(pick(71, spans) == "a")
        #expect(pick(69, spans) == nil)
    }

    @Test func afterEverythingLandsOnTheLastRecordingOnlyWhenNear() {
        let spans = [Self.span("a", 100, 110), Self.span("b", 120, 130)]
        #expect(pick(140, spans) == "b")
        #expect(pick(159, spans) == "b")
        #expect(pick(161, spans) == nil)
    }

    /// Between two conversations, the one that starts next wins over the one that ended.
    @Test func betweenConversationsPrefersWhatComesNext() {
        let spans = [Self.span("a", 0, 10, in: "c1"), Self.span("b", 25, 30, in: "c2")]
        let windows = [Self.window("c1", 0, 10), Self.window("c2", 25, 30)]
        #expect(pick(12, spans, windows) == "b")
        // More than half an hour to the next and within it of the last: the last.
        let far = [Self.span("a", 0, 10, in: "c1"), Self.span("b", 80, 90, in: "c2")]
        #expect(pick(20, far) == "a")
    }

    @Test func nothingRecordedResolvesToNothing() {
        #expect(pick(0, []) == nil)
        #expect(pick(0, [], [Self.window("c1", -10, 10)]) == nil)
    }

    @Test func theExtremesOfTheClockDoNotTrap() {
        let spans = [Self.span("a", 0, 10)]
        #expect(MomentResolver.segment(atWallMs: .max, in: spans, windows: []) == nil)
        #expect(MomentResolver.segment(atWallMs: .min, in: spans, windows: []) == nil)
    }
}

// MARK: - Topic-sized conversations: a moment belongs to the piece it falls in

/// A recording usually holds the end of one conversation and the start of the next, so which
/// conversation a moment opens is decided by WHERE in the recording it falls. The library is
/// `PieceLibrary`'s: two one-minute recordings shared by three conversations.
///
///     seg-a  |-- first ------------|-- second ---------------------|
///     seg-b  |-- second (cont.) ------------|-- third -------------|
@Suite("history moment: pieces") @MainActor
struct HistoryMomentPieceTests {
    typealias Library = PieceLibrary

    static func wall(_ segmentId: String, _ mediaMs: Int64) -> Int64 {
        // The fixture's recordings hold every millisecond of their wall span, so the two
        // clocks differ only by where the segment starts.
        ConversationGrouper.segmentStartMs(Library.metas[segmentId]!) + mediaMs
    }

    static func moment(_ wallMs: Int64, in db: AppDatabase, hiding hidden: Set<String> = [])
        async throws -> (segmentId: String, conversationId: String, mediaOffsetMs: Int64?)?
    {
        let queries = ConversationQueries(db: db)
        let spans = LiveWorld.momentSpans(
            Array(Library.metas.values), owners: try await queries.membersBySegment(), hiding: hidden)
        let windows = try await queries.rows(overlappingMs: wallMs..<(wallMs + 1))
            .filter { !hidden.contains($0.id) && $0.endMs > $0.startMs }
            .map { MomentResolver.Window(conversationId: $0.id, range: $0.startMs..<$0.endMs) }
        let resolved = await LiveWorld.momentPosition(
            atWallMs: wallMs, spans: spans, windows: windows, queries: queries,
            loadMetas: { ids in Library.metas.filter { ids.contains($0.key) } })
        return resolved.map {
            ($0.segment.segmentId, $0.position.detail.row.id, $0.position.mediaOffsetMs)
        }
    }

    /// Each side of a cut opens its own conversation, at its own place on THAT conversation's
    /// scrubber — the pieces before it, plus how far into its own piece the moment is.
    @Test func eachSideOfACutOpensItsOwnConversation() async throws {
        let db = try await Library.sharedLibrary()

        let early = try #require(try await Self.moment(Self.wall("seg-a", 10_000), in: db))
        #expect(early.segmentId == "seg-a")
        #expect(early.conversationId == Library.first)
        #expect(early.mediaOffsetMs == 10_000)

        // One millisecond either side of the cut in seg-a.
        let before = try #require(try await Self.moment(Self.wall("seg-a", Library.cutA - 1), in: db))
        #expect(before.conversationId == Library.first)
        let after = try #require(try await Self.moment(Self.wall("seg-a", Library.cutA), in: db))
        #expect(after.conversationId == Library.second)
        #expect(after.mediaOffsetMs == 0)

        let flying = try #require(try await Self.moment(Self.wall("seg-a", 50_000), in: db))
        #expect(flying.conversationId == Library.second)
        #expect(flying.mediaOffsetMs == 50_000 - Library.cutA)

        // seg-b: its first half continues the second conversation (after its 21.5 s of seg-a),
        // its second half is the third.
        let flights = try #require(try await Self.moment(Self.wall("seg-b", 1_000), in: db))
        #expect(flights.segmentId == "seg-b")
        #expect(flights.conversationId == Library.second)
        #expect(flights.mediaOffsetMs == 22_500)
        let costs = try #require(try await Self.moment(Self.wall("seg-b", 40_000), in: db))
        #expect(costs.conversationId == Library.third)
        #expect(costs.mediaOffsetMs == 40_000 - Library.cutB)
    }

    /// A moment and a citation of the same instant are the same hop, so they land together.
    @Test func aMomentAndACitationOfTheSameInstantAgree() async throws {
        let db = try await Library.sharedLibrary()
        let queries = ConversationQueries(db: db)
        for (segmentId, mediaMs) in [("seg-a", 5_000), ("seg-a", 45_000), ("seg-b", 3_000), ("seg-b", 50_000)] {
            let wallMs = Self.wall(segmentId, Int64(mediaMs))
            let moment = try #require(try await Self.moment(wallMs, in: db))
            let cited = try #require(
                await LiveWorld.citedPosition(
                    of: AskCitation(segmentId: segmentId, number: 1, startMs: wallMs, endMs: wallMs + 1_000),
                    queries: queries,
                    loadMetas: { ids in Library.metas.filter { ids.contains($0.key) } }))
            #expect(moment.conversationId == cited.detail.row.id)
            #expect(moment.mediaOffsetMs == cited.mediaOffsetMs)
        }
    }

    /// A conversation in its undo window is not a candidate: its recordings drop out of the
    /// spans only where nothing else holds a piece of them.
    @Test func aHiddenConversationsPiecesAreNotCandidates() async throws {
        let db = try await Library.sharedLibrary()
        let owners = try await ConversationQueries(db: db).membersBySegment()
        let all = LiveWorld.momentSpans(Array(Library.metas.values), owners: owners)
        #expect(all.map { "\($0.segmentId)/\($0.conversationId)" }.sorted() == [
            "seg-a/\(Library.first)", "seg-a/\(Library.second)",
            "seg-b/\(Library.second)", "seg-b/\(Library.third)",
        ])
        let hiding = LiveWorld.momentSpans(
            Array(Library.metas.values), owners: owners, hiding: [Library.second])
        #expect(hiding.map { "\($0.segmentId)/\($0.conversationId)" }.sorted() == [
            "seg-a/\(Library.first)", "seg-b/\(Library.third)",
        ])
    }
}

// MARK: - The mock stays usable

@Suite("history moment: the demo world") @MainActor
struct HistoryMomentMockTests {
    /// `-demo-data` and previews have to be able to open a moment too, and land on the moment
    /// style — never a citation band.
    @Test func aMomentInsideADemoConversationOpensItAtThatTime() async throws {
        let world = MockWorld.shared
        let display = try #require(try await world.display(id: "long-day"))
        let start = try #require(display.startedAt)
        let end = try #require(display.endedAt)
        let middle = Int64((start.timeIntervalSince1970 + end.timeIntervalSince(start) / 2) * 1000)

        let target = try #require(await world.momentTarget(atWallMs: middle))
        #expect(target.conversationId == "long-day")
        #expect(target.focus.style == .moment)
        #expect(target.focus.startMs == middle && target.focus.endMs == middle)
        let offset = try #require(target.mediaOffsetMs)
        let duration = try #require(display.player?.durationMs)
        #expect(abs(offset - duration / 2) <= 1)
    }
}
