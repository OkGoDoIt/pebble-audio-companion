import AppDB
import Foundation
import Intelligence
import SegmentStore
import Testing
import Transcription
import WireProtocol

@testable import CompanionRuntime

@Suite("audio content service")
struct AudioContentServiceTests {
    /// Mutable world the service reads through its closures.
    final class World: @unchecked Sendable {
        let lock = NSLock()
        var metas: [SegmentMeta] = []
        var turns: [String: [Transcription.TranscriptSegment]] = [:]
        var versions: [String: String] = [:]
        var versionReads = 0
        var timingReads = 0
    }

    static func meta(
        _ id: String, startMs: Int64, wallMs: Int64 = 600_000,
        state: TranscriptionState = .complete
    ) -> SegmentMeta {
        var meta = SegmentMeta(
            segmentId: id, streamId: 1, protocolVersion: 1, codecIdRaw: 1, channels: 1,
            frameSamples: 320, sampleRateHz: 16_000, bitRateBps: 9_800, frameDurationMs: 20,
            startTimeMs: UInt64(startMs), startMonotonicMs: 0, receivedAtMs: startMs + wallMs,
            firstSampleIndex: 0, lastSampleIndexExclusive: UInt64(wallMs) * 16,
            frameCount: wallMs / 20, gaps: [], closeReason: .rotated)
        meta.transcriptionState = state
        return meta
    }

    /// Ten minutes: five of talk, then five of nothing.
    static func talkThenQuiet(_ id: String) -> [Transcription.TranscriptSegment] {
        (0..<5).map { minute in
            Transcription.TranscriptSegment(
                text: (0..<100).map { "\(id)m\(minute)w\($0)" }.joined(separator: " "),
                startMs: Int64(minute) * 60_000, endMs: Int64(minute) * 60_000 + 55_000)
        }
    }

    private func service(
        _ world: World, db: AppDatabase,
        judge: (@Sendable (AiRunRequest) async throws -> RoutedAiResult)? = nil,
        now: Int64 = 1_000
    ) -> AudioContentService {
        AudioContentService(
            listSegments: { world.lock.withLock { world.metas } },
            speechTimingsOf: { id in
                world.lock.withLock {
                    world.timingReads += 1
                    return world.turns[id]
                }
            },
            transcriptVersionOf: { id in
                world.lock.withLock {
                    world.versionReads += 1
                    return world.versions[id] ?? "absent"
                }
            },
            store: AudioContentStore(db: db),
            nowMs: { now },
            judge: judge)
    }

    private func world(_ ids: [String]) -> World {
        let world = World()
        for (index, id) in ids.enumerated() {
            world.metas.append(Self.meta(id, startMs: 1_700_000_000_000 + Int64(index) * 600_000))
            world.turns[id] = Self.talkThenQuiet(id)
            world.versions[id] = "v1"
        }
        return world
    }

    @Test("a backfill runs newest first within its budget, then goes quiet and reads nothing")
    func backfillIsCappedAndThenIdle() async throws {
        let db = try AppDatabase.inMemory()
        let world = world(["a", "b", "c"])
        let service = service(world, db: db)
        #expect(try await service.classifyPass(budget: 2))
        let keys = try await AudioContentStore(db: db).inputKeys()
        #expect(Set(keys.keys) == ["b", "c"])  // newest two
        #expect(try await service.classifyPass(budget: 2))
        #expect(try await AudioContentStore(db: db).inputKeys().count == 3)
        // Steady state: nothing written, and not one transcript stat'd or read.
        let (stats, reads) = world.lock.withLock { (world.versionReads, world.timingReads) }
        #expect(try await service.classifyPass(budget: 2) == false)
        #expect(world.lock.withLock { (world.versionReads, world.timingReads) } == (stats, reads))
        // A fresh service over the same database knows what is done without reading transcripts.
        let restarted = self.service(world, db: db)
        let readsBefore = world.lock.withLock { world.timingReads }
        #expect(try await restarted.classifyPass(budget: 10) == false)
        #expect(world.lock.withLock { world.timingReads } == readsBefore)
    }

    @Test("a segment is classified when it settles, and again when its transcript changes")
    func reclassifiesOnChange() async throws {
        let db = try AppDatabase.inMemory()
        let world = world(["a"])
        world.metas[0].transcriptionState = .pending
        let service = service(world, db: db)
        #expect(try await service.classifyPass() == false)
        #expect(try await AudioContentStore(db: db).inputKeys().isEmpty)

        world.lock.withLock { world.metas[0].transcriptionState = .complete }
        #expect(try await service.classifyPass())
        let before = try await AudioContentStore(db: db).spans(segmentId: "a")
        #expect(before.map(\.kind) == [.conversation, .noConversation])

        // Re-transcribed: pending, then complete again with a new file that has talk throughout.
        world.lock.withLock {
            world.metas[0].transcriptionState = .pending
        }
        _ = try await service.classifyPass()
        world.lock.withLock {
            world.metas[0].transcriptionState = .complete
            world.versions["a"] = "v2"
            world.turns["a"] = (0..<10).map { minute in
                Transcription.TranscriptSegment(
                    text: (0..<80).map { "r\(minute)w\($0)" }.joined(separator: " "),
                    startMs: Int64(minute) * 60_000, endMs: Int64(minute) * 60_000 + 55_000)
            }
        }
        #expect(try await service.classifyPass())
        #expect(try await AudioContentStore(db: db).spans(segmentId: "a").map(\.kind) == [.conversation])
    }

