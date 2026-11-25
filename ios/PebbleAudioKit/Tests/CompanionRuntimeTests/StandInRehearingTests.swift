import Foundation
import GRDB
import SearchKit
import SegmentStore
import Testing
import Transcription

@testable import AppDB
@testable import CompanionRuntime

/// What the phone transcribed while the cloud account was refusing work is heard by the cloud once
/// the account works again: once, without losing anything meanwhile, and never by the phone again.
@Suite struct StandInRehearingTests {
    private static let day = Int64(1_795_400_000_000)  // 2026-11-23

    /// The phone: a few words, or nothing.
    private final class Phone: TranscriptionProvider, @unchecked Sendable {
        let id = "speechanalyzer"
        private let lock = NSLock()
        private var count = 0
        private var silent = false
        var calls: Int { lock.withLock { count } }
        func hearNothing(_ on: Bool) { lock.withLock { silent = on } }
        func isAvailable() async -> Bool { true }
        func transcribe(
            pcmChunks: AsyncThrowingStream<Data, Error>, sampleRateHz: Int
        ) async throws -> TranscriptionResult {
            let silent = lock.withLock { () -> Bool in
                count += 1
                return self.silent
            }
            if silent {
                throw TranscriptionError.noSpeechDetected("SpeechAnalyzer produced no speech")
            }
            return TranscriptionResult(text: "few words", providerId: id, modelUsed: "apple")
        }
    }

    private final class Account: TranscriptionProvider, @unchecked Sendable {
        let id = "soniox"
        func isAvailable() async -> Bool { true }
        func transcribe(
            pcmChunks: AsyncThrowingStream<Data, Error>, sampleRateHz: Int
        ) async throws -> TranscriptionResult {
            TranscriptionResult(text: "cloud", providerId: id, modelUsed: "v6")
        }
    }

    /// What the cloud answers to a hearing, and what it was sent.
    private final class Ear: @unchecked Sendable {
        private let lock = NSLock()
        private var sends: [String] = []
        private var answers: [String: Error] = [:]
        private var everything: Error?
        var sent: [String] { lock.withLock { sends } }
        func answer(_ id: String, _ error: Error?) { lock.withLock { answers[id] = error } }
        func answerAll(_ error: Error?) { lock.withLock { everything = error } }
        func hear(_ id: String) throws -> TranscriptionResult {
            let error = lock.withLock { () -> Error? in
                sends.append(id)
                return answers[id] ?? everything
            }
            if let error { throw error }
            return TranscriptionResult(
                text: "every word of \(id)", providerId: "soniox", modelUsed: "v6",
                segments: [TranscriptSegment(text: "every word of \(id)", startMs: 0, endMs: 100)])
        }
    }

    private struct Rig {
        let fixture: RuntimeFixture
        let hold: CloudAccountHold
        let phone: Phone
        let ear: Ear
        let cloud: SelectableCloudTranscriptionProvider
        let settings: RuntimeSettingsBox

        var queue: TranscriptionQueue { fixture.queue }
        var transcripts: FileTranscriptStore { fixture.transcriptStore }

        /// A process: everything in memory is new, everything durable is the fixture's.
        func launch() -> (service: TranscriptionService, rehearing: StandInRehearing) {
            let clock = fixture.clock
            let store = fixture.store
            let ear = self.ear
            let rehearing = StandInRehearing(
                queue: queue, transcripts: transcripts, store: store, database: fixture.database,
                cloud: cloud, settings: settings, clock: clock,
                send: { id, _ in try ear.hear(id) })
            let settings = self.settings
            let processor = TranscriptionProcessor(
                queue: queue,
                router: TranscriptionModeRouter(
                    local: phone, remote: cloud, mode: { settings.transcriptionMode }),
                pcmSource: { _ in AsyncThrowingStream { $0.finish() } },
                transcriptStore: transcripts, silenceFloorRms: nil)
            let service = TranscriptionService(
                queue: queue, processor: processor, transcriptStore: transcripts, store: store,
                database: fixture.database, settings: settings, clock: clock,
                cloudAccounts: cloud, rehearing: rehearing)
            return (service, rehearing)
        }

