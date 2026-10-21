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
    }

    fileprivate func world(answer: @escaping @Sendable (Data) -> (Int, Data) = acceptAll) async throws -> World {
        let db = try AppDatabase.inMemory()
        let outbox = ArchiveOutbox(db: db)
        let clock = TestClock()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-sync-\(UUID().uuidString)", isDirectory: true)
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
        await service.start()
        return World(db: db, outbox: outbox, http: http, uploads: uploads, service: service)
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
