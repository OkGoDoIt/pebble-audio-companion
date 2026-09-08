import Foundation
import Testing

@testable import Transcription

// These pin the CONTRACT WITH A BINARY WE DO NOT BUILD. The names below were verified present in
// both slices of the checked-in `CactusBinary.xcframework`:
//
//     strings -a PebbleAudioKit/Frameworks/CactusBinary.xcframework/ios-arm64/libCactusBinary.a \
//       | grep -E 'CACTUS_NO_CLOUD_TELE|CACTUS_SUPABASE_URL|CACTUS_CLOUD_API_BASE'
//
// A future drop-in that renames or drops a switch would otherwise re-enable telemetry silently,
// while Settings → Storage & Privacy went on claiming the opposite. Re-run that grep when the
// xcframework is updated; if a name here stops appearing in the binary, this file is the thing
// that has to change, and the privacy copy has to change with it.
@Suite("Cactus privacy configuration")
struct CactusPrivacyConfigurationTests {

    @Test("the telemetry kill switch is set, and set to something the library reads as on")
    func telemetryDisabled() {
        CactusPrivacyConfiguration.applyEnvironment()
        #expect(ProcessInfo.processInfo.environment["CACTUS_NO_CLOUD_TELE"] == "1")
    }

    @Test("both network endpoints are redirected to a port nothing listens on")
    func endpointsBlackholed() {
        CactusPrivacyConfiguration.applyEnvironment()
        let environment = ProcessInfo.processInfo.environment
        #expect(environment["CACTUS_SUPABASE_URL"] == "http://127.0.0.1:9")
        #expect(environment["CACTUS_CLOUD_API_BASE"] == "http://127.0.0.1:9")
    }

    /// Cactus falls back to local output when it finds no cloud key, so clearing these is what
    /// keeps the cloud handoff — the path that would send AUDIO, not just counters — inert.
    @Test("cloud credentials are cleared, not merely ignored")
    func cloudKeysCleared() {
        setenv("CACTUS_CLOUD_KEY", "leftover", 1)
        setenv("CACTUS_CLOUD_API_KEY", "leftover", 1)
        CactusPrivacyConfiguration.applyEnvironment()
        let environment = ProcessInfo.processInfo.environment
        #expect(environment["CACTUS_CLOUD_KEY"] == nil)
        #expect(environment["CACTUS_CLOUD_API_KEY"] == nil)
    }

    /// A value inherited from a scheme or a CI runner must not win: `setenv` is called with
    /// overwrite, and this is the regression that would prove it wasn't.
    @Test("an inherited value is overwritten rather than preserved")
    func overwritesInheritedValues() {
        setenv("CACTUS_NO_CLOUD_TELE", "0", 1)
        setenv("CACTUS_SUPABASE_URL", "https://example.invalid", 1)
        CactusPrivacyConfiguration.applyEnvironment()
        let environment = ProcessInfo.processInfo.environment
        #expect(environment["CACTUS_NO_CLOUD_TELE"] == "1")
        #expect(environment["CACTUS_SUPABASE_URL"] == "http://127.0.0.1:9")
    }

    @Test("the telemetry cache path is the library's own, resolved against the real container")
    func telemetryCachePath() {
        let caches = URL(fileURLWithPath: "/tmp/example/Library/Caches", isDirectory: true)
        let url = CactusPrivacyConfiguration.telemetryCacheURL(cachesDirectory: caches)
        #expect(url.path.hasSuffix("Library/Caches/cactus/telemetry"))
    }

    /// Events queued by an install that ran BEFORE this change would otherwise flush on a later
    /// launch, after the app had started promising they wouldn't.
    @Test("queued telemetry from earlier runs is deleted")
    func purgesQueuedTelemetry() throws {
        let caches = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("cactus-purge-\(UUID().uuidString)", isDirectory: true)
        let telemetry = CactusPrivacyConfiguration.telemetryCacheURL(cachesDirectory: caches)
        try FileManager.default.createDirectory(
            at: telemetry, withIntermediateDirectories: true)
        let queued = telemetry.appendingPathComponent("pending.json")
        try Data("{}".utf8).write(to: queued)
        #expect(FileManager.default.fileExists(atPath: queued.path))

        CactusPrivacyConfiguration.purgeTelemetryCache(cachesDirectory: caches)

        #expect(!FileManager.default.fileExists(atPath: telemetry.path))
        try? FileManager.default.removeItem(at: caches)
    }

    @Test("purging is safe when there is nothing there")
    func purgeIsSafeWhenAbsent() {
        let caches = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("cactus-absent-\(UUID().uuidString)", isDirectory: true)
        CactusPrivacyConfiguration.purgeTelemetryCache(cachesDirectory: caches)
    }
}
