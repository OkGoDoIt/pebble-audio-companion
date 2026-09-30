import Foundation
import Testing

@testable import Transcription

// The cloud account hold (2026-09-29): a provider that refused the ACCOUNT is sent nothing more,
// by any path, until something changes that could make it answer differently.

private final class Keys: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [CloudProvider: String] = [.soniox: "soniox-key-1", .openAi: "openai-key"]
    func key(_ provider: CloudProvider) -> String? { lock.withLock { stored[provider] } }
    func set(_ provider: CloudProvider, _ key: String?) { lock.withLock { stored[provider] = key } }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var ms: Int64 = 1_000_000_000
    var now: Int64 { lock.withLock { ms } }
    func advance(_ by: Int64) { lock.withLock { ms += by } }
}

private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var all: [String] { lock.withLock { stored } }
    func append(_ line: String) { lock.withLock { stored.append(line) } }
}

private let outOfFunds =
    "Soniox create transcription failed (402): {\"error\":\"Organization balance exhausted. "
    + "Please either add funds manually or enable autopay.\"}"

private func makeHold(
    file: URL? = nil, keys: Keys = Keys(), clock: Clock = Clock(), lines: Lines = Lines()
) -> CloudAccountHold {
    CloudAccountHold(
        fileURL: file, apiKey: { keys.key($0) }, nowMs: { clock.now }, log: { lines.append($0) })
}

@Suite struct CloudAccountHoldTests {
    @Test func onlyARefusalOfTheAccountHolds() {
        let hold = makeHold()
        for kind: TranscriptionFailureKind in [
            .rateLimited, .noConnection, .providerTrouble, .timedOut, .recordingTooLong,
            .providerRefusedAudio, .unknown,
        ] {
            #expect(hold.trip(kind, provider: .soniox) == false)
        }
        #expect(hold.active(for: .soniox) == nil)

        #expect(hold.noteFailure(outOfFunds, provider: .soniox))
        #expect(hold.active(for: .soniox)?.kind == .accountOutOfFunds)
        // The same refusal again is the same hold, not a new one.
        #expect(hold.noteFailure(outOfFunds, provider: .soniox) == false)
        #expect(hold.trip(.keyRejected, provider: .openAi))
        #expect(hold.active(for: .openAi)?.kind == .keyRejected)
    }

    @Test func holdsArePerProviderAndNeedAKey() {
        let keys = Keys()
        keys.set(.openAi, nil)
        let hold = makeHold(keys: keys)
        #expect(hold.trip(.accountOutOfFunds, provider: .openAi) == false)  // no key, nothing to hold
        #expect(hold.trip(.accountOutOfFunds, provider: .soniox))
        #expect(hold.active(for: .openAi) == nil)
    }

    /// iOS relaunches the process many times a day; a hold that did not survive one would be
    /// rediscovered with a full upload each time.
    @Test func theHoldSurvivesARelaunchAndNothingIsLeftOnceLifted() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hold-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("cloud_account_hold.json")
        let keys = Keys()

        makeHold(file: file, keys: keys).noteFailure(outOfFunds, provider: .soniox)
        let relaunched = makeHold(file: file, keys: keys)
        #expect(relaunched.active(for: .soniox)?.kind == .accountOutOfFunds)
        // The key itself is never written down.
        let onDisk = try String(contentsOf: file, encoding: .utf8)
        #expect(onDisk.contains("soniox-key-1") == false)

