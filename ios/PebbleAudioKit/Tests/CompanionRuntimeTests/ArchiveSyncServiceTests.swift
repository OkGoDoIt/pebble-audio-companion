import AppDB
import Foundation
import Testing

@testable import CompanionRuntime

// The archive sync's pass against a fake server: what it sends, what the answer clears, and that
// a pass with nothing to send sends nothing.

final class ArchiveFakeHTTP: ArchiveHTTP, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { _requests } }

    func send(_ request: URLRequest) async throws -> ArchiveHTTPResponse {
        lock.withLock { _requests.append(request) }
        if request.url?.path == "/sync/requests" {
            return ArchiveHTTPResponse(status: 200, body: Data("{\"requests\":[]}".utf8))
        }
        return ArchiveHTTPResponse(status: 200, body: Data("{}".utf8))
    }
}

/// Answers each upload at once with `answer(body)`, the way the background session delivers an
/// outcome on its own queue.
final class ArchiveFakeUploads: ArchiveUploading, @unchecked Sendable {
    let outcomes: AsyncStream<ArchiveUploadOutcome>
    private let continuation: AsyncStream<ArchiveUploadOutcome>.Continuation
    private let lock = NSLock()
    private var _bodies: [Data] = []
    private var _requests: [URLRequest] = []
    var answer: @Sendable (Data) -> (Int, Data)

    var bodies: [Data] { lock.withLock { _bodies } }
    var requests: [URLRequest] { lock.withLock { _requests } }

    init(answer: @escaping @Sendable (Data) -> (Int, Data)) {
        (outcomes, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        self.answer = answer
    }

    /// While true, an upload stays in flight until `cancel` (a slow network under Delete All).
    var holds = false
    private var _held: [String: Data] = [:]
    private var _cancelled: [String] = []
    var cancelled: [String] { lock.withLock { _cancelled } }

    func upload(_ request: URLRequest, fromFile file: URL, description: String) async {
        let body = (try? Data(contentsOf: file)) ?? Data()
        let hold = lock.withLock { () -> Bool in
            _bodies.append(body)
            _requests.append(request)
            if holds { _held[description] = body }
            return holds
        }
        guard !hold else { return }
        let (status, response) = answer(body)
        continuation.yield(ArchiveUploadOutcome(description: description, status: status, body: response))
    }

    func inFlight() async -> Set<String> { lock.withLock { Set(_held.keys) } }
    func reconnect() async {}

    func cancel(descriptionsWithPrefix prefix: String) async {
        let gone = lock.withLock { () -> [String] in
            let matching = _held.keys.filter { $0.hasPrefix(prefix) }
            for key in matching { _held[key] = nil }
            _cancelled += matching
            return matching
        }
        for description in gone {
            continuation.yield(
                ArchiveUploadOutcome(description: description, status: 0, body: Data(), error: "cancelled"))
        }
    }
}

/// Accepts every item of a batch.
private func acceptAll(_ body: Data) -> (Int, Data) {
    let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    let items = (json?["items"] as? [[String: Any]] ?? []).map {
        ["kind": $0["kind"] ?? "", "id": $0["id"] ?? "", "version": $0["version"] ?? 0]
    }
    let answer: [String: Any] = [
        "serverTime": "2026-10-20T00:00:00.000Z", "accepted": items, "ignored": [],
        "rejected": [], "pendingRequests": 0,
    ]
    return (200, (try? JSONSerialization.data(withJSONObject: answer)) ?? Data())
}

@Suite("archive sync service")
struct ArchiveSyncServiceTests {
    struct World {
        var db: AppDatabase
        var outbox: ArchiveOutbox
        var http: ArchiveFakeHTTP
        var uploads: ArchiveFakeUploads
        var service: ArchiveSyncService
        var directory: URL
    }

    /// `before` runs on the database and the service's directory before the service starts:
    /// the library and saved state an earlier release left behind.
    fileprivate func world(
        answer: @escaping @Sendable (Data) -> (Int, Data) = acceptAll,
        starts: Bool = true,
        before: (AppDatabase, URL) async throws -> Void = { _, _ in }
    ) async throws -> World {
        let db = try AppDatabase.inMemory()
        let outbox = ArchiveOutbox(db: db)
        let clock = TestClock()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-sync-\(UUID().uuidString)", isDirectory: true)
        try await before(db, directory)
        let builder = ArchivePayloadBuilder(
            sources: .init(
                database: db, readMeta: { _ in nil }, listSegments: { [] },
                transcript: { _ in nil }, transcriptVersion: { _ in "absent" },
                nowMs: { clock.nowMs }))
        let http = ArchiveFakeHTTP()
        let uploads = ArchiveFakeUploads(answer: answer)
        let service = ArchiveSyncService(
            .init(
                outbox: outbox, builder: builder,
                requests: ArchiveRequestHandler(
                    sources: .init(
                        builder: builder, readFrames: { _ in [] }, temporaryDirectory: directory,
                        nowMs: { clock.nowMs })),
                http: http, uploads: uploads,
                settings: {
                    ArchiveSyncSettings(
                        origin: "https://pebbleaudio.okgodoit.com", deviceId: "dev-1", enabled: true)
                },
                token: { "pad_test" }, directory: directory, clock: clock,
                isForeground: { true }, isCharging: { false }))
        if starts { await service.start() }
        return World(
            db: db, outbox: outbox, http: http, uploads: uploads, service: service,
            directory: directory)
    }