        /// A recording the phone settled during the outage, its sidecar mirrored as the app does.
        func record(_ index: Int, silent: Bool = false, dayOffset: Int = 0) async throws -> String {
            let start =
                StandInRehearingTests.day + Int64(dayOffset) * 86_400_000 + Int64(index) * 60_000
            let id = try await Fixture.writeSegment(
                into: fixture.store, streamId: UInt32(1000 + index + dayOffset * 100),
                startTimeMs: UInt64(start), receivedAtMs: start)
            try queue.enqueue(id, createdAtMs: start)
            phone.hearNothing(silent)
            _ = try await launch().service.drainQueue()
            phone.hearNothing(false)
            try await fixture.store.updateTranscriptionState(id, silent ? .noSpeech : .complete)
            await fixture.clock.advance(by: 10)
            return id
        }
    }

    private func rig(mode: TranscriptionMode = .remoteFirst, uploadAllowed: Bool = true) async throws
        -> Rig
    {
        let fixture = try RuntimeFixture()
        let clock = fixture.clock
        await clock.advance(by: Self.day + 3 * 86_400_000)
        let hold = CloudAccountHold(
            fileURL: nil, apiKey: { _ in "key" }, nowMs: { clock.nowMs })
        let cloud = SelectableCloudTranscriptionProvider(
            selected: { .soniox }, openAi: Account(), soniox: Account(), hold: hold,
            uploadAllowedNow: { uploadAllowed })
        hold.trip(.accountOutOfFunds, provider: .soniox)
        return Rig(
            fixture: fixture, hold: hold, phone: Phone(), ear: Ear(), cloud: cloud,
            settings: RuntimeSettingsBox(
                RuntimeSettingsSnapshot(
                    captureIntent: .active, transcriptionMode: mode,
                    cloudTranscriptionProvider: .soniox)))
    }

    private func refused() -> TranscriptionError {
        .transcriptionFailed("Soniox create transcription failed (402): balance exhausted")
    }

    @Test func theHoldLiftsAndWhatThePhoneDidIsHeardOnce() async throws {
        let rig = try await rig()
        let words = try await rig.record(0)
        let nothing = try await rig.record(1, silent: true)
        let silence = try await rig.record(2)
        try rig.queue.markNoSpeech(silence, decidedBy: "silence floor: loudest second -70 dBFS")
        #expect(try rig.queue.load(words)?.standInFor == "soniox: accountOutOfFunds")
        #expect(try rig.queue.load(nothing)?.standInFor == "soniox: accountOutOfFunds")
        #expect(try rig.queue.load(silence)?.standInFor == nil)

        // Still refused: nothing is sent, and the phone is not asked a second time.
        let phoneCalls = rig.phone.calls
        let first = rig.launch()
        _ = try await first.service.drainQueue()
        #expect(rig.ear.sent.isEmpty)

        rig.hold.noteSuccess(provider: .soniox)
        #expect(try await first.service.drainQueue())
        #expect(Set(rig.ear.sent) == [words, nothing])
        #expect(rig.phone.calls == phoneCalls)
        for id in [words, nothing] {
            let task = try rig.queue.load(id)
            #expect(task?.state == .complete)
            #expect(task?.providerId == "soniox")
            #expect(task?.standInFor == nil)
            #expect(task?.lastError == nil)
            #expect(rig.transcripts.load(id)?.text == "every word of \(id)")
            #expect(await rig.fixture.store.readMeta(id)?.transcriptionState == .complete)
            #expect(rig.transcripts.loadReheard(id) == nil)
        }
        #expect(try rig.queue.load(silence)?.state == .noSpeech)
        #expect(Set(await first.service.takeReplacedTranscripts()) == [words, nothing])

        // Not again: not by this process, and not by the next.
        _ = try await first.service.drainQueue()
        _ = try await rig.launch().service.drainQueue()
        #expect(rig.ear.sent.count == 2)
    }

