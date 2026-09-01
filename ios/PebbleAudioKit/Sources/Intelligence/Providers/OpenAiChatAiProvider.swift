import Foundation
import Transcription

// Port of `core/ai/.../OpenAiChatAiProvider.kt`. The KMP provider took a ktor `HttpClient`;
// here the Transcription module's injected `HttpTransport` plays that role so tests run
// hermetically (same seam the cloud STT providers use).

/// Remote AI provider over OpenAI's Responses API (`/v1/responses`).
///
/// Fail-closed: transcripts leave the phone only when the user has enabled remote AI consent
/// and provided an API key; otherwise the provider reports unavailable and refuses to run.
/// Input is durable transcript text only — never audio, never live BLE data.
public final class OpenAiChatAiProvider: AiProvider, @unchecked Sendable {
    public static let defaultEndpointUrl = "https://api.openai.com/v1/responses"
    public static let defaultModel = AiModels.defaultModelId
    public static let defaultReasoningEffort = "low"
    /// Last-resort ceiling for a model whose window we do not know. Real ceilings come from
    /// the catalog via `maxInputChars` below — a fixed 240_000 here silently cut a
    /// million-token model's input to a tenth of what it could hold, chronologically from the
    /// START, so the newest transcripts were the ones dropped.
    public static let defaultMaxInputChars =
        AiModels.conservativeContextTokens * AskBudget.charsPerToken

    public let id = "openai-chat"

    private let transport: HttpTransport
    private let apiKey: @Sendable () -> String?
    private let remoteConsent: @Sendable () -> Bool
    private let model: @Sendable () -> String
    private let endpointUrl: String
    /// Resolved per call from the selected model, so this backstop always sits ABOVE what
    /// `AskBudget` planned to send and truncation stays a genuine last resort rather than an
    /// invisible second budget that contradicts the coverage the prompt claims.
    private let maxInputChars: @Sendable () -> Int
    private let grounding: @Sendable () -> String?
    private let reasoningEffort: String

    public init(
        transport: HttpTransport,
        apiKey: @escaping @Sendable () -> String?,
        remoteConsent: @escaping @Sendable () -> Bool,
        model: @escaping @Sendable () -> String = { OpenAiChatAiProvider.defaultModel },
        endpointUrl: String = OpenAiChatAiProvider.defaultEndpointUrl,
        maxInputChars: (@Sendable () -> Int)? = nil,
        grounding: @escaping @Sendable () -> String? = { nil },
        reasoningEffort: String = OpenAiChatAiProvider.defaultReasoningEffort
    ) {
        self.transport = transport
        self.apiKey = apiKey
        self.remoteConsent = remoteConsent
        self.model = model
        self.endpointUrl = endpointUrl
        self.maxInputChars =
            maxInputChars ?? { AiModels.byId(model()).contextTokens * AskBudget.charsPerToken }
        self.grounding = grounding
        self.reasoningEffort = reasoningEffort
    }

    public func isAvailable() async -> Bool {
        guard remoteConsent() else { return false }
        guard let key = apiKey() else { return false }
        return !key.isBlank
    }