    @Test func aChangeIsSentOnceAndItsAnswerClearsIt() async throws {
        let w = try await world()
        // Starting a linked service sends the whole library: here, one follow-up.
        let item = try await FollowUpStore(db: w.db).add(text: "Call the landlord")
        await w.service.pass(.userAsked)

        let body = try #require(w.uploads.bodies.first)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["deviceId"] as? String == "dev-1")
        let items = try #require(json["items"] as? [[String: Any]])
        #expect(items.count == 1)
        #expect(items[0]["kind"] as? String == "followUp" && items[0]["id"] as? String == item.id)
        #expect((items[0]["payload"] as? [String: Any])?["text"] as? String == "Call the landlord")
        let request = try #require(w.uploads.requests.first)
        #expect(request.httpMethod == "PUT" && request.url?.path == "/sync/batch")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer pad_test")
        #expect(request.value(forHTTPHeaderField: "X-Sync-Protocol") == "1")

        #expect(try await w.outbox.counts().pending == 0)
        #expect(w.service.status.value.lastBatchAtMs != nil)

        // Nothing changed since: the pipeline's hook sends nothing, asks nothing, and the
        // payload the server already holds is not sent again even when the row is marked.
        let uploadsBefore = w.uploads.bodies.count
        let httpBefore = w.http.requests.count
        await w.service.pipelinePassFinished(changed: false)
        await w.service.idle()
        await w.service.pipelinePassFinished(changed: false)
        await w.service.idle()
        #expect(w.uploads.bodies.count == uploadsBefore && w.http.requests.count == httpBefore)
        try await w.db.writer.write { d in
            try ArchiveOutbox.enqueue(d, kind: .followUp, id: item.id, op: .upsert)
        }
        await w.service.pass(.userAsked)
        await w.service.idle()
        #expect(w.uploads.bodies.count == uploadsBefore)
        #expect(try await w.outbox.counts().pending == 0)
    }

    @Test func aRefusedTokenStopsTheSyncAndSaysSo() async throws {
        let w = try await world(answer: { _ in (401, Data()) })
        _ = try await FollowUpStore(db: w.db).add(text: "Renew the lease")
        await w.service.pass(.userAsked)
        #expect(w.uploads.bodies.count == 1)
        #expect(w.service.status.value.link == .revoked(host: "pebbleaudio.okgodoit.com"))
        // Still waiting, and nothing more is sent while the server refuses this phone.
        #expect(try await w.outbox.counts().pending == 1)
        await w.service.pass(.userAsked)
        #expect(w.uploads.bodies.count == 1)
    }

