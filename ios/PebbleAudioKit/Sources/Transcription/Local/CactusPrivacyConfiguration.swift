import Foundation

// Cactus is the one dependency in this app that can reach the network without going through a
// seam we own. The vendored `CactusBinary.xcframework` is merged with its own libcurl, so every
// `URLSession` policy, every provider gate and every "local only" mode in this codebase is
// invisible to it: it links `cactus::telemetry::TelemetryDispatcher`, which posts to a Supabase
// endpoint from `cactus_init` and from each transcription. Nothing in the app had ever called
// the opt-outs the library exposes.
//
// That matters here more than it would almost anywhere else. Parakeet is the engine a person
// selects BECAUSE they want transcription to happen on their phone, and Settings → Storage &
// Privacy now states in plain words where their data goes. A statement like that is only worth
// making if it is true of the binary as well as of the Swift.
//
// The library's own kill switches are what turn it off — the static library itself is untouched.
// All five names below were confirmed present in both slices of the checked-in xcframework
// (`strings -a … | grep CACTUS_`), which is the precondition for any of this working;
// `CactusPrivacyConfigurationTests` pins the names so a future drop-in that renames them fails
// loudly here instead of silently re-enabling telemetry.

/// Turns off Cactus's telemetry and its separate cloud-handoff path, once per process.
///
/// **Ordering is the whole point.** Telemetry is initialized from inside `cactus_init`, so this
/// has to run before the first one — after that, the first event has already gone. `configure()`
/// is therefore called immediately before every `cactus_init`, not at some app-start hook that a
/// later refactor could reorder; the work itself happens once (`configured` is a lazy `static`,
/// which Swift initializes exactly once and thread-safely).
public enum CactusPrivacyConfiguration {

    // MARK: Environment keys
    //
    // Kept as constants rather than inline literals so the test can assert the exact set, and so
    // the grep that verified them against the binary has something to match in Swift too.

    /// The primary control: suppresses telemetry transmission outright.
    public static let noCloudTelemetryKey = "CACTUS_NO_CLOUD_TELE"
    /// Where telemetry would be posted. Redirected as defense in depth.
    public static let supabaseUrlKey = "CACTUS_SUPABASE_URL"
    /// Cactus's own cloud/hybrid transcription endpoint — a different path from telemetry, and
    /// one that would send audio, not just counters.
    public static let cloudApiBaseKey = "CACTUS_CLOUD_API_BASE"
    /// Cloud credentials. Cactus falls back to local output when it finds no key, so clearing
    /// these keeps cloud handoff from activating even if an endpoint were reachable.
    public static let cloudKeyKeys = ["CACTUS_CLOUD_KEY", "CACTUS_CLOUD_API_KEY"]

    /// Discard port on loopback: RFC 863's port 9, which nothing listens on. A redirect rather
    /// than an empty value, because an empty base URL is the kind of input a client library
    /// "helpfully" falls back to a default for.
    public static let blackholeEndpoint = "http://127.0.0.1:9"

    // MARK: Applying it

    private static let configured: Void = {
        applyEnvironment()
        purgeTelemetryCache()
    }()

    /// Idempotent and cheap after the first call. Call it immediately before `cactus_init`.
    public static func configure() {
        _ = configured
    }

    /// Overwrites unconditionally (`setenv`'s third argument): a value inherited from a scheme,
    /// a CI environment or a previous library could otherwise re-enable exactly what this exists
    /// to prevent.
    static func applyEnvironment() {
        setenv(noCloudTelemetryKey, "1", 1)
        setenv(supabaseUrlKey, blackholeEndpoint, 1)
        setenv(cloudApiBaseKey, blackholeEndpoint, 1)
        for key in cloudKeyKeys { unsetenv(key) }
    }

    // MARK: Cached telemetry from earlier runs

    /// `Library/Caches/cactus/telemetry`, resolved against the real container rather than a
    /// hard-coded sandbox path.
    static func telemetryCacheURL(cachesDirectory: URL) -> URL {
        cachesDirectory
            .appendingPathComponent("cactus", isDirectory: true)
            .appendingPathComponent("telemetry", isDirectory: true)
    }

    /// An install that ran before this change may already have events queued on disk waiting for
    /// a next launch to flush them. Turning transmission off does not retract those, so they are
    /// deleted. Safe to repeat, and safe when absent — there is nothing here the app reads.
    static func purgeTelemetryCache(
        fileManager: FileManager = .default,
        cachesDirectory: URL? = nil
    ) {
        let caches =
            cachesDirectory
            ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
        guard let caches else { return }
        try? fileManager.removeItem(at: telemetryCacheURL(cachesDirectory: caches))
    }
}
