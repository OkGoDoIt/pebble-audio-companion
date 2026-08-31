import AVFAudio
import Foundation
import Testing

@testable import Transcription

// Hermetic tests for the M3 local speech-to-text stack (SpeechAnalyzer engine): provider
// availability against a faked asset inventory, PCM → AVAudioPCMBuffer conversion, NoSpeech
// mapping, the live accumulator, and the LocalModelManager state machine. Live recognizer
// calls are deliberately NOT made here (simulator/macOS hosts may lack language assets — the
// M6 on-device gate covers real recognition quality).

// MARK: - Fakes

private final class FakeInventory: SpeechAssetInventorying, @unchecked Sendable {
    var statusValue: SpeechAssetStatus
    var installRequest: FakeInstall?
    var installationRequests = 0
    var releases = 0

    init(status: SpeechAssetStatus, installRequest: FakeInstall? = nil) {
        self.statusValue = status
        self.installRequest = installRequest
    }

    func status(for locale: Locale) async -> SpeechAssetStatus { statusValue }

    func installationRequest(for locale: Locale) async throws -> (any SpeechAssetInstalling)? {
        installationRequests += 1
        return installRequest
    }

    func release(locale: Locale) async {
        releases += 1
        statusValue = .supported
    }
}

private final class FakeInstall: SpeechAssetInstalling, @unchecked Sendable {
    let progressValues: [Double]
    let failure: Error?
    /// Status the paired inventory flips to after a successful install.
    let onSuccess: (() -> Void)?

    init(progressValues: [Double], failure: Error? = nil, onSuccess: (() -> Void)? = nil) {
        self.progressValues = progressValues
        self.failure = failure
        self.onSuccess = onSuccess
    }

    func install() -> AsyncThrowingStream<Double, Error> {
        AsyncThrowingStream { continuation in
            for value in progressValues {
                continuation.yield(value)
            }
            if let failure {
                continuation.finish(throwing: failure)
            } else {
                onSuccess?()
                continuation.finish()
            }
        }
    }
}

private struct FakeInstallError: Error {}

// MARK: - PCM conversion

@Suite struct LocalSpeechPcmTests {
    @Test func convertsS16leMonoChunkToInt16Buffer() throws {
        let sampleCount = 320
        var samples = [Int16]()
        for index in 0..<sampleCount {
            samples.append(Int16(index * 100 - 16_000))
        }
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        let format = try #require(LocalSpeechPcm.format(sampleRateHz: 16_000))

        let buffer = try #require(LocalSpeechPcm.makeBuffer(data: data, format: format))

        #expect(buffer.frameLength == 320)
        #expect(buffer.format.sampleRate == 16_000)
        #expect(buffer.format.channelCount == 1)
        #expect(buffer.format.commonFormat == .pcmFormatInt16)
        let channel = try #require(buffer.int16ChannelData?[0])
        #expect(channel[0] == -16_000)
        #expect(channel[160] == 0)
        #expect(channel[319] == 15_900)
    }

    @Test func dropsTornTrailingByte() throws {
        let format = try #require(LocalSpeechPcm.format(sampleRateHz: 16_000))
        let data = Data([0x01, 0x02, 0x03, 0x04, 0x05])  // 2 whole samples + 1 torn byte

        let buffer = try #require(LocalSpeechPcm.makeBuffer(data: data, format: format))

        #expect(buffer.frameLength == 2)
    }

    @Test func rejectsEmptyAndSubSampleData() throws {
        let format = try #require(LocalSpeechPcm.format(sampleRateHz: 16_000))
        #expect(LocalSpeechPcm.makeBuffer(data: Data(), format: format) == nil)
        #expect(LocalSpeechPcm.makeBuffer(data: Data([0x7F]), format: format) == nil)
        #expect(LocalSpeechPcm.format(sampleRateHz: 0) == nil)
    }
}

// MARK: - Transcript text mapping (NoSpeech contract)

@Suite struct LocalSpeechTextTests {
    @Test func joinInsertsSpacesOnlyWhereNeitherSideProvidesOne() {
        #expect(localSpeechJoin(["Hello", "world"]) == "Hello world")
        #expect(localSpeechJoin(["Hello ", "world"]) == "Hello world")
        #expect(localSpeechJoin(["Hello", " world"]) == "Hello world")
        #expect(localSpeechJoin(["Hello", ", world"]) == "Hello, world")
        #expect(localSpeechJoin(["", "world"]) == "world")
    }

    @Test func blankFinalTranscriptMapsToNoSpeech() {
        #expect(localSpeechFinalText([]) == nil)
        #expect(localSpeechFinalText(["", "  ", "\n"]) == nil)
        #expect(localSpeechFinalText(["Hello ", "world."]) == "Hello world.")
    }
}

// MARK: - Provider availability (faked asset state; no live Speech calls)

@Suite struct SpeechAnalyzerProviderTests {
    @Test func availabilityRequiresInstalledAssets() async {
        let installed = SpeechAnalyzerProvider(inventory: FakeInventory(status: .installed))
        let supported = SpeechAnalyzerProvider(inventory: FakeInventory(status: .supported))
        let unsupported = SpeechAnalyzerProvider(inventory: FakeInventory(status: .unsupported))

        #expect(await installed.isAvailable())
        #expect(!(await supported.isAvailable()))
        #expect(!(await unsupported.isAvailable()))
        #expect(installed.id == "speechanalyzer")
    }

