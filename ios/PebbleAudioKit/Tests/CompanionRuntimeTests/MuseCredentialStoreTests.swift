import Foundation
import MuseLink
import Testing
@testable import CompanionRuntime

struct MuseCredentialStoreTests {
    @Test func simultaneousConnectionsAndLateRejectionsShareOneRotation() async throws {
        let fx = AuthFixture()
        let first = Task { try await fx.store.current() }
        await fx.server.waitForRequest()
        let second = Task { try await fx.store.refresh(rejected: fx.original) }
        await fx.server.reply()
        let a = try await first.value
        #expect(try await second.value == a)
        #expect(a.accessToken == "new-access")
        #expect(fx.secrets.credentials() == a)
        #expect(try await fx.store.refresh(rejected: fx.original) == a)
        #expect(await fx.server.count == 1)
    }
    @Test func callerCancellationStillPersistsTheRotation() async throws {
        let fx = AuthFixture()
        let first = Task { try await fx.store.current() }
        await fx.server.waitForRequest()
        first.cancel()
        await fx.server.reply()
        _ = try await first.value
        #expect(fx.secrets.credentials()?.accessToken == "new-access")
        #expect(try await fx.store.current().accessToken == "new-access")
        #expect(await fx.server.count == 1)
    }
    @Test func failedSaveRetriesNewTokensWithoutAnotherRefresh() async throws {
        let fx = AuthFixture()
        fx.secrets.failWrites = true
        let first = Task { try await fx.store.current() }
        await fx.server.waitForRequest()
        await fx.server.reply()
        await #expect(throws: MuseCredentialStore.Failure.couldNotSave) { try await first.value }
        #expect(fx.secrets.credentials() == fx.original)
        await #expect(throws: MuseCredentialStore.Failure.couldNotSave) { try await fx.store.current() }
        fx.secrets.failWrites = false
        let recovered = try await fx.store.current()
        #expect(recovered.accessToken == "new-access")
        #expect(fx.secrets.credentials() == recovered)
        #expect(await fx.server.count == 1)
    }
    @Test func forgetDuringRefreshCannotResurrectPairing() async throws {
        let fx = AuthFixture()
        let first = Task { try await fx.store.current() }
        await fx.server.waitForRequest()
        #expect(await fx.store.forget())
        await fx.server.reply()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(fx.secrets.credentials() == nil)
        #expect(fx.store.pairedName.value == nil)
    }
    @Test func oldRefreshCannotOverwriteOrRejectNewPairing() async throws {
        for status in [200, 401] {
            let fx = AuthFixture()
            let first = Task { try await fx.store.current() }
            await fx.server.waitForRequest()
            var repaired = fx.original
            repaired.accessToken = "paired-again"
            repaired.refreshToken = "paired-again-refresh"
            repaired.accessTokenSavedAt = Date()
            #expect(await fx.store.replace(with: repaired))
            await fx.server.reply(status: status)
            await #expect(throws: CancellationError.self) { try await first.value }
            await fx.store.rejected(fx.original)
            #expect(fx.secrets.credentials() == repaired)
            #expect(fx.store.pairedName.value == repaired.identity.bleName)
            #expect(!fx.store.reconnectRequired.value)
        }
    }
    @Test func rejectedRefreshStopsRetryingAndOffersReconnection() async throws {
        let fx = AuthFixture()
        let first = Task { try await fx.store.current() }
        await fx.server.waitForRequest()
        await fx.server.reply(status: 401)
        await #expect(throws: MuseDeviceAPI.Failure.http(401)) { try await first.value }
        #expect(fx.store.reconnectRequired.value)
        #expect(fx.store.pairedName.value == nil)
        #expect(fx.secrets.credentials() == fx.original)
        await #expect(throws: MuseCredentialStore.Failure.pairingRejected) { try await fx.store.current() }
        #expect(await fx.server.count == 1)
        #expect(await fx.store.replace(with: fx.original))
        #expect(!fx.store.reconnectRequired.value)
    }
    @Test func serverFailureDoesNotDiscardPairing() async throws {
        let fx = AuthFixture()
        let first = Task { try await fx.store.current() }
        await fx.server.waitForRequest()
        await fx.server.reply(status: 503)
        await #expect(throws: MuseDeviceAPI.Failure.http(503)) { try await first.value }
        #expect(!fx.store.reconnectRequired.value)
        #expect(fx.store.pairedName.value != nil)
        #expect(fx.secrets.credentials() == fx.original)
    }
    @Test func failedForgetKeepsVisiblePairing() async {
        let fx = AuthFixture()
        fx.secrets.failWrites = true
        #expect(await !fx.store.forget())
        #expect(fx.store.pairedName.value == fx.original.identity.bleName)
        #expect(fx.secrets.credentials() == fx.original)
    }
}

private struct AuthFixture {
    let server = RefreshServer()
    let secrets: FailableMuseSecrets
    let original: MuseGadgetCredentials
    let store: MuseCredentialStore
    init() {
        let host = UUID().uuidString.lowercased() + ".invalid"
        original = MuseGadgetCredentials(
            identity: MuseGadgetIdentity(mac: "02:00:00:01:02:03")!,
            accessToken: "old-access", refreshToken: "hatch_refresh:old-refresh", username: "",
            apiURL: "", apiURLv2: "https://" + host, noiseHost: "",
            accessTokenSavedAt: Date().addingTimeInterval(-4 * 3600))
        secrets = FailableMuseSecrets(original)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MuseAuthURLProtocol.self]
        MuseAuthURLProtocol.register(host, server: server)
        store = MuseCredentialStore(secrets: secrets, api: MuseDeviceAPI(session: URLSession(configuration: config)))
    }
}
private actor RefreshServer {
    private(set) var count = 0
    private var pending: CheckedContinuation<(Int, Data), Never>?
    func request(_ request: URLRequest) async -> (Int, Data) {
        count += 1
        #expect(request.url?.path == "/device_token/refresh")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer hatch_refresh:old-refresh")
        return await withCheckedContinuation { pending = $0 }
    }
    func waitForRequest() async {
        for _ in 0..<200 {
            if pending != nil { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Refresh request did not arrive")
    }
    func reply(status: Int = 200) {
        pending?.resume(returning: (status, Data(#"{"access_token":"new-access","refresh_token":"new-refresh"}"#.utf8)))
        pending = nil
    }
}
private final class MuseAuthURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var servers: [String: RefreshServer] = [:]
    static func register(_ host: String, server: RefreshServer) { lock.withLock { servers[host] = server } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let server = Self.lock.withLock({ Self.servers[request.url!.host!] }) else { return }
        Task {
            let (status, data) = await server.request(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
private final class FailableMuseSecrets: MuseSecrets, @unchecked Sendable {
    private let lock = NSLock()
    private let base: InMemoryMuseSecrets
    private var failing = false
    var failWrites: Bool {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }
    init(_ credentials: MuseGadgetCredentials) { base = InMemoryMuseSecrets(identity: credentials.identity, credentials: credentials, sdkToken: "test-sdk") }
    func identity() -> MuseGadgetIdentity? { base.identity() }
    func save(identity: MuseGadgetIdentity) -> Bool { !failWrites && base.save(identity: identity) }
    func credentials() -> MuseGadgetCredentials? { base.credentials() }
    func save(credentials: MuseGadgetCredentials) -> Bool { !failWrites && base.save(credentials: credentials) }
    func removeCredentials() -> Bool { !failWrites && base.removeCredentials() }
    func sdkToken() -> String? { base.sdkToken() }
    func setSDKToken(_ token: String?) -> Bool { !failWrites && base.setSDKToken(token) }
}
