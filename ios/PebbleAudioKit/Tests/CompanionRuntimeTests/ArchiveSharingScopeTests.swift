import AppDB
import Foundation
import Testing

@testable import CompanionRuntime

// The phone's half of what the person allows (`sync-protocol.md` §5): the sharing scope, clips,
// and edits. The server enforces all three, and so does the phone, so a stale server preference
// can never move audio or text the person did not allow. What these pin is what the server
// cannot repair: something outside the scope sent anyway, an item the server ignored remembered
// as stored (so widening the scope never brings it back), a preference that waits for the sync
// switch, and an unlink that forgets the link while the server still holds the copy.

private let day: Int64 = 86_400_000
/// 2026-10-21, mid-morning UTC: a realistic "now" for the windows.
private let now: Int64 = 1_792_576_800_000

/// Settings the test changes as it goes.
final class ArchiveSettingsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: ArchiveSyncSettings
    init(_ value: ArchiveSyncSettings) { _value = value }
    var value: ArchiveSyncSettings {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

/// A server whose answers the test writes: each request goes to `handler`.
final class ArchiveScriptedHTTP: ArchiveHTTP, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    var handler: @Sendable (URLRequest) throws -> ArchiveHTTPResponse

    init(handler: @escaping @Sendable (URLRequest) throws -> ArchiveHTTPResponse = { _ in .init(status: 200, body: Data("{}".utf8)) }) {
        self.handler = handler
    }

    var requests: [URLRequest] { lock.withLock { _requests } }
    func requests(_ method: String, _ path: String) -> [URLRequest] {
        requests.filter { $0.httpMethod == method && $0.url?.path == path }
    }

    func send(_ request: URLRequest) async throws -> ArchiveHTTPResponse {
        lock.withLock { _requests.append(request) }
        if request.url?.path == "/sync/requests" {
            return ArchiveHTTPResponse(status: 200, body: Data("{\"requests\":[]}".utf8))
        }
        return try handler(request)
    }
}

struct NetworkDown: Error {}

/// Accepts everything, or ignores the ids in `outside` as outside the scope.
private func answer(_ body: Data, outside: Set<String> = []) -> (Int, Data) {
    let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    var accepted: [[String: Any]] = []
    var ignored: [[String: Any]] = []
    for item in json?["items"] as? [[String: Any]] ?? [] {
        let entry: [String: Any] = ["kind": item["kind"] ?? "", "id": item["id"] ?? "", "version": item["version"] ?? 0]
        if outside.contains(item["id"] as? String ?? "") {
            ignored.append(entry.merging(["reason": "outsideScope"]) { $1 })
        } else {
            accepted.append(entry)
        }
    }
    let response: [String: Any] = [
        "serverTime": "2026-10-21T00:00:00.000Z", "accepted": accepted, "ignored": ignored,
        "rejected": [], "pendingRequests": 0,
    ]
    return (200, (try? JSONSerialization.data(withJSONObject: response)) ?? Data())
}