    /// A range delete takes words out of a transcript without moving the segment's state, which
    /// is the one change a pass cannot see by itself.
    @Test("a segment whose audio was rewritten is classified again, and a correction inside the deleted stretch goes")
    func rewrittenAudioIsReclassified() async throws {
        let db = try AppDatabase.inMemory()
        let store = AudioContentStore(db: db)
        let world = world(["a"])
        let service = service(world, db: db)
        #expect(try await service.classifyPass())
        #expect(try await store.spans(segmentId: "a").map(\.kind) == [.conversation, .noConversation])
        let start = world.metas[0].startWallMs
        let inside = try await service.correct(
            startMs: start + 60_000, endMs: start + 120_000, kind: .noConversation)
        let straddling = try await service.correct(
            startMs: start + 240_000, endMs: start + 360_000, kind: .noConversation)
        #expect(service.mask.aiRanges("a") == [60_000..<120_000, 240_000..<360_000])

        // The first five minutes — all of the talk — are deleted: the transcript is rewritten,
        // the state stays `.complete`.
        world.lock.withLock {
            world.turns["a"] = []
            world.versions["a"] = "v2"
        }
        // Untold, the pass sees a segment whose state has not moved and looks no further.
        #expect(try await service.classifyPass() == false)

        await service.audioRewritten(segment: world.metas[0], mediaRangeMs: 0..<300_000)

        // The correction that was only about deleted audio is gone, at once; the one that
        // also covers what is left stays.
        let corrections = try await store.overrides(overlappingMs: start..<(start + 600_000))
        #expect(!corrections.contains(inside))
        #expect(corrections.contains(straddling))
        #expect(service.mask.aiRanges("a") == [240_000..<360_000])
        // And the next pass reads the transcript as it now is.
        #expect(try await service.classifyPass())
        #expect(try await store.spans(segmentId: "a").allSatisfy { $0.kind == .noConversation })
    }

    @Test("a correction masks the model input of exactly the stretch it covers, and undoes cleanly")
    func correctionMasksModelInput() async throws {
        let db = try AppDatabase.inMemory()
        let world = world(["a"])
        let service = service(world, db: db)
        _ = try await service.classifyPass()
        let mask = service.mask
        #expect(mask.aiRanges("a").isEmpty)
        #expect(mask.aiGeneration("a") == 0)

        // "Minutes 1-3 were the TV, not a conversation."
        let start = world.metas[0].startWallMs
        let correction = try await service.correct(
            startMs: start + 60_000, endMs: start + 180_000, kind: .noConversation)
        #expect(mask.aiRanges("a") == [60_000..<180_000])
        #expect(mask.speechRanges("a") == [60_000..<180_000])
        let generation = mask.aiGeneration("a")
        #expect(generation > 0)
        let spans = try await AudioContentStore(db: db).spans(overlappingMs: start..<(start + 600_000))
        #expect(spans.map(\.decidedBy) == ["wordRate", "user", "wordRate", "wordRate"])

        try await service.undoCorrection(correction)
        #expect(mask.aiRanges("a").isEmpty)
        #expect(mask.aiGeneration("a") > generation)
    }

    @Test("a loop is withheld from speech evidence but not from the models, which collapse it")
    func loopMasksSpeechOnly() async throws {
        let db = try AppDatabase.inMemory()
        let world = World()
        world.metas = [Self.meta("a", startMs: 1_700_000_000_000, wallMs: 300_000)]
        world.versions["a"] = "v1"
        world.turns["a"] = (0..<3).map { minute in
            Transcription.TranscriptSegment(
                text: Array(repeating: "Yeah.", count: 400).joined(separator: " "),
                startMs: Int64(minute) * 60_000, endMs: Int64(minute) * 60_000 + 60_000)
        }
        let service = service(world, db: db)
        _ = try await service.classifyPass()
        #expect(service.mask.speechRanges("a") == [0..<180_000])
        #expect(service.mask.aiRanges("a").isEmpty)
    }