        #expect(relaunched.noteSuccess(provider: .soniox))
        #expect(FileManager.default.fileExists(atPath: file.path) == false)
        #expect(makeHold(file: file, keys: keys).active(for: .soniox) == nil)
    }

    /// A different key is a different account (or a fixed one): the hold said nothing about it.
    @Test func replacingTheKeyReleasesTheHold() {
        let keys = Keys()
        let lines = Lines()
        let hold = makeHold(keys: keys, lines: lines)
        hold.noteFailure(outOfFunds, provider: .soniox)
        keys.set(.soniox, "soniox-key-2")
        #expect(hold.active(for: .soniox) == nil)
        #expect(lines.all.contains { $0.contains("API key it was for has changed") })
        keys.set(.soniox, "soniox-key-1")
        #expect(hold.active(for: .soniox) == nil)  // released, not suspended
    }

    @Test func aSuccessLiftsTheHoldAndSaysSoOnce() {
        final class Lifted: @unchecked Sendable {
            let lock = NSLock()
            var providers: [CloudProvider] = []
        }
        let lifted = Lifted()
        let lines = Lines()
        let hold = makeHold(lines: lines)
        hold.onLifted { provider in lifted.lock.withLock { lifted.providers.append(provider) } }

        #expect(hold.noteSuccess(provider: .soniox) == false)  // nothing held: nothing to say
        hold.noteFailure(outOfFunds, provider: .soniox)
        #expect(hold.noteSuccess(provider: .soniox))
        #expect(hold.noteSuccess(provider: .soniox) == false)
        #expect(lifted.lock.withLock { lifted.providers } == [.soniox])
        #expect(lines.all.contains { $0.contains("accepting work again") })
    }

    @Test func probesBackOffFromFifteenMinutesToSixHours() {
        #expect(
            (0...7).map { CloudAccountHold.probeDelayMs(afterRefusedProbes: $0) / 60_000 }
                == [15, 30, 60, 120, 240, 360, 360, 360])

        let clock = Clock()
        let hold = makeHold(clock: clock)
        hold.noteFailure(outOfFunds, provider: .soniox)
        clock.advance(14 * 60_000)
        #expect(hold.isProbeDue(provider: .soniox, foreground: false) == false)
        clock.advance(60_000)
        #expect(hold.isProbeDue(provider: .soniox, foreground: false))

        hold.recordRefusedProbe(provider: .soniox, kind: .accountOutOfFunds)
        #expect(hold.active(for: .soniox)?.refusedProbes == 1)
        clock.advance(29 * 60_000)
        #expect(hold.isProbeDue(provider: .soniox, foreground: false) == false)
        clock.advance(60_000)
        #expect(hold.isProbeDue(provider: .soniox, foreground: false))

        // Could not tell: soon again, without escalating.
        hold.recordInconclusiveProbe(provider: .soniox)
        #expect(hold.active(for: .soniox)?.refusedProbes == 1)
        clock.advance(CloudAccountHold.inconclusiveProbeDelayMs)
        #expect(hold.isProbeDue(provider: .soniox, foreground: false))
    }

    /// Opening the app is when someone who just topped up is looking.
    @Test func theForegroundChecksSoonerThanTheBackoff() {
        let clock = Clock()
        let hold = makeHold(clock: clock)
        hold.noteFailure(outOfFunds, provider: .soniox)
        for _ in 0..<4 { hold.recordRefusedProbe(provider: .soniox, kind: .accountOutOfFunds) }
        clock.advance(CloudAccountHold.foregroundProbeIntervalMs - 1)
        #expect(hold.isProbeDue(provider: .soniox, foreground: true) == false)
        clock.advance(1)
        #expect(hold.isProbeDue(provider: .soniox, foreground: true))
        #expect(hold.isProbeDue(provider: .soniox, foreground: false) == false)
    }

    /// The paused message is stored as a task's lastError and read back through `classify`, so
    /// it must classify as the hold's own kind.
    @Test func pausedMessagesClassifyAsTheHoldsOwnKind() {
        for kind in CloudAccountHold.holdingKinds {
            let hold = CloudAccountHold.Hold(
                provider: .soniox, keyFingerprint: "x", kind: kind, sinceMs: 0, refusedProbes: 0,
                lastProbeMs: nil, nextProbeAtMs: 0)
            #expect(TranscriptionFailureKind.classify(CloudAccountHold.pausedMessage(hold)) == kind)
        }
    }
}

// MARK: - The gate on the providers

private final class Backend: TranscriptionProvider, @unchecked Sendable {
    let id: String
    private let lock = NSLock()
    private var failure: Error?
    private var calls = 0
    private var bytes = 0

    init(_ id: String, failure: Error? = nil) {
        self.id = id
        self.failure = failure
    }

    var callCount: Int { lock.withLock { calls } }
    var bytesReceived: Int { lock.withLock { bytes } }
    func fail(with error: Error?) { lock.withLock { failure = error } }

    func isAvailable() async -> Bool { true }

    func transcribe(
        pcmChunks: AsyncThrowingStream<Data, Error>, sampleRateHz: Int
    ) async throws -> TranscriptionResult {
        var received = 0
        for try await chunk in pcmChunks { received += chunk.count }
        let error = lock.withLock { () -> Error? in
            calls += 1
            bytes += received
            return failure
        }
        if let error { throw error }
        return TranscriptionResult(text: "words", providerId: id, modelUsed: "m")
    }
}

private func audio() -> AsyncThrowingStream<Data, Error> {
    AsyncThrowingStream { continuation in
        continuation.yield(Data(repeating: 7, count: 640))
        continuation.finish()
    }
}

@Suite struct CloudAccountGateTests {
    private func gate(_ soniox: Backend, hold: CloudAccountHold) -> SelectableCloudTranscriptionProvider {
        SelectableCloudTranscriptionProvider(
            selected: { .soniox }, openAi: Backend("openai"), soniox: soniox, hold: hold)
    }

