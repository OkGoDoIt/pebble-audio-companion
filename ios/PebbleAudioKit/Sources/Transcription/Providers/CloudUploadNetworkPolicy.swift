import Foundation

// Which networks the segment-audio upload is allowed to use.
//
// WHY THIS EXISTS. The background upload session carried NO network policy at all — unlike
// `URLSessionArchiveDownloader`, which sets `allowsExpensiveNetworkAccess = false` and documents
// why. Measured over this user's real 88 days, that unrestricted session was posting **141 MB per
// day** of uncompressed WAV, and nothing anywhere prevented a byte of it from going out over
// cellular, over a personal hotspot, or in Low Data Mode. Nobody chose that; it was simply never
// decided.
//
// Two corrections to the number this comment used to carry. FLAC is **~45-52 MB/day**, not 42:
// 42 came from treating the best of five measured segments (29.8% of WAV) as typical, and the
// real spread over the nine segments now measured is 29-45%, because FLAC actually compresses and
// quiet audio compresses better than speech. And FLAC is no longer the top rung — Ogg Speex
// passthrough (`OggSpeex`) is, at a deterministic 4.08%, i.e. **5.8 MB/day**. That is small enough
// that "Wi-Fi and Cellular" stops being a scary setting; it is not small enough to make the
// setting pointless, because the fallback rung is still an order of magnitude larger and because
// nobody should discover an unbudgeted upload after the fact.
//
// WHY WI-FI IS THE DEFAULT AND WHY THAT IS SAFE. Nothing is lost by waiting: the audio is durably
// spooled on the phone, the queue keeps it `Pending`, and one Wi-Fi window drains the backlog.
// Delay is the entire cost, and it is recoverable in one tap. The reverse mistake — a data bill
// nobody agreed to — is not.
//
// WHY IT IS NOT ON THE SESSION. A background `URLSession` cannot be reconfigured once created (one
// live session per identifier, for the life of the app), so a restriction set there could never be
// lifted by a user changing their mind. `URLRequest` carries the same three properties per task,
// and the effective policy is the AND of session and request — so the session is left permissive
// on purpose and every request states the policy explicitly at enqueue time. A change takes effect
// on the very next segment.
//
// WHAT HAPPENS WHEN THE NETWORK IS WRONG. Background tasks WAIT for a satisfactory network rather
// than failing, so a segment enqueued on cellular under `wifiOnly` sits in the transport's
// in-flight set — which is also what keeps `resetAbandonedUploads` from clawing it back — and
// starts the moment Wi-Fi appears. If it waits past the session's resource timeout it fails
// retryably, returns to `Pending`, and is offered again. Nothing is dropped in either case.

/// The networks the user is willing to spend on uploading segment audio.
///
/// Two states rather than three, deliberately. A third "Wi-Fi, and cellular but honour Low Data
/// Mode" is the sort of option that is easy to write and impossible to explain, and it leaves an
/// invisible second blocker in place after someone has just told the app to go ahead — which is
/// the "why is nothing happening" failure this setting exists to prevent.
public enum CloudUploadNetwork: String, Sendable, Equatable, CaseIterable, Codable {
    /// Wi-Fi and other unmetered networks. Excludes cellular, personal hotspots, and any network
    /// the user has put in Low Data Mode. **The default.**
    case wifiOnly
    /// Any network the phone has, cellular included. Chosen explicitly, so it also overrides Low
    /// Data Mode: an app-specific "yes" is more specific than a network-wide hint, and honouring
    /// the hint anyway would silently ignore the choice just made.
    case anyNetwork
}

extension CloudUploadNetwork {
    /// Plain language, describing what gets used rather than which flag gets set.
    public var displayName: String {
        switch self {
        case .wifiOnly: return "Wi-Fi Only"
        case .anyNetwork: return "Wi-Fi and Cellular"
        }
    }
}

public enum CloudUploadNetworkPolicy {
    /// Wi-Fi only. See the note at the top of this file for why this is the defensible default
    /// rather than the cautious one.
    public static let `default`: CloudUploadNetwork = .wifiOnly

    /// Stamps `network` onto one upload request.
    ///
    /// All three properties are set every time, including to `true`: `URLRequest` defaults them to
    /// `true`, and leaving one unset would make the policy depend on what the last caller happened
    /// to do rather than on what the user chose.
    public static func apply(_ network: CloudUploadNetwork, to request: inout URLRequest) {
        let allowed = network == .anyNetwork
        // Cellular radio.
        request.allowsCellularAccess = allowed
        // Cellular AND personal hotspots — the superset, which is why it is set alongside.
        request.allowsExpensiveNetworkAccess = allowed
        // Low Data Mode, on whichever network is in use.
        request.allowsConstrainedNetworkAccess = allowed
    }
}
