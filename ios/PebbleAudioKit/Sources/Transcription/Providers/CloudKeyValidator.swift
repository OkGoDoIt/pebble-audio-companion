import Foundation

// Validating a typed API key, with a REASON rather than a yes/no.
//
// This exists separately from `CloudConnectivityCheck` because the key-entry screens need to
// test a key the user has just typed and not yet saved, and because "it didn't work" is not a
// useful answer — "that key was rejected" and "the account is out of credit" call for opposite
// actions from the person reading it.
//
// The outcome is a TAXONOMY, never provider prose. Two reasons:
//   • the plan bans raw exception/platform copy in the UI (anti-goal B20), and
//   • the providers' own 401 bodies quote the key back — OpenAI's reads "Incorrect API key
//     provided: sk-inval***********_123" — so echoing them puts key material on screen and
//     into any screenshot of it.
// The app maps these cases to its single approved string catalog.

/// Why a key check succeeded or failed. Distinctions are drawn where the user's next action
/// differs, and nowhere else.
public enum ApiKeyCheckOutcome: Sendable, Equatable {
    /// The provider accepted the key.
    case valid
    /// Nothing was entered.
    case missing
    /// 401 — wrong key, or a partial paste.
    case rejected
    /// 403 — the key is real but not allowed to use this API (project/org restrictions).
    case notPermitted
    /// 429 with a quota code — the key works, the account has no credit. Fixing the key is the
    /// wrong instinct here, which is exactly why it is not folded into `rejected`.
    case outOfCredit
    /// 429 without a quota code — too many requests right now; retrying later works.
    case rateLimited
    /// 5xx — the provider is having trouble; nothing is wrong with the key.
    case providerUnavailable
    /// No response at all (offline, DNS, TLS, timeout).
    case unreachable
    /// A status we do not have specific advice for; carried so diagnostics can show it.
    case unexpected(status: Int)

    public var isValid: Bool { self == .valid }
}

/// Checks a cloud API key with one cheap authenticated GET. Uses the injectable `HttpTransport`
/// seam, so every test runs hermetically.
public struct CloudKeyValidator: Sendable {
    public enum Provider: Sendable, CaseIterable {
        case openAi
        case soniox

        /// The cheapest authenticated endpoint that proves the credential without side effects.
        /// Both are plain reads: nothing is created, nothing is billed.
        var probeUrl: String {
            switch self {
            case .openAi: return "https://api.openai.com/v1/models"
            case .soniox: return "https://api.soniox.com/v1/transcriptions"
            }
        }
    }

    private let transport: any HttpTransport

    public init(transport: any HttpTransport) {
        self.transport = transport
    }

    public func validate(_ key: String, for provider: Provider) async -> ApiKeyCheckOutcome {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .missing }

        let response: HttpTransportResponse
        do {
            response = try await transport.execute(
                HttpTransportRequest(
                    method: "GET",
                    url: provider.probeUrl,
                    headers: ["Authorization": "Bearer \(trimmed)"]
                )
            )
        } catch {
            // A thrown transport error means no HTTP response existed at all.
            return .unreachable
        }

        return Self.outcome(status: response.status, body: response.body)
    }

    /// Status → outcome. Split out so tests can pin the mapping against real captured bodies.
    static func outcome(status: Int, body: Data) -> ApiKeyCheckOutcome {
        switch status {
        case 200..<300:
            return .valid
        case 401:
            return .rejected
        case 403:
            return .notPermitted
        case 429:
            // Both providers overload 429. OpenAI signals an exhausted balance with
            // `code: "insufficient_quota"`; anything else is ordinary throttling.
            return mentionsQuota(body) ? .outOfCredit : .rateLimited
        case 500...599:
            return .providerUnavailable
        default:
            return .unexpected(status: status)
        }
    }

    /// Looks for a quota marker without parsing either provider's whole error schema — the
    /// shapes differ and both are free to change; the marker string is the stable part.
    private static func mentionsQuota(_ body: Data) -> Bool {
        let text = String(decoding: body, as: UTF8.self).lowercased()
        return text.contains("insufficient_quota")
            || text.contains("exceeded your current quota")
            || text.contains("out of credit")
    }
}