    /// Nothing moves until the whole day has been heard: the words on screen stay, and a relaunch
    /// in the middle neither loses what was heard nor pays for it again.
    @Test func aDayIsReplacedAtOnceAndSurvivesARelaunch() async throws {
        let rig = try await rig()
        var ids: [String] = []
        for index in 0..<6 { ids.append(try await rig.record(index)) }
        let older = try await rig.record(0, dayOffset: -1)
        rig.hold.noteSuccess(provider: .soniox)

        _ = try await rig.launch().service.drainQueue()
        #expect(rig.ear.sent.count == 4)
        for id in ids {
            #expect(try rig.queue.load(id)?.state == .complete)
            #expect(rig.transcripts.load(id)?.text == "few words")
        }

        _ = try await rig.launch().service.drainQueue()
        #expect(Set(rig.ear.sent) == Set(ids))
        #expect(rig.ear.sent.count == 6)
        for id in ids { #expect(rig.transcripts.load(id)?.text == "every word of \(id)") }
        #expect(rig.transcripts.load(older)?.text == "few words", "the newest day first")

        _ = try await rig.launch().service.drainQueue()
        #expect(rig.transcripts.load(older)?.text == "every word of \(older)")
    }

    /// The money runs out again part-way: what was paid for is used, the rest keep their transcripts
    /// and their place, and the phone does not transcribe them a second time.
    @Test func aSecondRefusalKeepsWhatItHas() async throws {
        let rig = try await rig()
        let heard = try await rig.record(0)
        let unheard = try await rig.record(1)
        rig.hold.noteSuccess(provider: .soniox)
        rig.ear.answer(unheard, refused())
        let phoneCalls = rig.phone.calls
        let process = rig.launch()

        _ = try await process.service.drainQueue()
        #expect(rig.hold.active(for: .soniox) != nil)
        _ = try await process.service.drainQueue()
        #expect(rig.transcripts.load(heard)?.text == "every word of \(heard)")
        let kept = try rig.queue.load(unheard)
        #expect(kept?.state == .complete)
        #expect(kept?.standInFor == "soniox: accountOutOfFunds")
        #expect(kept?.rehearAttempts == 0, "an account's refusal is not an attempt")
        #expect(rig.transcripts.load(unheard)?.text == "few words")
        #expect(rig.phone.calls == phoneCalls)

        rig.hold.noteSuccess(provider: .soniox)
        rig.ear.answer(unheard, nil)
        await rig.fixture.clock.advance(by: StandInRehearing.networkPauseMs)
        _ = try await process.service.drainQueue()
        #expect(rig.transcripts.load(unheard)?.text == "every word of \(unheard)")
    }

    /// A recording the cloud cannot do is not paid for forever, whatever is relaunched; the rest of
    /// its day does not wait for it.
    @Test func aRecordingTheCloudCannotDoIsSentThreeTimes() async throws {
        let rig = try await rig()
        let bad = try await rig.record(0)
        let good = try await rig.record(1)
        rig.hold.noteSuccess(provider: .soniox)
        rig.ear.answer(bad, TranscriptionError.transcriptionFailed("Soniox job error: bad audio"))
        for _ in 0..<6 {
            _ = try await rig.launch().service.drainQueue()
            await rig.fixture.clock.advance(by: 60 * 60_000)
        }
        #expect(rig.ear.sent.filter { $0 == bad }.count == StandInRehearing.maxAttempts)
        #expect(rig.ear.sent.filter { $0 == good }.count == 1)
        #expect(rig.transcripts.load(good)?.text == "every word of \(good)")
        #expect(rig.transcripts.load(bad)?.text == "few words")
        #expect(try rig.queue.load(bad)?.state == .complete)
    }

    @Test func nothingIsSentInALocalModeOrOnANetworkThatIsNotAllowed() async throws {
        let local = try await rig()
        _ = try await local.record(0)
        local.hold.noteSuccess(provider: .soniox)
        local.settings.apply { $0.transcriptionMode = .localFirst }
        _ = try await local.launch().service.drainQueue()
        #expect(local.ear.sent.isEmpty)

        let cellular = try await rig(uploadAllowed: false)
        _ = try await cellular.record(0)
        cellular.hold.noteSuccess(provider: .soniox)
        _ = try await cellular.launch().service.drainQueue()
        #expect(cellular.ear.sent.isEmpty)
    }

    /// A fallback for any other reason is the ordinary first-mode behavior, not an outage.
    @Test func beingOffWifiIsNotAnOutage() async throws {
        let rig = try await rig(uploadAllowed: false)
        rig.hold.noteSuccess(provider: .soniox)
        let id = try await rig.record(0)
        #expect(rig.phone.calls == 1)
        #expect(try rig.queue.load(id)?.standInFor == nil)
    }

    @Test func theCloudHearingNothingKeepsTheWordsThereAre() async throws {
        let rig = try await rig()
        let words = try await rig.record(0)
        let nothing = try await rig.record(1, silent: true)
        rig.hold.noteSuccess(provider: .soniox)
        rig.ear.answerAll(TranscriptionError.noSpeechDetected("Soniox returned no speech"))
        _ = try await rig.launch().service.drainQueue()
        #expect(try rig.queue.load(words)?.state == .complete)
        #expect(rig.transcripts.load(words)?.text == "few words")
        #expect(try rig.queue.load(nothing)?.state == .noSpeech)
        #expect(
            try rig.queue.load(nothing)?.lastError == "no speech - Soniox: Soniox returned no speech")
        #expect(try rig.queue.standIns().isEmpty)
    }

