import AppDB
import Foundation
import Testing
import Transcription

@testable import Intelligence

// Follow-up extraction and curation pin a stronger model than the person's own choice — a
// deliberate product decision. A key without access to it used to fail the call, and on Remote
// first the router then handed the job to the on-device model: a silent downgrade from the
// strongest model the app uses to the weakest, for the one job the stronger one was chosen for.

private final class ModelTransport: HttpTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _models: [String] = []
    private let refused: Set<String>
    private let status: Int

    init(refusing refused: Set<String>, status: Int = 403) {
        self.refused = refused
        self.status = status
    }

    var models: [String] { lock.withLock { _models } }

    func execute(_ request: HttpTransportRequest) async throws -> HttpTransportResponse {
        let body = try JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any]
        let model = body?["model"] as? String ?? ""
        lock.withLock { _models.append(model) }
        if refused.contains(model) {
            return HttpTransportResponse(
                status: status,
                text: status == 404
                    ? #"{"error":{"code":"model_not_found","message":"The model `\#(model)` does not exist or you do not have access to it."}}"#
                    : #"{"error":{"message":"You are not allowed to sample from this model"}}"#)
        }
        return HttpTransportResponse(
            status: 200, text: #"{"output_text": "{\"items\":[]}", "model": "\#(model)-2026-09-01"}"#)
    }
}

private final class KeyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = "sk-first"
    var value: String {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

private let pinnedRequest = AiRunRequest(
    requestId: "followups-1",
    prompt: AiPromptTemplates.followUpExtraction,
    transcripts: [TranscriptExcerpt(segmentId: "prebuilt", text: "I will call Dana tomorrow.")],
    metadata: [
        AiRunRequest.modelKey: FollowUpWorker.modelId,
        AiRunRequest.reasoningEffortKey: FollowUpWorker.reasoningEffort,
        AiRunRequest.requiresStructuredOutputKey: "1",
    ])

@Suite("Follow-ups — the stronger model when the key can use it, the person's own when not")
struct FollowUpModelTests {
    @Test(arguments: [403, 404])
    func aKeyThatCannotUseThePinnedModelGetsThePersonsModelInstead(_ status: Int) async throws {
        let transport = ModelTransport(refusing: [FollowUpWorker.modelId], status: status)
        let key = KeyBox()
        let hold = CloudAccountHold(fileURL: nil, apiKey: { _ in key.value })
        let provider = OpenAiChatAiProvider(
            transport: transport, apiKey: { key.value }, remoteConsent: { true },
            model: { "gpt-5.6-luna" }, accountHold: hold)

        let first = try await provider.run(pinnedRequest)
        #expect(transport.models == [FollowUpWorker.modelId, "gpt-5.6-luna"])
        #expect(first.modelUsed == "gpt-5.6-luna-2026-09-01")
        // One model refused is not the account refused.
        #expect(hold.active(for: .openAi) == nil)

        // Remembered: the next job goes straight to the model the key can use.
        _ = try await provider.run(pinnedRequest)
        #expect(transport.models.count == 3)
        #expect(transport.models.last == "gpt-5.6-luna")

        // A different key may well be allowed the stronger model.
        key.value = "sk-second"
        _ = try await provider.run(pinnedRequest)
        #expect(transport.models.suffix(2) == [FollowUpWorker.modelId, "gpt-5.6-luna"])
    }

    /// Through the router on Remote first: answered by the cloud with the person's model, not
    /// silently by the phone.
    @Test func remoteFirstNoLongerDegradesToThePhone() async throws {
        struct Phone: AiProvider {
            let id = "apple-foundation-models"
            func isAvailable() async -> Bool { true }
            func run(_ request: AiRunRequest) async throws -> AiProviderResult {
                AiProviderResult(text: #"{"items":[]}"#, modelUsed: id)
            }
        }
        let provider = OpenAiChatAiProvider(
            transport: ModelTransport(refusing: [FollowUpWorker.modelId]),
            apiKey: { "sk-x" }, remoteConsent: { true }, model: { "gpt-5.6-luna" })
        let router = AiModeRouter(local: Phone(), remote: provider, mode: { .remoteFirst })
        let result = try await router.run(pinnedRequest)
        #expect(result.providerId == "openai-chat")
        #expect(!result.viaFallback)
    }

    /// The model that found an item travels with it onto the list, for its provenance card.
    @Test func theFindingModelIsKeptOnTheFollowUp() async throws {
        let db = try AppDatabase.inMemory()
        let candidates = FollowUpCandidateStore(db: db)
        let followUps = FollowUpStore(db: db)
        try await candidates.save(
            FollowUpCandidate(
                id: "c1", conversationId: "conv-1", segmentId: "seg-1", task: "Call Dana",
                quote: "I will call Dana tomorrow.", why: "she waits", createdAtMs: 1_000,
                model: "gpt-5.6-luna-2026-09-01"))
        #expect(try await candidates.list(conversationId: "conv-1").first?.model
            == "gpt-5.6-luna-2026-09-01")

        struct Keeper: AiProvider {
            let id = "keeper"
            func isAvailable() async -> Bool { true }
            func run(_ request: AiRunRequest) async throws -> AiProviderResult {
                AiProviderResult(
                    text: """
                        {"decisions":[{"index":1,"decision":"keep","reason":"real","task":"",
                        "priority":"normal","dueDate":""}]}
                        """)
            }
        }
        let curator = FollowUpCurator(
            candidates: candidates, followUps: followUps,
            router: AiModeRouter(local: Keeper(), remote: nil, mode: { .localOnly }),
            nowMs: { 2_000 })
        let written = try await curator.curate()
        #expect(written.first?.model == "gpt-5.6-luna-2026-09-01")
        #expect(try await followUps.load(id: "c1")?.model == "gpt-5.6-luna-2026-09-01")
        #expect(
            AiModels.displayName(modelUsed: written.first?.model) == "GPT-5.6 Luna")
    }
}