    @Test("deleting a segment forgets its spans and the corrections that were only about it")
    func forgetCascades() async throws {
        let db = try AppDatabase.inMemory()
        let world = world(["a", "b"])
        let service = service(world, db: db)
        _ = try await service.classifyPass()
        let a = world.metas[0], b = world.metas[1]
        let inside = try await service.correct(
            startMs: a.startWallMs + 60_000, endMs: a.startWallMs + 120_000, kind: .noConversation)
        let across = try await service.correct(
            startMs: a.startWallMs + 500_000, endMs: b.startWallMs + 60_000, kind: .noConversation)
        await service.forget(segment: a)
        world.lock.withLock { world.metas.removeAll { $0.segmentId == "a" } }
        let store = AudioContentStore(db: db)
        #expect(try await store.spans(segmentId: "a").isEmpty)
        let left = try await store.overrides(overlappingMs: 0..<Int64.max).map(\.id)
        #expect(left == [across.id])
        #expect(!left.contains(inside.id))
        #expect(service.mask.aiRanges("a").isEmpty)

        // A segment that vanishes without the cascade (a copied-in library) is swept too.
        world.lock.withLock { world.metas.removeAll { $0.segmentId == "b" } }
        _ = try await service.classifyPass()
        #expect(try await store.inputKeys().isEmpty)
    }

    final class Judge: @unchecked Sendable {
        let lock = NSLock()
        var calls = 0
        var reply = #"{"minutes":[{"m":0,"kind":"conversation","confidence":0.99},{"m":1,"kind":"music","confidence":0.97},{"m":2,"kind":"music","confidence":0.95}]}"#
        var error: Error?
        func run(_ request: AiRunRequest) async throws -> RoutedAiResult {
            let (reply, error) = lock.withLock { () -> (String, Error?) in
                calls += 1
                return (self.reply, self.error)
            }
            if let error { throw error }
            return RoutedAiResult(
                text: reply, modeUsed: .remoteFirst, providerId: "openai", modelUsed: "gpt-5.6-luna",
                inputTokens: 100, outputTokens: 20)
        }
    }

    @Test("an AI reading lands, reclassifies the segment, and withholds the lyrics from the models")
    func judgedLyricsAreWithheld() async throws {
        let db = try AppDatabase.inMemory()
        let world = world(["a"])
        let judge = Judge()
        let now = world.metas[0].startWallMs + 3_600_000
        let service = service(world, db: db, judge: { try await judge.run($0) }, now: now)
        _ = try await service.classifyPass()
        #expect(service.mask.aiRanges("a").isEmpty)

        #expect(try await service.judgePass(allowBackfill: false))
        #expect(judge.lock.withLock { judge.calls } == 1)
        #expect(try await service.classifyPass())
        let spans = try await AudioContentStore(db: db).spans(segmentId: "a")
        #expect(spans.map(\.decidedBy).contains(AudioContentDecider.contentJudge))
        #expect(spans.first { $0.decidedBy == AudioContentDecider.contentJudge }?.descriptor == "music")
        // Minutes 1-2 were lyrics: withheld from the models and from speech evidence.
        #expect(service.mask.aiRanges("a") == [60_000..<180_000])
        #expect(service.mask.speechRanges("a") == [60_000..<180_000])
        // Read once per transcript: nothing more to ask.
        #expect(try await service.judgePass(allowBackfill: false) == false)
        #expect(judge.lock.withLock { judge.calls } == 1)
        let stored = try await AudioContentStore(db: db).judgements()["a"]
        #expect(stored?.model == "gpt-5.6-luna" && stored?.minutes?.count == 3)
    }

    @Test("the backlog waits for the charger; no AI means nothing owed; a failure backs off")
    func judgeGating() async throws {
        let db = try AppDatabase.inMemory()
        let world = world(["old"])
        let judge = Judge()
        // Two days later: backlog.
        let now = world.metas[0].startWallMs + 48 * 3_600_000
        let service = service(world, db: db, judge: { try await judge.run($0) }, now: now)
        _ = try await service.classifyPass()
        #expect(try await service.judgePass(allowBackfill: false) == false)
        #expect(judge.lock.withLock { judge.calls } == 0)

        judge.lock.withLock { judge.error = AiError.providerUnavailable(providerId: "openai") }
        #expect(try await service.judgePass(allowBackfill: true) == false)
        #expect(try await AudioContentStore(db: db).judgements().isEmpty)

        judge.lock.withLock { judge.error = AiError.providerFailed("HTTP 500") }
        #expect(try await service.judgePass(allowBackfill: true) == false)
        let failed = try #require(try await AudioContentStore(db: db).judgements()["old"])
        #expect(failed.attempts == 1 && failed.minutes == nil && (failed.nextAttemptAtMs ?? 0) > now)
        // Inside the backoff: not asked again.
        let calls = judge.lock.withLock { judge.calls }
        #expect(try await service.judgePass(allowBackfill: true) == false)
        #expect(judge.lock.withLock { judge.calls } == calls)
    }
}