    @Test func transcribeFailsClosedWhenAssetsAreMissing() async {
        let provider = SpeechAnalyzerProvider(inventory: FakeInventory(status: .supported))

        do {
            _ = try await provider.transcribe(pcmChunks: pcmStream([]), sampleRateHz: 16_000)
            Issue.record("expected providerUnavailable")
        } catch let error as TranscriptionError {
            guard case .providerUnavailable(let providerId) = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
            #expect(providerId == "speechanalyzer")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func liveStreamFailsClosedWhenAssetsAreMissing() async {
        let provider = LiveSpeechAnalyzerProvider(inventory: FakeInventory(status: .supported))
        #expect(!(await provider.isAvailable()))

        do {
            for try await _ in provider.transcribeStream(pcm: pcmStream([]), sampleRateHz: 16_000) {
                Issue.record("expected no updates")
            }
            Issue.record("expected providerUnavailable")
        } catch let error as TranscriptionError {
            guard case .providerUnavailable(let providerId) = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
            #expect(providerId == "speechanalyzer")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}

// MARK: - Live accumulator

@Suite struct LiveTranscriptAccumulatorTests {
    @Test func volatileHypothesesReplaceThePartialTail() {
        var accumulator = LiveTranscriptAccumulator()

        let first = accumulator.applyVolatile("hel")
        #expect(first.finalText == "")
        #expect(first.partialText == "hel")
        #expect(first.isFinal == false)

        let second = accumulator.applyVolatile("hello wor")
        #expect(second.partialText == "hello wor")
        #expect(second.displayText == "hello wor")
    }

    @Test func finalizedResultsBecomeStableTextAndClearThePartial() {
        var accumulator = LiveTranscriptAccumulator()
        _ = accumulator.applyVolatile("hello wor")

        let update = accumulator.applyFinal(
            "hello world.",
            segment: TranscriptSegment(text: "hello world.", startMs: 0, endMs: 1_200)
        )

        #expect(update.finalText == "hello world.")
        #expect(update.partialText == "")
        #expect(update.segments == [TranscriptSegment(text: "hello world.", startMs: 0, endMs: 1_200)])
        #expect(update.isFinal == false)

        let finished = accumulator.finished()
        #expect(finished.finalText == "hello world.")
        #expect(finished.partialText == "")
        #expect(finished.isFinal)
    }
}

// MARK: - LocalModelManager state machine

@Suite struct LocalModelManagerTests {
    @Test func unsupportedLocaleReportsUnsupported() async {
        let manager = LocalModelManager(inventory: FakeInventory(status: .unsupported))
        #expect(await manager.refresh() == .unsupported)
        #expect(await manager.requestInstall() == .unsupported)
    }

    @Test func installFlowReportsProgressThenInstalled() async {
        let inventory = FakeInventory(status: .supported)
        inventory.installRequest = FakeInstall(
            progressValues: [0.25, 0.75],
            onSuccess: { inventory.statusValue = .installed }
        )
        let manager = LocalModelManager(inventory: inventory)
        let states = await manager.states()

        let final = await manager.requestInstall()
        #expect(final == .installed)
        #expect(await manager.currentState() == .installed)
        #expect(inventory.installationRequests == 1)

        var observed: [LocalModelState] = []
        for await state in states {
            observed.append(state)
            if observed.count == 5 { break }
        }
        #expect(
            observed == [
                .notInstalled,
                .downloading(progress: 0),
                .downloading(progress: 0.25),
                .downloading(progress: 0.75),
                .installed,
            ]
        )
    }

    @Test func installFailureReportsCalmRetryableFailure() async {
        let inventory = FakeInventory(status: .supported)
        inventory.installRequest = FakeInstall(progressValues: [0.5], failure: FakeInstallError())
        let manager = LocalModelManager(inventory: inventory)

        let final = await manager.requestInstall()
        guard case .failed(let message) = final else {
            Issue.record("expected failed, got \(final)")
            return
        }
        #expect(message.contains("try again"))
        // The failure message stays visible across a refresh that still reports downloadable.
        #expect(await manager.refresh() == final)
    }

    @Test func wifiOnlyPreferenceDefersTheDownload() async {
        let inventory = FakeInventory(
            status: .supported, installRequest: FakeInstall(progressValues: [1])
        )
        let manager = LocalModelManager(
            inventory: inventory,
            wifiOnly: { true },
            isOnWiFi: { false }
        )

        #expect(await manager.requestInstall() == .waitingForWiFi)
        #expect(inventory.installationRequests == 0)
    }

    @Test func alreadyInstalledShortCircuitsWithoutARequest() async {
        let inventory = FakeInventory(status: .installed)
        let manager = LocalModelManager(inventory: inventory)

        #expect(await manager.requestInstall() == .installed)
        #expect(inventory.installationRequests == 0)
    }

    @Test func nilInstallationRequestMeansAssetsAlreadyPresent() async {
        let inventory = FakeInventory(status: .supported, installRequest: nil)
        let manager = LocalModelManager(inventory: inventory)

        #expect(await manager.requestInstall() == .installed)
        #expect(inventory.installationRequests == 1)
    }

    @Test func uninstallReleasesTheLocaleReservation() async {
        let inventory = FakeInventory(status: .installed)
        let manager = LocalModelManager(inventory: inventory)
        _ = await manager.refresh()

        #expect(await manager.uninstall() == .notInstalled)
        #expect(inventory.releases == 1)
    }
}