    /// The 09-29 shape: one refusal, and then nothing more is sent — the provider reports itself
    /// unavailable (so the queue parks cloud-only work) and says why.
    @Test func oneRefusalAndNothingMoreIsSent() async throws {
        let soniox = Backend(
            "soniox", failure: TranscriptionError.transcriptionFailed(outOfFunds))
        let hold = makeHold()
        let cloud = gate(soniox, hold: hold)

        await #expect(throws: TranscriptionError.self) {
            _ = try await cloud.transcribe(pcmChunks: audio(), sampleRateHz: 16_000)
        }
        #expect(cloud.isSendingHeld)
        #expect(await cloud.isAvailable() == false)
        #expect(
            TranscriptionFailureKind.classify(await cloud.unavailabilityReason())
                == .accountOutOfFunds)

        await #expect(throws: TranscriptionError.self) {
            _ = try await cloud.transcribe(pcmChunks: audio(), sampleRateHz: 16_000)
        }
        #expect(soniox.callCount == 1)

        // A cloud-only router parks instead of trying.
        let router = TranscriptionModeRouter(local: nil, remote: cloud, mode: { .remoteOnly })
        #expect(await router.isAvailable() == false)
    }

    /// Busy is not broke: a rate limit never holds.
    @Test func aRateLimitDoesNotHold() async {
        let soniox = Backend(
            "soniox", failure: TranscriptionError.transcriptionFailed("Soniox poll failed (429): slow down"))
        let cloud = gate(soniox, hold: makeHold())
        _ = try? await cloud.transcribe(pcmChunks: audio(), sampleRateHz: 16_000)
        #expect(cloud.isSendingHeld == false)
    }

    @Test func aProbeSendsOneSecondAndLiftsTheHoldWhenAccepted() async {
        let soniox = Backend(
            "soniox", failure: TranscriptionError.transcriptionFailed(outOfFunds))
        let hold = makeHold()
        let cloud = gate(soniox, hold: hold)
        hold.noteFailure(outOfFunds, provider: .soniox)

        #expect(await cloud.probeAccount(.soniox) == .refused(.accountOutOfFunds))
        #expect(soniox.bytesReceived == 32_000)
        #expect(hold.active(for: .soniox)?.refusedProbes == 1)

        // Topped up: the provider transcribes the silence and finds nothing — which only an
        // account that pays for transcription does.
        soniox.fail(with: TranscriptionError.noSpeechDetected("Soniox returned no speech"))
        #expect(await cloud.probeAccount(.soniox) == .accepted)
        #expect(cloud.isSendingHeld == false)
        #expect(await cloud.isAvailable())
    }

    @Test func aProbeThatCannotTellDoesNotEscalate() async {
        let soniox = Backend("soniox", failure: URLError(.notConnectedToInternet))
        let hold = makeHold()
        hold.noteFailure(outOfFunds, provider: .soniox)
        let outcome = await gate(soniox, hold: hold).probeAccount(.soniox)
        guard case .inconclusive = outcome else {
            Issue.record("expected inconclusive, got \(outcome)")
            return
        }
        #expect(hold.active(for: .soniox)?.refusedProbes == 0)
    }

    /// The 2026-09-30 shape: a Soniox project's monthly budget runs out mid-backlog. The first
    /// refusal holds the account — it used to read as provider trouble, and the uploader kept
    /// sending full recordings into it — and a probe that meets the same words is a refusal
    /// that backs off, not an "inconclusive" that retries every 15 minutes.
    @Test func aSpendingLimitHoldsOnTheFirstRefusalAndProbesBackOff() async {
        let budget =
            "Soniox transcription error: Project monthly budget exhausted. Please increase it."
        let soniox = Backend("soniox", failure: TranscriptionError.transcriptionFailed(budget))
        let hold = makeHold()
        let cloud = gate(soniox, hold: hold)

        await #expect(throws: TranscriptionError.self) {
            _ = try await cloud.transcribe(pcmChunks: audio(), sampleRateHz: 16_000)
        }
        #expect(hold.active(for: .soniox)?.kind == .spendingLimitReached)
        #expect(await cloud.isAvailable() == false)
        #expect(
            TranscriptionFailureKind.classify(await cloud.unavailabilityReason())
                == .spendingLimitReached)

        #expect(await cloud.probeAccount(.soniox) == .refused(.spendingLimitReached))
    }

    /// A probe run with no hold in force — Test Connection — starts one when refused.
    @Test func aRefusedProbeWithNoHoldStartsOne() async {
        let soniox = Backend(
            "soniox", failure: TranscriptionError.transcriptionFailed(outOfFunds))
        let hold = makeHold()
        #expect(await gate(soniox, hold: hold).probeAccount(.soniox) == .refused(.accountOutOfFunds))
        #expect(hold.active(for: .soniox)?.kind == .accountOutOfFunds)
    }

    @Test func theLiveSocketIsUnavailableWhileHeld() async {
        final class Streaming: StreamingTranscriptionProvider, @unchecked Sendable {
            let id = "soniox-rt"
            func isAvailable() async -> Bool { true }
            func transcribeStream(pcm: AsyncThrowingStream<Data, Error>, sampleRateHz: Int)
                -> AsyncThrowingStream<StreamingTranscriptUpdate, Error>
            {
                AsyncThrowingStream { $0.finish() }
            }
        }
        let hold = makeHold()
        let live = SelectableStreamingTranscriptionProvider(
            selected: { .soniox }, openAi: Streaming(), soniox: Streaming(), hold: hold)
        #expect(await live.isAvailable())
        live.noteFailureKind(.accountOutOfFunds)
        #expect(await live.isAvailable() == false)
        #expect(hold.active(for: .soniox)?.kind == .accountOutOfFunds)
    }
}