private func sentIds(_ uploads: ArchiveFakeUploads) -> [String] {
    uploads.bodies.flatMap { body -> [String] in
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        return (json?["items"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
    }
}

@Suite("archive sharing scope")
struct ArchiveSharingScopeTests {
    struct World {
        var db: AppDatabase
        var outbox: ArchiveOutbox
        var http: ArchiveScriptedHTTP
        var uploads: ArchiveFakeUploads
        var settings: ArchiveSettingsBox
        var clock: TestClock
        var service: ArchiveSyncService
        var directory: URL
    }

    func world(
        settings: ArchiveSyncSettings = ArchiveSyncSettings(
            origin: "https://pebbleaudio.okgodoit.com", deviceId: "dev-1", enabled: true),
        http: ArchiveScriptedHTTP = ArchiveScriptedHTTP(),
        answer: @escaping @Sendable (Data) -> (Int, Data) = { answer($0) }
    ) async throws -> World {
        let db = try AppDatabase.inMemory()
        let outbox = ArchiveOutbox(db: db)
        let clock = TestClock()
        await clock.advance(by: now)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-scope-\(UUID().uuidString)", isDirectory: true)
        let box = ArchiveSettingsBox(settings)
        let builder = ArchivePayloadBuilder(
            sources: .init(
                database: db, readMeta: { _ in nil }, listSegments: { [] },
                transcript: { _ in nil }, transcriptVersion: { _ in "absent" },
                nowMs: { clock.nowMs }))
        let uploads = ArchiveFakeUploads(answer: answer)
        let service = ArchiveSyncService(
            .init(
                outbox: outbox, builder: builder,
                requests: ArchiveRequestHandler(
                    sources: .init(
                        builder: builder, readFrames: { _ in [] }, temporaryDirectory: directory,
                        nowMs: { clock.nowMs }, permissions: { box.value.preferences })),
                http: http, uploads: uploads, settings: { box.value },
                token: { "pad_test" }, directory: directory, clock: clock,
                isForeground: { true }, isCharging: { false }))
        await service.start()
        return World(
            db: db, outbox: outbox, http: http, uploads: uploads, settings: box, clock: clock,
            service: service, directory: directory)
    }

    /// A follow-up said `daysAgo` days before now.
    func followUp(_ id: String, daysAgo: Int64, in db: AppDatabase) async throws {
        _ = try await FollowUpStore(db: db).insertFromAssistant(
            FollowUp(
                id: id, text: "Follow-up \(id)", done: false, sourceConversationId: nil,
                sourceSegmentId: nil, createdAtMs: now - daysAgo * day))
    }

    // MARK: - The scope itself

    @Test func windowsWidenAndNarrowByWhatTheyHoldNow() {
        let thirty = ArchiveSharingScope.lastDays(30)
        let ninety = ArchiveSharingScope.lastDays(90)
        #expect(thirty.cutoffMs(nowMs: now) == now - 30 * day)
        #expect(ArchiveSharingScope.all.cutoffMs(nowMs: now) == nil)
        // Wider adds exactly the stretch the old cutoff left out.
        #expect(
            ArchiveSharingScope.widening(from: thirty, to: ninety, nowMs: now)
                == ArchiveScopeRange(fromMs: now - 90 * day, toMs: now - 30 * day))
        #expect(
            ArchiveSharingScope.widening(from: .since(ms: now - day), to: .all, nowMs: now)
                == ArchiveScopeRange(fromMs: nil, toMs: now - day))
        // Narrower, the same, or from everything: nothing to send again.
        #expect(ArchiveSharingScope.widening(from: ninety, to: thirty, nowMs: now) == nil)
        #expect(ArchiveSharingScope.widening(from: .all, to: thirty, nowMs: now) == nil)
        #expect(ArchiveSharingScope.narrows(from: .all, to: thirty, nowMs: now))
        #expect(ArchiveSharingScope.narrows(from: ninety, to: .since(ms: now - day), nowMs: now))
        #expect(!ArchiveSharingScope.narrows(from: thirty, to: .all, nowMs: now))
    }

    @Test func theScopeGoesOnTheWireAsTheContractWritesIt() throws {
        func json(_ scope: ArchiveSharingScope) throws -> [String: Any] {
            let data = try JSONEncoder().encode(ArchivePreferences(clips: true, edits: false, scope: scope))
            return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        let rolling = try json(.lastDays(90))
        #expect(rolling["clips"] as? Bool == true && rolling["edits"] as? Bool == false)
        let scope = try #require(rolling["scope"] as? [String: Any])
        #expect(scope["kind"] as? String == "lastDays" && scope["days"] as? Int == 90)
        #expect(scope["since"] is NSNull)
        let since = try #require(try json(.since(ms: 1_792_540_800_000))["scope"] as? [String: Any])
        #expect(since["kind"] as? String == "since" && since["since"] as? String == "2026-10-21T00:00:00.000Z")
        // The server's answer reads back (its `since` is a time, `days` absent for other kinds).
        let answer = Data(#"{"clips":false,"edits":true,"scope":{"kind":"since","since":"2026-10-21T00:00:00Z"}}"#.utf8)
        let read = try JSONDecoder().decode(ArchivePreferences.self, from: answer)
        #expect(read == ArchivePreferences(clips: false, edits: true, scope: .since(ms: 1_792_540_800_000)))
    }

    @Test func countsAreThePhonesOwnForEveryChoice() {
        let counts = ArchiveScopeCounts(startsMs: [now - 1, now - 10 * day, now - 40 * day, now - 200 * day])
        #expect(counts.total == 4 && counts.oldestStartMs == now - 200 * day)
        #expect(counts.count(.lastDays(30), nowMs: now) == 2)
        #expect(counts.count(.lastDays(90), nowMs: now) == 3)
        #expect(counts.count(.all, nowMs: now) == 4)
        #expect(counts.removed(from: .lastDays(90), to: .lastDays(30), nowMs: now) == 1)
        #expect(counts.removed(from: .lastDays(30), to: .all, nowMs: now) == 0)
    }

    // MARK: - The phone never sends what the scope leaves out

    @Test func nothingOutsideTheScopeIsSentAndWideningSendsItAgain() async throws {
        var settings = ArchiveSyncSettings(
            origin: "https://pebbleaudio.okgodoit.com", deviceId: "dev-1", enabled: true,
            preferences: ArchivePreferences(scope: .lastDays(30)))
        settings.setupComplete = true
        let w = try await world(settings: settings)
        try await followUp("recent", daysAgo: 2, in: w.db)
        try await followUp("old", daysAgo: 100, in: w.db)
        await w.service.didLink()
        await w.service.pass(.userAsked)

        #expect(sentIds(w.uploads) == ["recent"])
        // Not waiting, and not remembered as sent: the server never had it.
        let old = try #require(try await w.outbox.row(kind: .followUp, id: "old"))
        #expect(!old.pending && old.sentHash == nil)
        #expect(try await w.outbox.row(kind: .followUp, id: "recent")?.sentHash != nil)

        // Widening to everything re-marks what it adds, and only that.
        w.settings.value.preferences.scope = .all
        await w.service.settingsChanged()
        #expect(sentIds(w.uploads) == ["recent", "old"])
        // The server was told the new scope, before anything else in that pass.
        let puts = w.http.requests("PUT", "/sync/preferences")
        #expect(!puts.isEmpty)
        let body = try #require(puts.last?.httpBody)
        let scope = (try JSONSerialization.jsonObject(with: body) as? [String: Any])?["scope"] as? [String: Any]
        #expect(scope?["kind"] as? String == "all")
    }

    @Test func anItemTheServerIgnoredAsOutsideTheScopeIsNotRememberedAsStored() async throws {
        // The phone believes it in scope; the server (a different idea of the account's day)
        // does not. Treating that as "held" would mean it is never sent again.
        let w = try await world(answer: { answer($0, outside: ["edge"]) })
        try await followUp("edge", daysAgo: 1, in: w.db)
        await w.service.didLink()
        await w.service.pass(.userAsked)
        let row = try #require(try await w.outbox.row(kind: .followUp, id: "edge"))
        #expect(!row.pending && row.sentHash == nil)
        // A later change sends it again rather than reading it as unchanged.
        try await FollowUpStore(db: w.db).setText(id: "edge", "Follow-up edge, edited")
        await w.service.pass(.userAsked)
        #expect(sentIds(w.uploads).filter { $0 == "edge" }.count == 2)
    }

    // MARK: - Preferences

    @Test func nothingSyncsBeforeStartSyncingAndPreferencesGoEvenWhilePaused() async throws {
        var settings = ArchiveSyncSettings(
            origin: "https://pebbleaudio.okgodoit.com", deviceId: "dev-1", enabled: false)
        settings.setupComplete = false
        let w = try await world(settings: settings)
        try await followUp("a", daysAgo: 1, in: w.db)
        await w.service.didLink()
        await w.service.pass(.userAsked)
        // Linked but not set up: nothing sent, nothing asked.
        #expect(w.uploads.bodies.isEmpty)
        #expect(w.http.requests("PUT", "/sync/preferences").isEmpty)

        // Set up, then paused: the preferences still reach the server; the text does not.
        w.settings.value.setupComplete = true
        w.settings.value.preferences = ArchivePreferences(clips: true, edits: false, scope: .lastDays(90))
        await w.service.settingsChanged()
        #expect(w.http.requests("PUT", "/sync/preferences").count == 1)
        #expect(w.uploads.bodies.isEmpty)
        // Confirmed once: not sent again until they change.
        await w.service.pass(.foregroundTick)
        await w.service.settingsChanged()
        #expect(w.http.requests("PUT", "/sync/preferences").count == 1)

        // Turned on: the text goes.
        w.settings.value.enabled = true
        await w.service.settingsChanged()
        #expect(sentIds(w.uploads) == ["a"])
    }

    @Test func aPreferenceTheServerDidNotTakeIsSentAgain() async throws {
        let failing = ArchiveScriptedHTTP { request in
            if request.url?.path == "/sync/preferences" { throw NetworkDown() }
            return .init(status: 200, body: Data("{}".utf8))
        }
        let w = try await world(http: failing)
        await w.service.didLink()  // tries once, with the defaults
        w.settings.value.preferences.clips = true
        await w.service.settingsChanged()
        await w.service.pass(.foregroundTick)
        #expect(failing.requests("PUT", "/sync/preferences").count == 3)
        failing.handler = { _ in .init(status: 200, body: Data("{}".utf8)) }
        await w.service.pass(.foregroundTick)
        await w.service.pass(.foregroundTick)
        #expect(failing.requests("PUT", "/sync/preferences").count == 4)
    }

    // MARK: - Requests the person has not allowed

    @Test func clipsAndEditsAreRefusedOnThePhoneWhatever_TheServerAsked() async throws {
        let w = try await world()
        let db = w.db
        let handler = ArchiveRequestHandler(
            sources: .init(
                builder: ArchivePayloadBuilder(
                    sources: .init(
                        database: db, readMeta: { _ in nil }, listSegments: { [] },
                        transcript: { _ in nil }, transcriptVersion: { _ in "absent" })),
                readFrames: { _ in [] }, temporaryDirectory: FileManager.default.temporaryDirectory,
                nowMs: { now }, permissions: { w.settings.value.preferences }))
        let clip = ArchiveServerRequest(
            id: "r1", kind: "clip", createdAt: nil, expiresAt: nil,
            payload: .object([
                "conversationId": .string("conv-1"), "startAt": .string("2026-10-21T01:00:00Z"),
                "endAt": .string("2026-10-21T01:01:00Z"),
            ]))
        #expect(await handler.handle(clip) == .result(.init(status: .failed, detail: ArchiveRequestHandler.Refusal.clips)))

        let create = ArchiveServerRequest(
            id: "r2", kind: "followUp.create", createdAt: nil, expiresAt: nil,
            payload: .object(["id": .string("fu-assistant"), "text": .string("Send Priya the deck")]))
        #expect(await handler.handle(create) == .result(.init(status: .failed, detail: ArchiveRequestHandler.Refusal.edits)))
        #expect(try await FollowUpStore(db: db).load(id: "fu-assistant") == nil)

        w.settings.value.preferences.edits = true
        #expect(await handler.handle(create) == .result(.init(status: .done)))
        #expect(try await FollowUpStore(db: db).load(id: "fu-assistant")?.text == "Send Priya the deck")
    }

    // MARK: - Unlinking deletes the server's copy, or changes nothing

    @Test func unlinkForgetsTheLinkOnlyOnceTheServerHasDeleted() async throws {
        let http = ArchiveScriptedHTTP { request in
            if request.httpMethod == "DELETE" { throw NetworkDown() }
            return .init(status: 200, body: Data("{}".utf8))
        }
        let w = try await world(http: http)
        await w.service.didLink()
        #expect(await w.service.unlink() == .unreachable)
        #expect(try await w.outbox.isActive())

        http.handler = { request in
            .init(status: request.httpMethod == "DELETE" ? 500 : 200, body: Data("{}".utf8))
        }
        #expect(await w.service.unlink() == .refused(500))
        #expect(try await w.outbox.isActive())

        http.handler = { _ in .init(status: 204, body: Data()) }
        #expect(await w.service.unlink() == .deleted)
        #expect(try await !w.outbox.isActive())
        let delete = try #require(http.requests("DELETE", "/link").last)
        #expect(delete.url?.query == nil)  // never `keepData=true` from the app
        #expect(delete.value(forHTTPHeaderField: "Authorization") == "Bearer pad_test")
    }

    // MARK: - Delete All reaches the server

    @Test func deleteAllWipesTheServerEvenWhileSyncIsPaused() async throws {
        var settings = ArchiveSyncSettings(
            origin: "https://pebbleaudio.okgodoit.com", deviceId: "dev-1", enabled: false)
        settings.setupComplete = true
        let w = try await world(settings: settings)
        try await followUp("a", daysAgo: 1, in: w.db)
        await w.service.didLink()
        await w.service.willWipeLocally()
        await w.service.didWipeLocally()
        #expect(w.http.requests("POST", "/sync/wipe").count == 1)
        #expect(w.service.status.value.wipePending == false)
        // Paused: the wipe goes, the text does not.
        #expect(w.uploads.bodies.isEmpty)
    }

    @Test func aDeleteAllInterruptedByAKillIsSentOnTheNextLaunchBeforeAnythingElse() async throws {
        let w = try await world()
        try await followUp("kept", daysAgo: 1, in: w.db)
        await w.service.didLink()
        await w.service.pass(.userAsked)
        #expect(sentIds(w.uploads) == ["kept"])
        // The app is killed after the local deletes began, before `didWipeLocally`.
        await w.service.willWipeLocally()

        let directory = FileManager.default.temporaryDirectory
        // A new process: a new background session object (a stream has one reader).
        let uploads = ArchiveFakeUploads(answer: { answer($0) })
        let relaunched = ArchiveSyncService(
            .init(
                outbox: w.outbox,
                builder: ArchivePayloadBuilder(
                    sources: .init(
                        database: w.db, readMeta: { _ in nil }, listSegments: { [] },
                        transcript: { _ in nil }, transcriptVersion: { _ in "absent" })),
                requests: ArchiveRequestHandler(
                    sources: .init(
                        builder: ArchivePayloadBuilder(
                            sources: .init(
                                database: w.db, readMeta: { _ in nil }, listSegments: { [] },
                                transcript: { _ in nil }, transcriptVersion: { _ in "absent" })),
                        readFrames: { _ in [] }, temporaryDirectory: directory, nowMs: { now })),
                http: w.http, uploads: uploads, settings: { w.settings.value },
                token: { "pad_test" }, directory: w.directory,
                clock: w.clock, isForeground: { true }, isCharging: { false }))
        await relaunched.start()
        #expect(relaunched.status.value.wipePending)
        await relaunched.pass(.foregroundTick)
        // The owed wipe went, then what is left on the phone was sent to the empty server.
        #expect(w.http.requests("POST", "/sync/wipe").count == 1)
        #expect(relaunched.status.value.wipePending == false)
        #expect(sentIds(uploads) == ["kept"])
    }

    /// Item 52 of the 2026-10-21 sweep, settled: a batch still uploading when Delete All runs is
    /// cancelled, and the wipe waits for it, so nothing the person deleted lands after the wipe.
    @Test func aBatchStillUploadingIsCancelledBeforeTheWipeAndNeverLandsAfterIt() async throws {
        let w = try await world()
        try await followUp("deleted-later", daysAgo: 1, in: w.db)
        w.uploads.holds = true
        // Linking sends the library; its first batch is still uploading when Delete All runs.
        let pass = Task { await w.service.didLink() }
        var spins = 0
        while w.uploads.bodies.isEmpty, spins < 100_000 {
            await Task.yield()
            spins += 1
        }
        try #require(!w.uploads.bodies.isEmpty)
        // The pass waits for the answer that never comes, then leaves the batch uploading.
        await w.clock.advance(by: ArchiveSyncService.answerWaitMs)
        await pass.value
        #expect(await w.uploads.inFlight().count == 1)

        w.uploads.holds = false
        await w.service.willWipeLocally()
        #expect(w.uploads.cancelled.count == 1)
        #expect(await w.uploads.inFlight().isEmpty)
        try await FollowUpStore(db: w.db).delete(id: "deleted-later")
        await w.service.didWipeLocally()
        #expect(w.http.requests("POST", "/sync/wipe").count == 1)
        // The cancelled batch is not read as the server being unreachable.
        #expect(w.service.status.value.lastError == nil)
        // Only the one cancelled upload ever carried the deleted follow-up.
        #expect(sentIds(w.uploads).filter { $0 == "deleted-later" }.count == 1)
    }

    // MARK: - Status: who can read, published only when it changes

    @Test func whoCanReadIsReadKeptAndPublishedOnlyWhenItChanges() async throws {
        let body = Data(
            #"""
            {"serverTime":"2026-10-21T00:00:00Z","lastBatchAt":null,"pendingRequests":0,
             "counts":{"conversation":168},
             "aiReads":[{"at":"2026-10-21T02:41:00Z","client":"ChatGPT","tool":"fetch","ids":["conv-kitchen"]}],
             "access":[{"kind":"oauth","id":"c1","name":"ChatGPT","scopes":["archive:read"],"connectedAt":"2026-10-12T00:00:00Z","lastUsedAt":"2026-10-21T02:41:00Z"},
                       {"kind":"token","id":"t1","name":"Codex on Mac","scopes":["archive:read","archive:write"],"connectedAt":"2026-10-18T00:00:00Z","lastUsedAt":null}]}
            """#.utf8)
        let http = ArchiveScriptedHTTP { request in
            if request.url?.path == "/sync/status" { return .init(status: 200, body: body) }
            return .init(status: 204, body: Data())
        }
        let w = try await world(http: http)
        await w.service.refreshServerStatus()
        let first = w.service.status.value
        let access = try #require(first.server?.access)
        #expect(access.map(\.name) == ["ChatGPT", "Codex on Mac"])
        #expect(access.map(\.canWrite) == [false, true])
        #expect(first.server?.counts["conversation"] == 168)
        #expect(first.serverStatusAtMs == now)

        // The same answer a minute later: nothing published (the time shown does not move).
        await w.clock.advance(by: 60_000)
        await w.service.refreshServerStatus()
        #expect(w.service.status.value == first)

        // Unreachable: the last answer stays, marked as of when it came.
        http.handler = { _ in throw NetworkDown() }
        await w.service.refreshServerStatus()
        #expect(w.service.status.value.serverUnreachable)
        #expect(w.service.status.value.server?.access.count == 2)

        // Disconnecting one from the phone removes it from what every screen shows.
        http.handler = { _ in .init(status: 204, body: Data()) }
        #expect(await w.service.revokeAccess(kind: "token", id: "t1"))
        #expect(http.requests("DELETE", "/sync/access/token/t1").count == 1)
        #expect(w.service.status.value.server?.access.map(\.name) == ["ChatGPT"])
    }
}
