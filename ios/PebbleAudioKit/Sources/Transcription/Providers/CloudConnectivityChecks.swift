import Foundation

// The providers' `CloudConnectivityCheck` conformances — the `checkConnectivity()` bodies from
// the KMP `OpenAiTranscriptionProvider.kt` / `SonioxTranscriptionProvider.kt` /
// `SelectableCloudTranscriptionProvider.kt` originals, kept together so the connectivity seam
// (defined in the root `CloudConnectivity.swift`) has one home on the provider side.

extension OpenAiTranscriptionProvider: ConnectivityProbing {}
extension SonioxTranscriptionProvider: ConnectivityProbing {}

extension OpenAiTranscriptionProvider: CloudConnectivityCheck {
    public func checkConnectivity() async -> CloudConnectivityResult {
        await probeConnectivity(
            service: "OpenAI",
            url: modelsUrl,
            notConfigured: "Add an OpenAI API key to use cloud transcription."
        )
    }
}

extension SonioxTranscriptionProvider: CloudConnectivityCheck {
    public func checkConnectivity() async -> CloudConnectivityResult {
        // Cheapest authenticated call: list transcriptions. 2xx = key accepted.
        await probeConnectivity(
            service: "Soniox",
            url: "\(baseUrl)/v1/transcriptions",
            notConfigured: "Add a Soniox API key to use cloud transcription."
        )
    }
}

extension SelectableCloudTranscriptionProvider: CloudConnectivityCheck {
    public func checkConnectivity() async -> CloudConnectivityResult {
        guard let check = backend(selectedProvider()) as? any CloudConnectivityCheck else {
            return .failed(message: "The selected cloud provider cannot be tested.")
        }
        return await check.checkConnectivity()
    }
}

/// Shared probe shape: authenticated GET, mapped to the user-facing connectivity vocabulary.
protocol ConnectivityProbing {
    var connectivityTransport: any HttpTransport { get }
    var connectivityApiKey: String? { get }
}

extension ConnectivityProbing {
    func probeConnectivity(
        service: String,
        url: String,
        notConfigured: String
    ) async -> CloudConnectivityResult {
        guard let key = connectivityApiKey, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return .notConfigured(message: notConfigured)
        }
        do {
            let response = try await connectivityTransport.execute(
                HttpTransportRequest(
                    method: "GET", url: url, headers: ["Authorization": "Bearer \(key)"]
                )
            )
            switch response.status {
            case 200..<300:
                return .ok(detail: "\(service) connected")
            case 401, 403:
                return .failed(message: "\(service) rejected the API key.")
            case 429:
                return .failed(message: "\(service) was busy, or the account is out of credit.")
            default:
                // The response body is NOT spliced in. This string is rendered verbatim on the
                // Transcription & AI row, and a provider's body is arbitrary text that on a 4xx
                // is typically the request URL — the raw provider prose B20 forbids on a screen.
                // The status is enough for the reader; the body belongs in a log, not here.
                return .failed(message: "\(service) had trouble on its side (\(response.status)).")
            }
        } catch {
            // Likewise `localizedDescription`: system prose, in the phone's language, about a
            // request the reader never made. "It could not be reached" is the whole actionable
            // fact.
            return .failed(message: "Could not reach \(service). Check your connection.")
        }
    }
}
