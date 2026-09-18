import Foundation
import Testing

@testable import Intelligence

// The remote slot re-reads the setting per call, and a setting naming a provider this OS does
// not have is unavailable — never quietly the other one.

private final class CountingProvider: AiProvider, AiInputWindowReporting, @unchecked Sendable {
    let id: String
    private let available: Bool
    private let window: Int?
    private let chars: Int?
    private let lock = NSLock()
    private var _runs = 0

    init(_ id: String, available: Bool = true, window: Int? = nil, chars: Int? = nil) {
        self.id = id
        self.available = available
        self.window = window
        self.chars = chars
    }

    var runs: Int { lock.withLock { _runs } }

    func isAvailable() async -> Bool { available }

    func run(_ request: AiRunRequest) async throws -> AiProviderResult {
        lock.withLock { _runs += 1 }
        return AiProviderResult(text: "from \(id)", modelUsed: id)
    }

    func inputChars() async -> Int? { chars }
    func contextTokens() async -> Int? { window }
}

private final class Setting: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: RemoteAiProvider
    init(_ value: RemoteAiProvider) { _value = value }
    var value: RemoteAiProvider {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

@Suite("remote AI provider switch")
struct RemoteAiProviderSwitchTests {
    private let request = AiRunRequest(
        requestId: "r",
        prompt: SegmentAnnotationPrompt.template,
        transcripts: [TranscriptExcerpt(segmentId: "seg-1", text: "hello")]
    )

    @Test func followsTheSettingOnEveryCall() async throws {
        let setting = Setting(.openAi)
        let openAi = CountingProvider("openai-chat")
        let pcc = CountingProvider("apple-pcc")
        let slot = RemoteAiProviderSwitch(
            selected: { setting.value }, openAi: openAi, applePrivateCloud: pcc)

        #expect(try await slot.run(request).modelUsed == "openai-chat")
        #expect(slot.id == "openai-chat")

        setting.value = .applePrivateCloud
        #expect(try await slot.run(request).modelUsed == "apple-pcc")
        #expect(slot.id == "apple-pcc")

        setting.value = .openAi
        #expect(try await slot.run(request).modelUsed == "openai-chat")
        #expect(openAi.runs == 2)
        #expect(pcc.runs == 1)
    }

    /// iOS 26 with the setting somehow on Private Cloud Compute: unavailable, and OpenAI is
    /// never touched. Sending transcripts to a provider the person did not choose is the one
    /// thing the slot exists to make impossible.
    @Test func aProviderThisOsLacksIsUnavailableNeverTheOtherOne() async throws {
        let openAi = CountingProvider("openai-chat")
        let slot = RemoteAiProviderSwitch(
            selected: { .applePrivateCloud }, openAi: openAi, applePrivateCloud: nil)

        #expect(await slot.isAvailable() == false)
        #expect(slot.id == "apple-pcc")
        do {
            _ = try await slot.run(request)
            Issue.record("expected providerUnavailable")
        } catch AiError.providerUnavailable(let id) {
            #expect(id == "apple-pcc")
        }
        #expect(openAi.runs == 0)
    }

    @Test func availabilityIsTheSelectedProviders() async {
        let slot = RemoteAiProviderSwitch(
            selected: { .applePrivateCloud },
            openAi: CountingProvider("openai-chat", available: true),
            applePrivateCloud: CountingProvider("apple-pcc", available: false))
        #expect(await slot.isAvailable() == false)
    }

    @Test func theWindowReportIsTheSelectedProviders() async {
        let setting = Setting(.openAi)
        let slot = RemoteAiProviderSwitch(
            selected: { setting.value },
            openAi: CountingProvider("openai-chat"),
            applePrivateCloud: CountingProvider("apple-pcc", window: 32_768))
        #expect(await slot.contextTokens() == nil)
        setting.value = .applePrivateCloud
        #expect(await slot.contextTokens() == 32_768)
    }

    // MARK: The router relays what each slot can take

    @Test func theRouterRelaysTheLocalCeilingAndTheRemoteWindow() async {
        let onDevice = OnDeviceAiProvider(model: WideFakeModel())
        let router = AiModeRouter(
            local: onDevice,
            remote: CountingProvider("apple-pcc", window: 32_768),
            mode: { .localFirst })
        #expect(await router.localInputChars() == 16_000)
        #expect(await router.remoteContextTokens() == 32_768)
    }

    @Test func theRouterReportsNothingForProvidersThatCannotSay() async {
        struct Mute: AiProvider {
            let id = "mute"
            func isAvailable() async -> Bool { true }
            func run(_ request: AiRunRequest) async throws -> AiProviderResult {
                AiProviderResult(text: "x")
            }
        }
        let router = AiModeRouter(local: Mute(), remote: Mute(), mode: { .localFirst })
        #expect(await router.localInputChars() == nil)
        #expect(await router.remoteContextTokens() == nil)
        let empty = AiModeRouter(local: nil, remote: nil, mode: { .localFirst })
        #expect(await empty.localInputChars() == nil)
        #expect(await empty.remoteContextTokens() == nil)
    }
}

private struct WideFakeModel: OnDeviceLanguageModel {
    let id = "wide"
    func availability() async -> OnDeviceAvailability { .available }
    func contextWindowTokens() async -> Int { 8_192 }
    func generate(instructions: String, prompt: String, maxOutputTokens: Int?) async throws
        -> String
    { "ok" }
}