    /// A pass can reach the service before the runtime calls `start()` (a background entry at
    /// launch). It still works from the saved state: on empty state it re-sent the preferences
    /// and re-exported the whole library, then saved that over the real state, every launch.
    @Test(.timeLimit(.minutes(1))) func aPassBeforeStartWorksFromTheSavedState() async throws {
        var saved = ArchiveSyncService.PersistedState()
        saved.preferencesSent = ArchivePreferences()
        saved.transcriptExportMarked = ArchiveExport.transcriptExportVersion
        saved.alignedScope = ArchivePreferences().scope
        let w = try await world(starts: false, before: { db, directory in
            try await ArchiveOutbox(db: db).setActive(true)
            let conversations = (0..<3).map { index in
                GroupedConversation(
                    id: "conv-seg-\(index)", startMs: 1_788_000_000_000 + Int64(index) * 60_000,
                    endMs: 1_788_000_030_000 + Int64(index) * 60_000, timeZoneID: "UTC", isLive: false,
                    members: [ConversationMember(segmentId: "seg-\(index)")])
            }
            try await db.writer.write { d in
                _ = try ConversationGrouper.apply(conversations, in: d)
                try d.execute(sql: "UPDATE sync_outbox SET pending = 0, sentVersion = version, sentHash = 'old'")
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(saved).write(to: directory.appendingPathComponent("state.json"))
        })

        await w.service.pass(.backgroundEntry)
        await w.service.idle()
        await w.service.start()
        await w.service.pass(.userAsked)
        await w.service.idle()

        #expect(!w.http.requests.contains { $0.url?.path == "/sync/preferences" })
        #expect(w.uploads.bodies.isEmpty)
        let after = try JSONDecoder().decode(
            ArchiveSyncService.PersistedState.self,
            from: Data(contentsOf: w.directory.appendingPathComponent("state.json")))
        #expect(after.preferencesSent == saved.preferencesSent)
        #expect(after.transcriptExportMarked == saved.transcriptExportMarked)
        #expect(after.alignedScope == saved.alignedScope)
    }

    /// A new export version sends every transcript again once, a batch's worth per pass rather
    /// than the whole library in one: here 450 conversations a phone linked under an earlier
    /// release had already sent, and that release's saved state, which names no version.
    @Test func aNewExportResendsEveryTranscriptOnceAtTheUsualPace() async throws {
        let count = 450
        let w = try await world(before: { db, directory in
            try await ArchiveOutbox(db: db).setActive(true)
            let conversations = (0..<count).map { index in
                GroupedConversation(
                    id: String(format: "conv-seg-%04d", index), startMs: 1_788_000_000_000 + Int64(index) * 60_000,
                    endMs: 1_788_000_030_000 + Int64(index) * 60_000, timeZoneID: "UTC", isLive: false,
                    members: [ConversationMember(segmentId: String(format: "seg-%04d", index))])
            }
            try await db.writer.write { d in
                _ = try ConversationGrouper.apply(conversations, in: d)
                // All of it already sent and answered.
                try d.execute(sql: "UPDATE sync_outbox SET pending = 0, sentVersion = version, sentHash = 'old'")
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(ArchiveSyncService.PersistedState())
                .write(to: directory.appendingPathComponent("state.json"))
        })
        func sent(_ kind: String) -> Int {
            w.uploads.bodies.reduce(0) { total, body in
                let items = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["items"]
                    as? [[String: Any]] ?? []
                return total + items.filter { $0["kind"] as? String == kind }.count
            }
        }
        var perPass: [Int] = []
        var conversationsPerPass: [Int] = []
        for _ in 0..<4 {
            let before = (sent("transcript"), sent("conversation"))
            await w.service.pass(.userAsked)
            await w.service.idle()
            perPass.append(sent("transcript") - before.0)
            conversationsPerPass.append(sent("conversation") - before.1)
        }
        let page = ArchiveSyncProtocol.maxItemsPerBatch
        #expect(perPass == [page, page, count - 2 * page, 0])
        // Each conversation goes again with its transcript: its gaps are the screen's rows too,
        // and they changed with the export.
        #expect(conversationsPerPass == perPass)
        #expect(try await w.outbox.counts().pending == 0)
    }

    /// The device status goes as an ordinary upsert, its payload the reading the reporter
    /// stored. A server from before the kind refuses it: that is nobody's error to show, and it
    /// is not sent again — one upload, settled, nothing parked, nothing pending.
    @Test func aServerThatDoesNotKnowTheDeviceStatusIsNeitherAnErrorNorARetry() async throws {
        let w = try await world(answer: { body in
            let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            let items = json?["items"] as? [[String: Any]] ?? []
            let known = items.filter { $0["kind"] as? String != "deviceStatus" }
            let answer: [String: Any] = [
                "accepted": known.map { ["kind": $0["kind"] ?? "", "id": $0["id"] ?? "", "version": $0["version"] ?? 0] },
                "ignored": [],
                "rejected": items.filter { $0["kind"] as? String == "deviceStatus" }.map {
                    ["kind": "deviceStatus", "id": $0["id"] ?? "", "reason": "kind: 'deviceStatus' is not known"]
                },
                "pendingRequests": 0,
            ]
            return (200, (try? JSONSerialization.data(withJSONObject: answer)) ?? Data())
        })
        let reading = ArchiveDeviceStatusPayload(
            updatedAtMs: 1_793_188_800_000, capture: .active, link: .streaming, recording: true,
            lastAudioAtMs: 1_793_188_798_000, watchBatteryPercent: 62)
        try await w.outbox.recordDeviceStatus(
            deviceId: "dev-1", payload: try ArchiveJSON.encoder().encode(reading), atMs: reading.updatedAtMs)
        _ = try await FollowUpStore(db: w.db).add(text: "Water the tomatoes")
        await w.service.pass(.userAsked)
        await w.service.idle()

        #expect(w.uploads.bodies.count == 1)
        let body = try #require(w.uploads.bodies.first)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let items = try #require(json["items"] as? [[String: Any]])
        let status = try #require(items.first { $0["kind"] as? String == "deviceStatus" })
        #expect(status["id"] as? String == "dev-1" && status["op"] as? String == "upsert")
        let payload = try #require(status["payload"] as? [String: Any])
        #expect(payload["link"] as? String == "streaming" && payload["recording"] as? Bool == true)
        #expect((payload["updatedAtMs"] as? NSNumber)?.int64Value == 1_793_188_800_000)
        #expect(payload["watchFirmware"] is NSNull && payload["todayRecordedMinutes"] is NSNull)

        #expect(try await w.outbox.row(kind: .deviceStatus, id: "dev-1")?.pending == false)
        let counts = try await w.outbox.counts()
        #expect(counts.pending == 0 && counts.parked == 0)
        #expect(w.service.status.value.lastError == nil)
        // Nothing more goes until the next reading.
        await w.service.pass(.userAsked)
        await w.service.idle()
        #expect(w.uploads.bodies.count == 1)
    }

    @Test func aServerThatTakesTheDeviceStatusClearsIt() async throws {
        let w = try await world()
        try await w.outbox.recordDeviceStatus(deviceId: "dev-1", payload: Data("{}".utf8), atMs: 1)
        await w.service.pass(.userAsked)
        await w.service.idle()
        #expect(w.uploads.bodies.count == 1)
        let row = try #require(try await w.outbox.row(kind: .deviceStatus, id: "dev-1"))
        #expect(!row.pending && row.sentHash == ArchivePayloadBuilder.hash(Data("{}".utf8)))
    }

    @Test func anOversizedBatchIsHalvedAndSentAgain() async throws {
        let counter = Counter()
        let w = try await world(answer: { body in
            counter.increment() == 1 ? (413, Data()) : acceptAll(body)
        })
        let store = FollowUpStore(db: w.db)
        for index in 0..<4 { _ = try await store.add(text: "Item \(index)") }
        await w.service.pass(.userAsked)
        let sizes = w.uploads.bodies.map {
            ((try? JSONSerialization.jsonObject(with: $0)) as? [String: Any])?["items"] as? [Any] ?? []
        }.map(\.count)
        #expect(sizes.first == 4)
        #expect(sizes.dropFirst().allSatisfy { $0 <= ArchiveSyncProtocol.maxItemsPerBatch / 2 })
        #expect(try await w.outbox.counts().pending == 0)
    }
}

@Suite("archive link invitation")
struct ArchiveLinkInvitationTests {
    @Test func theServersQRCodeIsReadAndOnlyHttpsServersAreAccepted() throws {
        let url = try #require(
            URL(string: "pebbleaudio://link?code=ab3d-ef7h&origin=https://pebbleaudio.okgodoit.com"))
        let invitation = try #require(ArchiveLinkInvitation.parse(url))
        #expect(invitation.code == "AB3DEF7H")
        #expect(invitation.origin.absoluteString == "https://pebbleaudio.okgodoit.com")
        // No origin: the product's own server.
        let bare = try #require(URL(string: "pebbleaudio://link?code=AB3DEF7H"))
        #expect(ArchiveLinkInvitation.parse(bare)?.host == "pebbleaudio.okgodoit.com")
        // A code is never sent to a plain-http server, except this Mac's own loopback.
        let plain = try #require(URL(string: "pebbleaudio://link?code=AB3DEF7H&origin=http://example.com"))
        #expect(ArchiveLinkInvitation.parse(plain) == nil)
        #expect(ArchiveEndpoint.acceptableOrigin("http://localhost:5090")?.absoluteString == "http://localhost:5090")
        #expect(ArchiveEndpoint.acceptableOrigin("pebbleaudio.okgodoit.com/admin")?.absoluteString
            == "https://pebbleaudio.okgodoit.com")
        #expect(ArchiveLinkInvitation.parse(try #require(URL(string: "companion://today"))) == nil)
    }