    /// Between being heard and being applied: transcribed again by the person, or partly deleted.
    @Test func aWaitingResultIsOnlyUsedForWhatItWasMadeFrom() async throws {
        let rig = try await rig()
        var ids: [String] = []
        for index in 0..<5 { ids.append(try await rig.record(index)) }
        rig.hold.noteSuccess(provider: .soniox)
        let process = rig.launch()
        _ = try await process.service.drainQueue()
        let waiting = rig.ear.sent
        #expect(waiting.count == 4)

        let redone = waiting[0]
        let cut = waiting[1]
        try rig.queue.requeue(redone)
        try rig.queue.markComplete(
            redone,
            result: RoutedTranscription(
                text: "redone", modeUsed: .remoteFirst, providerId: "soniox", modelUsed: nil))
        try await process.service.redactTranscript(cut, mediaRangeMs: 0..<100)
        #expect(rig.transcripts.loadReheard(cut) == nil)

        for _ in 0..<3 { _ = try await process.service.drainQueue() }
        #expect(rig.transcripts.load(redone)?.text == "few words", "the queue's own transcript stands")
        #expect(rig.ear.sent.filter { $0 == redone }.count == 1)
        #expect(rig.ear.sent.filter { $0 == cut }.count == 2, "heard again from what is left")
        #expect(
            rig.transcripts.load(cut)?.segments.isEmpty == true, "and the deletion still applies")
        #expect(try rig.queue.standIns().isEmpty)
    }

    /// What was made from the old words is owed a rewrite; what the person made stays.
    @Test func derivedWorkIsOwedAndThePersonsOwnStays() async throws {
        let rig = try await rig()
        let id = try await rig.record(0)
        let enrichment = rig.fixture.enrichment
        let conversation = try #require(try await enrichment.regroup().first?.id)
        try await rig.fixture.annotations.setUserTitle("My title", conversationId: conversation)
        try await rig.fixture.database.writer.write { db in
            try db.execute(
                sql: "UPDATE annotations SET isFinal = 1, summary = 'old' WHERE conversationId = ?",
                arguments: [conversation])
            try db.execute(
                sql: """
                    INSERT INTO recaps (dateKey, text, segmentIds, updatedAtMs)
                    VALUES ('2026-11-23', 'day', ?, 1)
                    """, arguments: ["[\"\(id)\",\"other\"]"])
            try db.execute(sql: "UPDATE sync_outbox_state SET active = 1")
            try db.execute(sql: "DELETE FROM sync_outbox")
        }
        rig.hold.noteSuccess(provider: .soniox)
        let process = rig.launch()
        _ = try await process.service.drainQueue()
        await enrichment.transcriptsReplaced(await process.service.takeReplacedTranscripts())
        _ = try await enrichment.regroupPass()

        try await rig.fixture.database.reader.read { db in
            let row = try #require(
                try Row.fetchOne(
                    db, sql: "SELECT title, isFinal FROM annotations WHERE conversationId = ?",
                    arguments: [conversation]))
            #expect(row["title"] as String? == "My title")
            #expect(row["isFinal"] as Bool == false)
            #expect(
                try String.fetchOne(db, sql: "SELECT segmentIds FROM recaps") == "[\"other\"]")
            #expect(
                try String.fetchAll(db, sql: "SELECT entityId FROM sync_outbox WHERE kind = 'transcript'")
                    == [conversation])
        }
        let indexed = rig.fixture.index.fullText(id: conversation, kind: .conversation) ?? ""
        #expect(indexed.contains("every word"))
    }

    /// The outage that was already in the data when this shipped.
    @Test func theOutageAlreadyInTheDataIsMarkedExactly() async throws {
        let database = try AppDatabase.inMemory()
        let during = 1_795_400_000_000
        let rows: [(String, String, String?, String?, String?, Int)] = [
            ("words", "Complete", "speechanalyzer", "LocalOnly", nil, during),
            ("nothing", "NoSpeech", nil, nil, "no speech - speechanalyzer: none", during),
            ("silence", "NoSpeech", nil, nil, "no speech - silence floor: -70 dBFS", during),
            ("cloud", "Complete", "soniox", "RemoteFirst", nil, during),
            ("before", "Complete", "speechanalyzer", "LocalOnly", nil, 1_795_360_000_000),
            ("after", "Complete", "speechanalyzer", "LocalOnly", nil, 1_795_590_000_000),
        ]
        try await database.writer.write { db in
            for row in rows {
                try db.execute(
                    sql: """
                        INSERT INTO transcription_tasks
                            (segmentId, state, createdAtMs, updatedAtMs, providerId, modeUsed, lastError)
                        VALUES (?, ?, 1, ?, ?, ?, ?)
                        """, arguments: [row.0, row.1, row.5, row.2, row.3, row.4])
            }
            try TranscriptReplacement.installStandIns(db)
        }
        let queue = TranscriptionQueue(database: database, nowMs: { 0 })
        #expect(Set(try queue.standIns().map(\.segmentId)) == ["words", "nothing"])
    }

    private final class Wire: HttpTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [HttpTransportRequest] = []
        var requests: [HttpTransportRequest] { lock.withLock { seen } }
        func execute(_ request: HttpTransportRequest) async throws -> HttpTransportResponse {
            lock.withLock { seen.append(request) }
            return HttpTransportResponse(status: 200, text: "heard")
        }
    }

    /// The watch's own frames, marked as audio so "Upload Audio" applies to them.
    @Test func aHearingSendsTheWatchsOwnFramesAsAudio() async throws {
        let fixture = try RuntimeFixture()
        let id = try await Fixture.writeSegment(into: fixture.store)
        let wire = Wire()
        let send = BackgroundUploadWiring.rehear(
            cloud: SelectableCloudTranscriptionProvider(
                selected: { .soniox }, openAi: Account(), soniox: FakeCloudUploadBackend()),
            files: SegmentFileReader(root: fixture.root),
            transport: wire)
        let result = try await send(id, .soniox)
        #expect(result.text == "heard")
        let request = try #require(wire.requests.first)
        #expect(request.carriesAudio)
        #expect(request.method == "POST")
        #expect(request.body.map { $0.range(of: Data("OggS".utf8)) != nil } == true)
    }
}
