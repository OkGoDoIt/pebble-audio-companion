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

        let requestedModel = request.metadata[AiRunRequest.modelKey]
        let ceiling =
            requestedModel.map { AiModels.byId($0).contextTokens * AskBudget.charsPerToken }
            ?? maxInputChars()
        // The last-resort backstop, and a refusal for the templates that must read everything
        // (`AiInputPolicy`). The planners size Ask and the recap below this, so reaching it means
        // a plan was wrong — and an answer that claims the whole range from part of it must not
        // be the way that is discovered.
        let fitted = try AiInputPolicy.fit(
            request, maxInputChars: ceiling, modelName: requestedModel ?? model())
        let userContent = fitted.content
        let instructions = buildInstructions(request.prompt.systemPrompt)

        // A caller may name a stronger model and more thinking for one specific job. Follow-up
        // extraction and curation do: they are one call per conversation, they decide what a
        // person sees on a list they trust, and the cheapest model reads ambient chatter as
        // commitments. Everything else keeps the single user-chosen model.
        var payload: [String: Any] = [
            "model": request.metadata[AiRunRequest.modelKey] ?? model(),
            "instructions": instructions,
            "input": userContent,
            "reasoning": [
                "effort": request.metadata[AiRunRequest.reasoningEffortKey] ?? reasoningEffort
            ],
            // A ceiling, not a length policy — the prompt asks, this guarantees. Without it an
            // "extended summary" wrote 5,797 words and took 70 s, which is past the transport's
            // idle timeout, so the note never arrived at all. See `CloudOutputBudget`.
            "max_output_tokens": CloudOutputBudget.maxOutputTokens(forTemplateId: request.prompt.id),
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
        // A response cut off at the ceiling is not a shorter note, it is a note that stops
        // mid-sentence — and handing that back as finished is exactly the silent wrong answer
        // this app keeps removing. Retrying is cheap and usually works, so say so and let it.
        if parsed.status == "incomplete", parsed.incompleteDetails?.reason == "max_output_tokens" {
            throw AiError.providerFailed(
                "OpenAI stopped at the output limit for \(request.prompt.id)")
        }
        let text = (parsed.outputText() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw AiError.providerFailed("OpenAI responses returned an empty completion")
        }
        return AiProviderResult(
            text: text,
            modelUsed: parsed.model ?? requestedModel ?? model(),
            inputTokens: parsed.usage?.inputTokens,
            outputTokens: parsed.usage?.outputTokens,
            inputTruncated: fitted.truncated
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
        case AiPromptTemplates.followUpExtraction.id:
            return [
                "format": jsonSchemaFormat(
                    name: FollowUpExtractionParser.schemaName, schema: followUpsSchema())
            ]
        case AiPromptTemplates.followUpCuration.id:
            return [
                "format": jsonSchemaFormat(
                    name: FollowUpCurationParser.schemaName, schema: followUpCurationSchema())
            ]
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

    /// Extraction. Note what is NOT here: no `owner` (an item that needs one belongs to
    /// somebody else) and no `sourceSegmentId` (the segment is found by matching the quote
    /// against the transcripts, so a model cannot strand a row by inventing an id).
    private func followUpsSchema() -> [String: Any] {
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
                        "required": ["task", "quote", "ifForgotten", "dueDate", "confidence"],
                        "properties": [
                            "task": schemaString(
                                "One plain imperative sentence naming the concrete thing to do."),
                            "quote": schemaString(
                                "One contiguous verbatim run from a single speaker turn that "
                                    + "contains the commitment."),
                            "ifForgotten": schemaString(
                                "One short clause naming what concretely goes wrong if this "
                                    + "never happens."),
                            "dueDate": schemaString(
                                "Real calendar date as YYYY-MM-DD, or empty string when the "
                                    + "transcript states none."),
                            "confidence": [
                                "type": "string",
                                "enum": ["high", "medium", "low"],
                                "description":
                                    "How certain the action is unambiguous, owned by this "
                                    + "person, and cleanly transcribed.",
                            ],
                        ],
                    ],
                ]
            ],
        ]
    }

    private func followUpCurationSchema() -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "required": ["decisions"],
            "properties": [
                "decisions": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "required": [
                            "index", "decision", "reason", "task", "priority", "dueDate",
                        ],
                        "properties": [
                            "index": [
                                "type": "integer",
                                "description": "1-based index of the candidate being decided.",
                            ],
                            "decision": [
                                "type": "string",
                                "enum": ["keep", "drop", "duplicate"],
                                "description": "What to do with this candidate.",
                            ],
                            "reason": schemaString("One clause explaining the decision."),
                            "task": schemaString(
                                "Rewritten task text, or empty string to keep the original."),
                            "priority": [
                                "type": "string",
                                "enum": ["high", "normal", "low"],
                                "description": "How much this wants to be looked at.",
                            ],
                            "dueDate": schemaString(
                                "Real calendar date as YYYY-MM-DD, or empty string for none."),
                        ],
                    ],
                ]
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
        /// "completed" or "incomplete". A 200 does not mean the model finished — it means the
        /// request was served, and a run stopped at `max_output_tokens` comes back 200 with a
        /// partial answer in it.
        var status: String?
        var incompleteDetails: IncompleteDetails?

        private enum CodingKeys: String, CodingKey {
            case model
            case outputTextField = "output_text"
            case incompleteDetails = "incomplete_details"
            case output, usage, status
        }

        struct IncompleteDetails: Decodable {
            var reason: String?
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
