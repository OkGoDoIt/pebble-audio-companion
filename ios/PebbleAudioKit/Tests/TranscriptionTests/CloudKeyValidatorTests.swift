import Foundation
import Testing

@testable import Transcription

// The status→outcome mapping is pinned against bodies captured from the REAL APIs (an invalid
// key against api.openai.com/v1/models and api.soniox.com/v1/transcriptions on 2026-08-31), so
// a provider changing its error prose cannot quietly turn "rejected" into "unexpected".
// No key material is present here: these are the failure bodies, with the echoed key redacted.

@Suite struct CloudKeyValidatorTests {

    // Real 401 body from OpenAI. The provider quotes a masked key back in `message`; the
    // redaction here is deliberate, and the fact that it quotes anything at all is why the
    // validator never surfaces provider prose.
    static let openAiUnauthorized = """
        {"error":{"message":"Incorrect API key provided: sk-REDACTED. You can find your API key \
        at https://platform.openai.com/account/api-keys.","type":"invalid_request_error",\
        "param":null,"code":"invalid_api_key"}}
        """

    // Real 401 body from Soniox.
    static let sonioxUnauthorized = """
        {"status_code": 401, "error_type": "unauthenticated", "message": "Incorrect API key \
        provided. You can get an API key at https://console.soniox.com", "validation_errors": \
        [], "request_id": "REDACTED"}
        """

    static let openAiQuotaExceeded = """
        {"error":{"message":"You exceeded your current quota, please check your plan and \
        billing details.","type":"insufficient_quota","param":null,"code":"insufficient_quota"}}
        """

    private func outcome(_ status: Int, _ text: String = "{}") -> ApiKeyCheckOutcome {
        CloudKeyValidator.outcome(status: status, body: Data(text.utf8))
    }

    @Test func acceptsAnySuccessStatus() {
        #expect(outcome(200) == .valid)
        #expect(outcome(204) == .valid)
    }

    @Test func unauthorizedIsRejectedForBothProviders() {
        #expect(outcome(401, Self.openAiUnauthorized) == .rejected)
        #expect(outcome(401, Self.sonioxUnauthorized) == .rejected)
    }

    @Test func forbiddenIsNotPermittedRatherThanRejected() {
        // 403 means the credential is real but barred from this API — telling the user to
        // re-check the key would send them the wrong way.
        #expect(outcome(403) == .notPermitted)
    }

    @Test func quotaExhaustionIsDistinguishedFromThrottling() {
        #expect(outcome(429, Self.openAiQuotaExceeded) == .outOfCredit)
        #expect(outcome(429, "{\"error\":{\"message\":\"Rate limit reached\"}}") == .rateLimited)
    }

    @Test func serverErrorsBlameTheProviderNotTheKey() {
        #expect(outcome(500) == .providerUnavailable)
        #expect(outcome(503) == .providerUnavailable)
    }

    @Test func unknownStatusCarriesItForDiagnostics() {
        #expect(outcome(418) == .unexpected(status: 418))
    }

    @Test func blankKeyIsMissingAndNeverHitsTheNetwork() async {
        let transport = RecordingTransport(result: .success(.init(status: 200, text: "{}")))
        let validator = CloudKeyValidator(transport: transport)
        #expect(await validator.validate("   ", for: .openAi) == .missing)
        #expect(transport.requestCount == 0)
    }

    @Test func transportFailureIsUnreachable() async {
        let transport = RecordingTransport(result: .failure(URLError(.notConnectedToInternet)))
        let validator = CloudKeyValidator(transport: transport)
        #expect(await validator.validate("sk-whatever", for: .soniox) == .unreachable)
    }

    @Test func sendsBearerKeyToTheProvidersProbeEndpoint() async {
        let transport = RecordingTransport(result: .success(.init(status: 200, text: "{}")))
        let validator = CloudKeyValidator(transport: transport)
        _ = await validator.validate("  key-with-space  ", for: .soniox)
        let request = try! #require(transport.lastRequest)
        #expect(request.method == "GET")
        #expect(request.url == "https://api.soniox.com/v1/transcriptions")
        // Whitespace from a paste must not travel into the header.
        #expect(request.headers["Authorization"] == "Bearer key-with-space")
    }

    @Test func openAiProbeUsesTheModelsEndpoint() async {
        let transport = RecordingTransport(result: .success(.init(status: 200, text: "{}")))
        _ = await CloudKeyValidator(transport: transport).validate("k", for: .openAi)
        #expect(transport.lastRequest?.url == "https://api.openai.com/v1/models")
    }
}

/// Minimal transport fake: one canned outcome, plus what it was asked for.
private final class RecordingTransport: HttpTransport, @unchecked Sendable {
    private let result: Result<HttpTransportResponse, Error>
    private(set) var lastRequest: HttpTransportRequest?
    private(set) var requestCount = 0

    init(result: Result<HttpTransportResponse, Error>) {
        self.result = result
    }

    func execute(_ request: HttpTransportRequest) async throws -> HttpTransportResponse {
        requestCount += 1
        lastRequest = request
        return try result.get()
    }
}
