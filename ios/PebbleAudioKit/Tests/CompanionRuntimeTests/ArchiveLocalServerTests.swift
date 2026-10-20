import AppDB
import Foundation
import Receiver
import Testing

@testable import CompanionRuntime

// The phone's half against a REAL Pebble Audio server running on this Mac (never production):
// link with a minted code, choose what syncs, send, see who can read, and unlink. Skipped unless
// both are set:
//
//   PEBBLE_LOCAL_SERVER=http://localhost:5191   (`dotnet run` from server/, a scratch database)
//   PEBBLE_LOCAL_CODE=K7QM-3XWD                 (`ios/Tools/ArchiveImport/mint-local-link-code.sh <db>`)
//
// A code works once, so mint a new one for every run.

/// Uploads a batch file for real, in the foreground (a background session needs an app).
final class ArchiveForegroundUploads: ArchiveUploading, @unchecked Sendable {
    let outcomes: AsyncStream<ArchiveUploadOutcome>
    private let continuation: AsyncStream<ArchiveUploadOutcome>.Continuation

    init() {
        (outcomes, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    func upload(_ request: URLRequest, fromFile file: URL, description: String) async {
        do {
            let (data, response) = try await URLSession.shared.upload(for: request, fromFile: file)
            continuation.yield(
                ArchiveUploadOutcome(
                    description: description, status: (response as? HTTPURLResponse)?.statusCode ?? 0,
                    body: data))
        } catch {
            continuation.yield(
                ArchiveUploadOutcome(description: description, status: 0, body: Data(), error: "\(error)"))
        }
    }

    func inFlight() async -> Set<String> { [] }
    func reconnect() async {}
    func cancel(descriptionsWithPrefix prefix: String) async {}
}

final class TokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: String?
    var value: String? {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

@Suite(
    "archive sync against a local server",
    .enabled(if: ProcessInfo.processInfo.environment["PEBBLE_LOCAL_SERVER"] != nil
        && ProcessInfo.processInfo.environment["PEBBLE_LOCAL_CODE"] != nil))
struct ArchiveLocalServerTests {
    @Test func linkChooseSendReadWhoCanReadAndUnlink() async throws {
        let env = ProcessInfo.processInfo.environment
        let origin = try #require(env["PEBBLE_LOCAL_SERVER"].flatMap(ArchiveEndpoint.acceptableOrigin))
        let code = try #require(env["PEBBLE_LOCAL_CODE"])

        let db = try AppDatabase.inMemory()
        let outbox = ArchiveOutbox(db: db)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-local-\(UUID().uuidString)", isDirectory: true)
        let settings = ArchiveSettingsBox(ArchiveSyncSettings(enabled: false, setupComplete: false))
        let token = TokenBox()
        let builder = ArchivePayloadBuilder(
            sources: .init(
                database: db, readMeta: { _ in nil }, listSegments: { [] }, transcript: { _ in nil },
                transcriptVersion: { _ in "absent" }))
        let clock = SystemTestClock()
        let service = ArchiveSyncService(
            .init(
                outbox: outbox, builder: builder,
                requests: ArchiveRequestHandler(
                    sources: .init(
                        builder: builder, readFrames: { _ in [] }, temporaryDirectory: directory,
                        nowMs: { clock.nowMs }, permissions: { settings.value.preferences })),
                http: URLSessionArchiveHTTP(), uploads: ArchiveForegroundUploads(),
                settings: { settings.value }, token: { token.value }, directory: directory,
                clock: clock, isForeground: { true }, isCharging: { false }))
        await service.start()

        // Something to send: one follow-up written now, one written long ago.
        let store = FollowUpStore(db: db)
        _ = try await store.insertFromAssistant(
            FollowUp(id: "fu-local-new", text: "Send Priya the launch deck", done: false,
                     sourceConversationId: nil, sourceSegmentId: nil, createdAtMs: clock.nowMs))
        _ = try await store.insertFromAssistant(
            FollowUp(id: "fu-local-old", text: "Ask Sam about the cabinet quote", done: false,
                     sourceConversationId: nil, sourceSegmentId: nil,
                     createdAtMs: clock.nowMs - 200 * 86_400_000))

        // Link: stored switched off and not set up, as the app stores it.
        let linked = try await service.link(
            code: code, origin: origin, deviceName: "Simulator test phone", appVersion: "test",
            appBuild: "test")
        #expect(linked.deviceToken.hasPrefix("pad_"))
        token.value = linked.deviceToken
        settings.value = ArchiveSyncSettings(
            origin: origin.absoluteString, deviceId: linked.deviceId, enabled: false,
            setupComplete: false)
        await service.didLink()
        await service.pass(.userAsked)
        #expect(service.status.value.lastBatchAtMs == nil, "nothing syncs before Start Syncing")

        // Start Syncing with a 90-day window and clips on.
        settings.value.preferences = ArchivePreferences(clips: true, edits: false, scope: .lastDays(90))
        settings.value.setupComplete = true
        settings.value.enabled = true
        await service.settingsChanged()
        await service.idle()
        #expect(service.status.value.lastBatchAtMs != nil)
        #expect(service.status.value.lastError == nil)

        // The server stored the new one and not the old one.
        await service.refreshServerStatus()
        let server = try #require(service.status.value.server)
        #expect(server.counts["followUp"] == 1)
        #expect(server.access.isEmpty)
        #expect(!service.status.value.serverUnreachable)

        // What the server holds as preferences is what the phone sent.
        var get = URLRequest(url: ArchiveEndpoint.url(origin, "/sync/preferences"))
        get.setValue("Bearer \(linked.deviceToken)", forHTTPHeaderField: "Authorization")
        get.setValue(ArchiveSyncProtocol.version, forHTTPHeaderField: "X-Sync-Protocol")
        let (body, _) = try await URLSession.shared.data(for: get)
        let stored = try JSONDecoder().decode(ArchivePreferences.self, from: body)
        #expect(stored == settings.value.preferences)

        // Widening sends the old one too.
        settings.value.preferences.scope = .all
        await service.settingsChanged()
        await service.idle()
        await service.refreshServerStatus()
        #expect(service.status.value.server?.counts["followUp"] == 2)

        // An access that is not there is already gone.
        #expect(await service.revokeAccess(kind: "token", id: UUID().uuidString))

        // Unlink deletes the server's copy and ends this token.
        #expect(await service.unlink() == .deleted)
        let (_, after) = try await URLSession.shared.data(for: get)
        #expect((after as? HTTPURLResponse)?.statusCode == 401)
    }
}

/// The wall clock, for a test that talks to a real server.
final class SystemTestClock: ReceiverClock, @unchecked Sendable {
    var nowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    func sleep(ms: Int64) async throws { try await Task.sleep(for: .milliseconds(ms)) }
}
