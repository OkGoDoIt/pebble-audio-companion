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
///
/// It also refuses while the ACCOUNT has told us to stop. The key and the account are the same
/// ones the OpenAI transcription provider uses, so this consults the same `CloudAccountHold`
/// the transcription side does (the 2026-09-23 Soniox outage is that type's story): a 402 or
/// insufficient-quota answer, or a rejected key (401), puts `.openAi` on hold, and while it is
/// held `isAvailable()` is false and nothing is sent — Remote first uses the on-device model,
/// Remote only parks, and the title backlog, the live refresh every 45 s, the boundary reviews
/// and multi-megabyte Ask sweeps stop paying full price to be told no. A 403 does NOT hold on
/// this side: for AI it can be one model the key may not use, not the account. Nor is a 403
/// hold the transcription side put on the account honoured here (`aiHoldingKinds`).
public final class OpenAiChatAiProvider: AiProvider, AiUnavailabilityExplaining, AiAccountProbing,
    @unchecked Sendable
{
    public static let defaultEndpointUrl = "https://api.openai.com/v1/responses"
    public static let defaultModel = AiModels.defaultModelId
    public static let defaultReasoningEffort = "low"
    /// Last-resort ceiling for a model whose window we do not know. Real ceilings come from
    /// the catalog via `maxInputChars` below — a fixed 240_000 here silently cut a
    /// million-token model's input to a tenth of what it could hold, chronologically from the
    /// START, so the newest transcripts were the ones dropped.
    public static let defaultMaxInputChars =
        AiModels.conservativeContextTokens * AskBudget.charsPerToken
    /// How long a 429 without a usable `Retry-After` keeps the provider unavailable.
    public static let defaultRateLimitBackoffMs: Int64 = 30_000
    /// A `Retry-After` longer than this is capped: an hour is already long enough that a
    /// Remote-first user is better served by the on-device model in the meantime, and a header
    /// is a request, not a promise.
    public static let maxRateLimitBackoffMs: Int64 = 60 * 60_000
    /// The probe's answer budget: the smallest the API accepts. The probe asks only whether the
    /// account will pay for a response at all.
    static let probeMaxOutputTokens = 16

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
    /// The hold shared with the transcription side. Nil in tests that do not care, and then
    /// nothing is ever held.
    private let accountHold: CloudAccountHold?
    private let nowMs: @Sendable () -> Int64
    private let log: @Sendable (String) -> Void

    private let lock = NSLock()
    /// Set by a 429: nothing is sent before this.
    private var rateLimitedUntilMs: Int64?
    private var probing = false

    public init(
        transport: HttpTransport,
        apiKey: @escaping @Sendable () -> String?,
        remoteConsent: @escaping @Sendable () -> Bool,
        model: @escaping @Sendable () -> String = { OpenAiChatAiProvider.defaultModel },
        endpointUrl: String = OpenAiChatAiProvider.defaultEndpointUrl,
        maxInputChars: (@Sendable () -> Int)? = nil,
        grounding: @escaping @Sendable () -> String? = { nil },
        reasoningEffort: String = OpenAiChatAiProvider.defaultReasoningEffort,
        accountHold: CloudAccountHold? = nil,
        nowMs: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) },
        log: @escaping @Sendable (String) -> Void = { _ in }
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
        self.accountHold = accountHold
        self.nowMs = nowMs
        self.log = log
    }

    public func isAvailable() async -> Bool {
        guard remoteConsent() else { return false }
        guard let key = apiKey(), !key.isBlank else { return false }
        return await unavailabilityReason() == nil
    }

    // MARK: AiUnavailabilityExplaining

    /// Why the provider is unavailable although consent and a key are in place: the account is
    /// on hold, or a 429 asked us to wait. Worded so the router and the copy classify it as the
    /// refusal it is, not as "not configured".
    public func unavailabilityReason() async -> String? {
        if let hold = honouredHold() { return Self.pausedMessage(hold) }
        if let until = lock.withLock({ rateLimitedUntilMs }), until > nowMs() {
            return "OpenAI is rate limiting this account (429); nothing is sent before "
                + Self.iso(until)
        }
        return nil
    }

    /// The hold kinds this side honours: the account is out of money, or the key was rejected
    /// outright — both true of every OpenAI API alike. The shared hold can also carry
    /// `.keyNotPermitted`, a 403 the TRANSCRIPTION side got, and that one is about what the key
    /// may do with audio: a restricted key can be refused the transcription models and still be
    /// allowed the Responses API. Honouring it here stopped every AI job for a key that could
    /// run them, and the first AI success then lifted it — so transcription paid a refused
    /// upload to put it back, once per AI call, every 45 s while the live refresh ran.
    static let aiHoldingKinds: Set<TranscriptionFailureKind> = [
        .accountOutOfFunds, .spendingLimitReached, .keyRejected,
    ]

    /// The hold in force for `.openAi` when it is one this side honours, or nil.
    private func honouredHold() -> CloudAccountHold.Hold? {
        guard let hold = accountHold?.active(for: .openAi), Self.aiHoldingKinds.contains(hold.kind)
        else { return nil }
        return hold
    }

    /// What a held account says instead of sending anything: our own words with the status in
    /// parentheses, so `TranscriptionFailureKind.classify` reads the hold's own kind back.
    static func pausedMessage(_ hold: CloudAccountHold.Hold) -> String {
        switch hold.kind {
        case .keyRejected:
            return "OpenAI did not accept the API key (401); no AI request is sent until it changes"
        case .spendingLimitReached:
            return "OpenAI has reached its spending limit (402); no AI request is sent until the "
                + "limit is raised"
        default:
            return "OpenAI is out of credit (402); no AI request is sent until the account is "
                + "topped up"
        }
    }

    // MARK: Running one request

    public func run(_ request: AiRunRequest) async throws -> AiProviderResult {
        guard remoteConsent() else {
            throw AiError.consentRequired(providerId: id)
        }
        guard let key = apiKey(), !key.isBlank else {
            throw AiError.providerUnavailable(providerId: id)
        }
        // Nothing is sent to an account that has said no, or before a 429's `Retry-After`. The
        // router never gets here in that state (`isAvailable()` is false); a direct caller gets
        // the reason instead of a request.
        if let reason = await unavailabilityReason() {
            throw AiError.providerFailed(reason)
        }

        let requestedModel = request.metadata[AiRunRequest.modelKey]
        // The stored setting, resolved the way Settings resolves it: a legacy id from an earlier
        // catalog ("gpt-5.4-mini") used to be sent to OpenAI verbatim while every budget and
        // label in the app treated it as its replacement.
        let selectedModel = AiModels.resolvedModelId(model())
        let ceiling =
            requestedModel.map { AiModels.byId($0).contextTokens * AskBudget.charsPerToken }
            ?? maxInputChars()
        // The last-resort backstop, and a refusal for the templates that must read everything
        // (`AiInputPolicy`). The planners size Ask and the recap below this, so reaching it means
        // a plan was wrong — and an answer that claims the whole range from part of it must not
        // be the way that is discovered.
        let fitted = try AiInputPolicy.fit(
            request, maxInputChars: ceiling, modelName: requestedModel ?? selectedModel)
        let userContent = fitted.content
        let instructions = buildInstructions(request.prompt.systemPrompt)

        // A caller may name a stronger model and more thinking for one specific job. Follow-up
        // extraction and curation do: they are one call per conversation, they decide what a
        // person sees on a list they trust, and the cheapest model reads ambient chatter as
        // commitments. Everything else keeps the single user-chosen model.
        //
        // A key without access to the pinned model gets the person's OWN model for that job,
        // not nothing: the 403/404 used to fail the call, and on Remote first the router then
        // handed the job to the on-device model — a silent downgrade from the strongest model
        // the app uses to the weakest, for exactly the job the stronger one was chosen for.
        let pinned = requestedModel.flatMap { $0 == selectedModel ? nil : $0 }
        let textConfig = responseTextConfig(for: request.prompt)
        let effort = request.metadata[AiRunRequest.reasoningEffortKey] ?? reasoningEffort
        let outputCap = CloudOutputBudget.maxOutputTokens(forTemplateId: request.prompt.id)
        let transport = self.transport
        let endpointUrl = self.endpointUrl
        func send(_ modelId: String) async throws -> HttpTransportResponse {
            var payload: [String: Any] = [
                "model": modelId,
                "instructions": instructions,
                "input": userContent,
                "reasoning": ["effort": effort],
                // A ceiling, not a length policy — the prompt asks, this guarantees. Without it
                // an "extended summary" wrote 5,797 words and took 70 s, which is past the
                // transport's idle timeout, so the note never arrived at all. See
                // `CloudOutputBudget`.
                "max_output_tokens": outputCap,
            ]
            if let textConfig { payload["text"] = textConfig }
            let body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            return try await transport.execute(
                HttpTransportRequest(
                    method: "POST",
                    url: endpointUrl,
                    headers: [
                        "Authorization": "Bearer \(key)",
                        "Content-Type": "application/json",
                    ],
                    body: body
                ))
        }
        var sentModel = pinned.map { cannotUse($0, key: key) ? selectedModel : $0 } ?? selectedModel
        var response = try await send(sentModel)
        if response.status != 200, let pinned, sentModel == pinned,
            Self.refusesModel(status: response.status, body: response.text)
        {
            rememberCannotUse(pinned, key: key, status: response.status, instead: selectedModel,
                templateId: request.prompt.id)
            sentModel = selectedModel
            response = try await send(sentModel)
        }
        guard response.status == 200 else {
            noteRefusal(response)
            throw AiError.providerFailed(
                "OpenAI responses request failed (\(response.status)): "
                    + String(response.text.prefix(240)))
        }
        // The account took a request: an out-of-credit or rejected-key hold — tripped here or on
        // the transcription side — no longer applies. A transcription-side 403 hold is left
        // alone: this success says nothing about what the key may do with audio.
        if honouredHold() != nil { accountHold?.noteSuccess(provider: .openAi) }
        let parsed = try decodeResponse(response.body)
        // A response cut off at the ceiling is not a shorter note, it is a note that stops
        // mid-sentence — and handing that back as finished is exactly the silent wrong answer
        // this app keeps removing. Retrying is cheap and usually works, so say so and let it.
        if parsed.status == "incomplete", parsed.incompleteDetails?.reason == "max_output_tokens" {
            throw AiError.providerFailed(
                "OpenAI \(AiFailure.Marker.outputLimit) for \(request.prompt.id)")
        }
        // The other ways a 200 is not an answer, each named rather than read as one. An
        // `incomplete` for any other reason (its content filter) stopped partway; a refusal part
        // came back instead of text; a `failed` response carries its own error. All three used
        // to reach the caller as finished text — or, with nothing left after filtering the
        // parts, as "an empty completion".
        if parsed.status == "incomplete" {
            throw AiError.providerFailed(
                "OpenAI \(AiFailure.Marker.answerRefused) in full: it stopped partway ("
                    + "\(parsed.incompleteDetails?.reason ?? "no reason given")) for "
                    + request.prompt.id)
        }
        if let refusal = parsed.refusal() {
            throw AiError.providerFailed(
                "OpenAI \(AiFailure.Marker.answerRefused) \(request.prompt.id): "
                    + String(refusal.prefix(160)))
        }
        if parsed.status == "failed" {
            // A failure on OpenAI's side, reported inside a 200: the provider's trouble (a
            // server-side 500 in the shared taxonomy), not the input's.
            throw AiError.providerFailed(
                "OpenAI reported the response failed (500): "
                    + String((parsed.error?.message ?? "no detail").prefix(200)))
        }
        let text = (parsed.outputText() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw AiError.providerFailed("OpenAI responses returned an empty completion")
        }
        return AiProviderResult(
            text: text,
            modelUsed: parsed.model ?? sentModel,
            inputTokens: parsed.usage?.inputTokens,
            outputTokens: parsed.usage?.outputTokens,
            inputTruncated: fitted.truncated
        )
    }

    // MARK: - A pinned model this key cannot use

    /// A 403 (not permitted to sample from this model) or a 404 naming the model: the KEY
    /// cannot use this one model, which says nothing about the account or any other model.
    static func refusesModel(status: Int, body: String) -> Bool {
        let text = body.lowercased()
        if text.contains("model_not_found")
            || text.contains("does not exist or you do not have access")
        {
            return true
        }
        return status == 403 || (status == 404 && text.contains("model"))
    }

    /// Pinned models each key has been refused, by a fingerprint of the key — a new key may
    /// well be allowed them. In memory: a relaunch costs one refused request per model.
    private var refusedModels: [String: Set<String>] = [:]

    private func cannotUse(_ model: String, key: String) -> Bool {
        let fingerprint = RecapCondenser.fingerprint(key)
        return lock.withLock { refusedModels[fingerprint]?.contains(model) == true }
    }

    private func rememberCannotUse(
        _ model: String, key: String, status: Int, instead: String, templateId: String
    ) {
        let fingerprint = RecapCondenser.fingerprint(key)
        let isNew: Bool = lock.withLock {
            refusedModels[fingerprint, default: []].insert(model).inserted
        }
        guard isNew else { return }
        log(
            "ai: this OpenAI key cannot use \(model) (\(status)); \(templateId) and every other "
                + "job that asks for it use \(instead) instead")
    }

    // MARK: - Refusals that are about the account, not the request

    /// A non-200 answer: put the account on hold when it refused the ACCOUNT, and honour a
    /// 429's `Retry-After` when it only asked us to slow down.
    private func noteRefusal(_ response: HttpTransportResponse) {
        if let kind = Self.accountRefusal(status: response.status, body: response.text) {
            if accountHold?.trip(kind, provider: .openAi) == true {
                log(
                    "ai: openai refused the account (\(kind.rawValue)); no AI request is sent to "
                        + "it until a check succeeds (first in "
                        + "\(CloudAccountHold.firstProbeDelayMs / 60_000) min) or the key changes")
            }
            return
        }
        guard response.status == 429 else { return }
        let waitMs = min(
            Self.retryAfterMs(response, nowMs: nowMs()) ?? Self.defaultRateLimitBackoffMs,
            Self.maxRateLimitBackoffMs)
        let until = nowMs() + max(0, waitMs)
        lock.withLock { rateLimitedUntilMs = max(rateLimitedUntilMs ?? 0, until) }
        log("ai: openai is rate limiting (429); nothing is sent for \(max(0, waitMs) / 1000) s")
    }

    /// The account-level refusals that hold: out of money (402, or the insufficient-quota
    /// wording OpenAI sends with a 429) and a rejected key (401). A 403 is deliberately absent —
    /// see the type's comment. Classified over the WHOLE body, not the 240 bytes the thrown
    /// message keeps.
    static func accountRefusal(status: Int, body: String) -> TranscriptionFailureKind? {
        if body.lowercased().contains("insufficient_quota") { return .accountOutOfFunds }
        switch TranscriptionFailureKind.classify(
            "OpenAI responses request failed (\(status)): \(body)")
        {
        case .accountOutOfFunds: return .accountOutOfFunds
        case .spendingLimitReached: return .spendingLimitReached
        case .keyRejected: return .keyRejected
        default: return nil
        }
    }

    /// OpenAI's `retry-after-ms`, or `Retry-After` in seconds or as an HTTP date, in ms.
    static func retryAfterMs(_ response: HttpTransportResponse, nowMs: Int64) -> Int64? {
        if let raw = response.header("retry-after-ms"),
            let ms = Double(raw.trimmingCharacters(in: .whitespaces))
        {
            return Int64(ms)
        }
        guard let raw = response.header("retry-after")?.trimmingCharacters(in: .whitespaces)
        else { return nil }
        if let seconds = Double(raw) { return Int64(seconds * 1_000) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: raw) else { return nil }
        return Int64(date.timeIntervalSince1970 * 1_000) - nowMs
    }

    // MARK: AiAccountProbing

    /// One minimal Responses request past the hold — "ok", sixteen tokens of answer — on the
    /// hold's own schedule (15 minutes doubling to 6 hours, and from the foreground at most every
    /// 10 minutes). It is the cheapest request that can say whether the account will pay for a
    /// response, which a key check cannot: `GET /v1/models` answers 200 for an empty account. A
    /// success lifts the hold, and the hold's lift handler wakes everything it parked.
    /// Only a hold this side honours is probed: a Responses request that succeeds cannot vouch
    /// for the audio permission a transcription-side 403 is about.
    public func probeHeldAccountIfDue(foreground: Bool) async -> CloudAccountProbeOutcome? {
        guard remoteConsent(), let hold = accountHold, honouredHold() != nil,
            hold.isProbeDue(provider: .openAi, foreground: foreground)
        else { return nil }
        let claimed: Bool = lock.withLock {
            if probing { return false }
            probing = true
            return true
        }
        guard claimed else { return nil }
        defer { lock.withLock { probing = false } }

        let outcome = await probeAccount()
        switch outcome {
        case .accepted:
            hold.noteSuccess(provider: .openAi)
        case .refused(let kind):
            if !hold.trip(kind, provider: .openAi) {
                hold.recordRefusedProbe(provider: .openAi, kind: kind)
            }
            let next = hold.active(for: .openAi).map { ($0.nextProbeAtMs - nowMs()) / 60_000 }
            log(
                "ai: openai account check: still refused (\(kind.rawValue)); next check in "
                    + "\(next ?? 0) min")
        case .inconclusive(let why):
            hold.recordInconclusiveProbe(provider: .openAi)
            log("ai: openai account check inconclusive: \(why)")
        }
        return outcome
    }

    /// The probe itself, with no hold bookkeeping.
    func probeAccount() async -> CloudAccountProbeOutcome {
        guard let key = apiKey(), !key.isBlank else { return .inconclusive("no key") }
        let payload: [String: Any] = [
            "model": AiModels.resolvedModelId(model()),
            "input": "ok",
            "reasoning": ["effort": reasoningEffort],
            "max_output_tokens": Self.probeMaxOutputTokens,
        ]
        let response: HttpTransportResponse
        do {
            let body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            response = try await transport.execute(
                HttpTransportRequest(
                    method: "POST", url: endpointUrl,
                    headers: [
                        "Authorization": "Bearer \(key)", "Content-Type": "application/json",
                    ],
                    body: body))
        } catch is CancellationError {
            return .inconclusive("cancelled")
        } catch {
            return .inconclusive(String(storedFailureMessage(error).prefix(200)))
        }
        if response.status == 200 { return .accepted }
        if let kind = Self.accountRefusal(status: response.status, body: response.text) {
            return .refused(kind)
        }
        return .inconclusive("HTTP \(response.status)")
    }

    private static func iso(_ ms: Int64) -> String {
        ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(ms) / 1_000))
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
        case DayBrief.templateId:
            return ["format": jsonSchemaFormat(name: "day_brief", schema: dayBriefSchema())]
        case PeriodBriefWriter.weekTemplateId, PeriodBriefWriter.monthTemplateId:
            return [
                "format": jsonSchemaFormat(name: "period_brief", schema: periodBriefSchema())
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

    /// History's day headline. The limits are the prompt's; `HistoryBriefText` enforces them.
    private func dayBriefSchema() -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "required": ["headline", "lineSummary"],
            "properties": [
                "headline": schemaString(
                    "A noun phrase of 2 to 6 words naming what the day was about; no full stop."),
                "lineSummary": schemaString(
                    "One or two short sentences, at most 130 characters, that stand on their own."),
            ],
        ]
    }

    /// History's week and month briefs.
    private func periodBriefSchema() -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "required": ["text", "headline", "lineSummary"],
            "properties": [
                "text": schemaString("3 or 4 sentences, at most 480 characters."),
                "headline": schemaString(
                    "A noun phrase of 2 to 6 words naming the main threads; no full stop."),
                "lineSummary": schemaString(
                    "One or two short sentences, at most 130 characters, that stand on their own."),
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
        var error: ResponseError?

        private enum CodingKeys: String, CodingKey {
            case model
            case outputTextField = "output_text"
            case incompleteDetails = "incomplete_details"
            case output, usage, status, error
        }

        struct IncompleteDetails: Decodable {
            var reason: String?
        }

        struct ResponseError: Decodable {
            var message: String?
        }

        struct OutputItem: Decodable {
            var type: String?
            var content: [ContentPart]?
        }

        struct ContentPart: Decodable {
            var type: String?
            var text: String?
            /// Set on a `refusal` part: the model's own words for why it would not answer.
            var refusal: String?
        }

        /// The model's refusal, when it gave one instead of text.
        func refusal() -> String? {
            let parts: [ContentPart] = (output ?? []).flatMap { $0.content ?? [] }
            guard let part = parts.first(where: { $0.type == "refusal" }) else { return nil }
            return (part.refusal ?? part.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
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