    public func run(_ request: AiRunRequest) async throws -> AiProviderResult {
        guard remoteConsent() else {
            throw AiError.consentRequired(providerId: id)
        }
        guard let key = apiKey(), !key.isBlank else {
            throw AiError.providerUnavailable(providerId: id)
        }

        let userContent = AiTranscriptFormatting.buildUserContent(
            request, maxInputChars: maxInputChars())
        let instructions = buildInstructions(request.prompt.systemPrompt)

        var payload: [String: Any] = [
            "model": model(),
            "instructions": instructions,
            "input": userContent,
            "reasoning": ["effort": reasoningEffort],
        ]
        if let textConfig = responseTextConfig(for: request.prompt) {
            payload["text"] = textConfig
        }
        let body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])

        let response = try await transport.execute(
            HttpTransportRequest(
                method: "POST",
                url: endpointUrl,
                headers: [
                    "Authorization": "Bearer \(key)",
                    "Content-Type": "application/json",
                ],
                body: body
            ))
        guard response.status == 200 else {
            throw AiError.providerFailed(
                "OpenAI responses request failed (\(response.status)): "
                    + String(response.text.prefix(240)))
        }
        let parsed = try decodeResponse(response.body)
        let text = (parsed.outputText() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw AiError.providerFailed("OpenAI responses returned an empty completion")
        }
        return AiProviderResult(
            text: text,
            modelUsed: parsed.model ?? model(),
            inputTokens: parsed.usage?.inputTokens,
            outputTokens: parsed.usage?.outputTokens
        )
    }

    private func decodeResponse(_ data: Data) throws -> ResponsesResponse {
        do {
            return try JSONDecoder().decode(ResponsesResponse.self, from: data)
        } catch {
            throw AiError.providerFailed(
                "OpenAI responses payload could not be parsed", underlying: error)
        }
    }

    private func buildInstructions(_ systemPrompt: String) -> String {
        guard
            let groundingBlock = grounding()?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !groundingBlock.isEmpty
        else { return systemPrompt }
        return "\(groundingBlock)\n\n\(systemPrompt)"
    }

    // MARK: - Structured output formats

    private func responseTextConfig(for prompt: AiPromptTemplate) -> [String: Any]? {
        switch prompt.id {
        case AiPromptTemplates.actionItems.id:
            return ["format": jsonSchemaFormat(name: "action_items", schema: actionItemsSchema())]
        case SegmentAnnotationPrompt.templateId, SegmentAnnotationPrompt.liveTemplateId:
            return [
                "format": jsonSchemaFormat(
                    name: "segment_annotation", schema: segmentAnnotationSchema())
            ]
        default:
            return nil
        }
    }

    private func jsonSchemaFormat(name: String, schema: [String: Any]) -> [String: Any] {
        [
            "type": "json_schema",
            "name": name,
            "schema": schema,
            "strict": true,
        ]
    }

    private func segmentAnnotationSchema() -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "required": ["title", "summary", "tags"],
            "properties": [
                "title": schemaString("Specific plain title, at most 8 words."),
                "summary": schemaString("One to three concise factual sentences."),
                "tags": [
                    "type": "array",
                    "items": schemaString("Short reusable topic tag or proper noun."),
                ],
            ],
        ]
    }

    private func actionItemsSchema() -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "required": ["items"],
            "properties": [
                "items": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "required": ["task", "owner", "due", "sourceSegmentId"],
                        "properties": [
                            "task": schemaString(
                                "Concrete action or follow-up task. Empty only if omitted from items."),
                            "owner": schemaString(
                                "Responsible person or team if stated, otherwise empty string."),
                            "due": schemaString("Deadline if stated, otherwise empty string."),
                            "sourceSegmentId": schemaString(
                                "Transcript segment id supporting the item, otherwise empty string."),
                        ],
                    ],
                ],
            ],
        ]
    }

    private func schemaString(_ description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }

    // MARK: - Response payload

    private struct ResponsesResponse: Decodable {
        var model: String?
        var outputTextField: String?
        var output: [OutputItem]?
        var usage: Usage?

        private enum CodingKeys: String, CodingKey {
            case model
            case outputTextField = "output_text"
            case output, usage
        }

        struct OutputItem: Decodable {
            var type: String?
            var content: [ContentPart]?
        }

        struct ContentPart: Decodable {
            var type: String?
            var text: String?
        }

        struct Usage: Decodable {
            var inputTokens: Int?
            var outputTokens: Int?

            private enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
            }
        }

        func outputText() -> String? {
            if let direct = outputTextField?.trimmingCharacters(in: .whitespacesAndNewlines),
                !direct.isEmpty
            {
                return direct
            }
            let items: [OutputItem] = output ?? []
            let parts: [ContentPart] = items.flatMap { $0.content ?? [] }
            let texts: [String] = parts
                .filter { $0.type == "output_text" || $0.type == "text" }
                .compactMap { $0.text }
            let joined = texts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            return joined.isEmpty ? nil : joined
        }
    }
}

extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
