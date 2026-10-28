import AppDB
import Foundation
import Testing

@testable import CompanionRuntime

// The Pebble plugin's two requests from the phone (`ArchivePlugin.swift`): what goes to the
// server, what comes back, and that a refused phone reads as not linked everywhere.

/// Answers by path, and records what was asked.
private final class PluginFakeHTTP: ArchiveHTTP, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private var answers: [String: (Int, String)]
    var unreachable = false
    var requests: [URLRequest] { lock.withLock { _requests } }

    init(_ answers: [String: (Int, String)]) { self.answers = answers }

    func answer(_ path: String, _ status: Int, _ body: String) {
        lock.withLock { answers[path] = (status, body) }
    }

    func send(_ request: URLRequest) async throws -> ArchiveHTTPResponse {
        lock.withLock { _requests.append(request) }
        if lock.withLock({ unreachable }) { throw URLError(.notConnectedToInternet) }
        let (status, body) = lock.withLock { answers[request.url?.path ?? ""] } ?? (404, "")
        return ArchiveHTTPResponse(status: status, body: Data(body.utf8))
    }
}

/// The settings the service reads, changeable mid-test.
private final class SettingsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: ArchiveSyncSettings
    var value: ArchiveSyncSettings {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }

    init(_ value: ArchiveSyncSettings) { _value = value }
}

@Suite("archive sync: the Pebble plugin")
struct ArchivePluginTests {
    private static let linked = ArchiveSyncSettings(
        origin: "https://pebbleaudio.okgodoit.com", deviceId: "dev-1", enabled: true)

    private func service(
        _ http: PluginFakeHTTP, settings: SettingsBox = SettingsBox(linked)
    ) throws -> ArchiveSyncService {
        let db = try AppDatabase.inMemory()
        let clock = TestClock()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-plugin-\(UUID().uuidString)", isDirectory: true)
        let builder = ArchivePayloadBuilder(
            sources: .init(
                database: db, readMeta: { _ in nil }, listSegments: { [] },
                transcript: { _ in nil }, transcriptVersion: { _ in "absent" },
                nowMs: { clock.nowMs }))
        return ArchiveSyncService(
            .init(
                outbox: ArchiveOutbox(db: db), builder: builder,
                requests: ArchiveRequestHandler(
                    sources: .init(
                        builder: builder, readFrames: { _ in [] }, temporaryDirectory: directory,
                        nowMs: { clock.nowMs })),
                http: http, uploads: ArchiveFakeUploads(answer: { _ in (200, Data()) }),
                settings: { settings.value }, token: { "pad_test" }, directory: directory,
                clock: clock, isForeground: { true }, isCharging: { false }))
    }

    @Test func theCodeAndTheConnectionComeFromThePhonesOwnDoor() async throws {
        let http = PluginFakeHTTP([
            "/sync/plugin-code": (201, #"{"code":"K7QM-3XWD","expiresAtMs":1792000375292}"#),
            "/sync/plugin": (200, #"{"connected":true,"lastUsedAtMs":1791999175292}"#),
        ])
        let service = try service(http)

        #expect(
            await service.mintPluginCode()
                == .success(ArchivePluginCode(code: "K7QM-3XWD", expiresAtMs: 1_792_000_375_292)))
        #expect(
            await service.pluginConnection()
                == .success(ArchivePluginConnection(connected: true, lastUsedAtMs: 1_791_999_175_292)))

        let mint = try #require(http.requests.first)
        #expect(mint.httpMethod == "POST" && mint.url?.absoluteString == "https://pebbleaudio.okgodoit.com/sync/plugin-code")
        #expect(mint.value(forHTTPHeaderField: "Authorization") == "Bearer pad_test")
        #expect(mint.value(forHTTPHeaderField: "X-Sync-Protocol") == ArchiveSyncProtocol.version)
        #expect(http.requests.last?.httpMethod == "GET")

        // Not connected: the last read is absent, not zero.
        http.answer("/sync/plugin", 200, #"{"connected":false,"lastUsedAtMs":null}"#)
        #expect(await service.pluginConnection() == .success(ArchivePluginConnection(connected: false)))
    }

    @Test func withoutAServerNothingIsAsked() async throws {
        let http = PluginFakeHTTP([:])
        let service = try service(http, settings: SettingsBox(ArchiveSyncSettings(enabled: false)))
        #expect(await service.mintPluginCode() == .failure(.notLinked))
        #expect(await service.pluginConnection() == .failure(.notLinked))
        #expect(http.requests.isEmpty)
    }

    /// A refused phone is unlinked for the plugin as for everything else, and asks nothing more.
    @Test func aRefusedPhoneReadsAsNotLinkedAndStopsAsking() async throws {
        let http = PluginFakeHTTP(["/sync/plugin-code": (401, "")])
        let service = try service(http)
        #expect(await service.mintPluginCode() == .failure(.notLinked))
        #expect(service.status.value.link == .revoked(host: "pebbleaudio.okgodoit.com"))
        #expect(await service.pluginConnection() == .failure(.notLinked))
        #expect(http.requests.count == 1)
    }

    /// Offline, an older server without these endpoints, or an answer it cannot read: unavailable,
    /// and the link stays as it was.
    @Test func noAnswerIsUnavailableNotUnlinked() async throws {
        let http = PluginFakeHTTP([
            "/sync/plugin-code": (404, #"{"error":"Not found"}"#),
            "/sync/plugin": (200, "not json"),
        ])
        let service = try service(http)
        #expect(await service.mintPluginCode() == .failure(.unavailable))
        #expect(await service.pluginConnection() == .failure(.unavailable))
        http.unreachable = true
        #expect(await service.pluginConnection() == .failure(.unavailable))
        #expect(service.status.value.link != .revoked(host: "pebbleaudio.okgodoit.com"))
    }
}