    @Test func theServersOwnLinkPageOpensTheSameStepWithItsOriginAsTheServer() throws {
        let universal = try #require(URL(string: "https://pebbleaudio.okgodoit.com/link?code=k7qm-3xwd"))
        let invitation = try #require(ArchiveLinkInvitation.parse(universal))
        #expect(invitation.code == "K7QM3XWD")
        #expect(invitation.origin.absoluteString == "https://pebbleaudio.okgodoit.com")
        // The page's origin is the server; an `origin` in the query cannot redirect the code.
        let redirect = try #require(
            URL(string: "https://pebbleaudio.okgodoit.com/link?code=K7QM3XWD&origin=https://example.com"))
        #expect(ArchiveLinkInvitation.parse(redirect)?.host == "pebbleaudio.okgodoit.com")
        #expect(ArchiveLinkInvitation.parse(try #require(URL(string: "https://pebbleaudio.okgodoit.com/link"))) == nil)
        #expect(ArchiveLinkInvitation.parse(try #require(URL(string: "https://pebbleaudio.okgodoit.com/c/conv-1?t=12"))) == nil)
        #expect(ArchiveLinkInvitation.parse(try #require(URL(string: "http://pebbleaudio.okgodoit.com/link?code=K7QM3XWD"))) == nil)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() -> Int { lock.withLock { value += 1; return value } }
}