// MARK: - "Upload Audio: Wi-Fi Only" on the immediate-send paths

@Suite struct UploadNetworkPolicyTests {
    private final class Flag: @unchecked Sendable {
        var value: Bool
        init(_ value: Bool) { self.value = value }
    }

    /// On a network the user has not allowed audio on, the batch provider is unavailable for
    /// anything that would send NOW (so Cloud-first uses on-device, Cloud-only parks) — but the
    /// background uploader may still enqueue, because iOS holds a Wi-Fi-only request until
    /// Wi-Fi appears even with the app suspended.
    @Test func aDisallowedNetworkParksImmediateSendsButNotBackgroundUploads() async {
        let allowed = Flag(false)
        let soniox = Backend("soniox")
        let cloud = SelectableCloudTranscriptionProvider(
            selected: { .soniox }, openAi: Backend("openai"), soniox: soniox,
            hold: CloudAccountHold(fileURL: nil, apiKey: { _ in "key" }),
            uploadAllowedNow: { allowed.value })

        #expect(await cloud.isAvailable() == false)
        #expect(await cloud.isAvailableForBackgroundUpload())
        #expect(
            TranscriptionFailureKind.classify(await cloud.unavailabilityReason()) == .noConnection)
        // Not even the one-second account probe goes out.
        guard case .inconclusive = await cloud.probeAccount(.soniox) else {
            Issue.record("expected an inconclusive probe")
            return
        }
        #expect(soniox.callCount == 0)

        allowed.value = true
        #expect(await cloud.isAvailable())
    }

    /// A live socket IS an audio upload.
    @Test func theLiveSocketHonoursTheChoiceToo() async {
        final class Streaming: StreamingTranscriptionProvider, @unchecked Sendable {
            let id = "soniox-rt"
            func isAvailable() async -> Bool { true }
            func transcribeStream(pcm: AsyncThrowingStream<Data, Error>, sampleRateHz: Int)
                -> AsyncThrowingStream<StreamingTranscriptUpdate, Error>
            {
                AsyncThrowingStream { $0.finish() }
            }
        }
        let allowed = Flag(false)
        let live = SelectableStreamingTranscriptionProvider(
            selected: { .soniox }, openAi: Streaming(), soniox: Streaming(),
            uploadAllowedNow: { allowed.value })
        #expect(await live.isAvailable() == false)
        allowed.value = true
        #expect(await live.isAvailable())
    }
}

/// Captures the request the session actually hands to the network layer.
final class CapturingURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var captured: [URLRequest] = []
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock { Self.captured.append(request) }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct AudioRequestNetworkTests {
    /// The foreground transport stamps the Wi-Fi-only restriction onto requests that carry audio
    /// — and only onto those: create/poll/fetch are a few hundred bytes and must still work on
    /// cellular to finish an upload that already happened.
    @Test func audioRequestsCarryTheUserChoiceAndControlCallsDoNot() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CapturingURLProtocol.self]
        let transport = URLSessionHttpTransport(
            session: URLSession(configuration: configuration), audioNetwork: { .wifiOnly })
        CapturingURLProtocol.lock.withLock { CapturingURLProtocol.captured = [] }

        _ = try await transport.execute(
            HttpTransportRequest(
                method: "POST", url: "https://example.invalid/v1/files", body: Data([1, 2, 3]),
                carriesAudio: true))
        _ = try await transport.execute(
            HttpTransportRequest(method: "GET", url: "https://example.invalid/v1/transcriptions/1"))

        let captured = CapturingURLProtocol.lock.withLock { CapturingURLProtocol.captured }
        #expect(captured.count == 2)
        #expect(captured[0].allowsCellularAccess == false)
        #expect(captured[0].allowsExpensiveNetworkAccess == false)
        #expect(captured[0].allowsConstrainedNetworkAccess == false)
        #expect(captured[1].allowsCellularAccess)
    }
}
