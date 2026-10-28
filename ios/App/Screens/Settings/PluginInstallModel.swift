import CompanionRuntime
import Firmware
import Foundation
import Observation

/// Settings › Watch › Pebble App Plugin: what the section shows, and the little it does.
///
/// The plugin (`pebble-plugin/`) lives in the official Pebble app, which installs a plugin from an
/// opened `.pbw` and lets its settings page connect with a one-time code from the person's server.
/// This app carries the plugin (the build packs it from `pebble-plugin/` into the app's resources)
/// and asks its own server for the code, so the whole setup is two steps on one phone: Install in
/// Pebble App, then enter the code shown under it.
///
/// It does nothing while the section is off screen: `run()` is the section's `.task`, and it ends
/// with it. While a live code is up and the plugin has not connected, it asks the server every
/// `pollInterval` whether it has, so the section turns to Connected while the person is still
/// looking; a code that runs out simply reads as expired, with no countdown. Every write is
/// change-gated: a check that finds what was already known publishes nothing.
@MainActor
@Observable
final class PluginInstallModel {
    enum Phase: Equatable {
        /// The first answer has not come back yet.
        case checking
        /// No server is linked, or it has stopped accepting this phone.
        case needsServer
        /// The first look found no server to ask.
        case unreachable
        case notConnected
        /// `lastReadAtMs` is nil before the plugin's first read.
        case connected(lastReadAtMs: Int64?)
    }

    enum Code: Equatable {
        case none
        case loading
        case ready(ArchivePluginCode)
        /// Past its time, still shown (dimmed) so the screen does not jump.
        case expired(ArchivePluginCode)
        case failed
    }

    /// What the last hand-off to the Pebble app came to, for the line under the install button.
    enum Handoff: Equatable {
        case none
        case sentToPebble
        case sentElsewhere
        /// Nothing on this phone could open the plugin, so no menu appeared.
        case noPebbleApp
    }

    /// How often a live code's connection is checked while the section is on screen.
    static let pollInterval: Duration = .seconds(10)
    /// A code with less than this left is replaced rather than shown again.
    static let reuseMarginMs: Int64 = 120_000
    /// The plugin as the build bundles it, and the name it is handed over under.
    static let bundledResource = "PebbleAudioPlugin"
    static let handoffFileName = "Pebble Audio.pbw"

    private(set) var phase: Phase = .checking
    private(set) var code: Code = .none
    /// Connect Again, tapped: the install and a code, below Connected.
    private(set) var reconnecting = false
    private(set) var handoff: Handoff = .none

    @ObservationIgnored private let source: PluginInstallSource
    @ObservationIgnored let nowMs: () -> Int64

    init(
        source: PluginInstallSource,
        nowMs: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.source = source
        self.nowMs = nowMs
    }

    /// The install and the code are on screen.
    var showsSetup: Bool {
        switch phase {
        case .notConnected: return true
        case .connected: return reconnecting
        case .checking, .needsServer, .unreachable: return false
        }
    }

    // MARK: Running

    /// The section's `.task`: the first look, then a check on a live code until it disappears.
    func run() async {
        await load()
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: nextWake)
            } catch {
                return
            }
            await tick()
        }
    }

    /// What the server says, and a code when one is needed. Coming back to the screen keeps a
    /// code that still has a while to run rather than ending it.
    func load() async {
        await refreshConnection()
        if showsSetup { await ensureCode() }
    }

    /// The clock: a code past its time reads as expired, and while a live one is up, whether the
    /// plugin has used it.
    func tick() async {
        expireIfDue()
        if case .ready = code, phase == .notConnected { await refreshConnection() }
    }

    /// Until the shown code runs out, or the next check, whichever comes first.
    var nextWake: Duration {
        guard case .ready(let current) = code else { return Self.pollInterval }
        let untilExpiry = Duration.milliseconds(max(0, current.expiresAtMs - nowMs()) + 50)
        return min(Self.pollInterval, untilExpiry)
    }

    func refreshConnection() async {
        guard source.archiveLinked else {
            settle(.needsServer)
            return
        }
        switch await source.connection() {
        case .success(let answer) where answer.connected:
            // A code that was up has done its job, or was never needed.
            if !reconnecting, code != .none { code = .none }
            settle(.connected(lastReadAtMs: answer.lastUsedAtMs))
        case .success:
            if reconnecting { reconnecting = false }
            settle(.notConnected)
        case .failure(.notLinked):
            settle(.needsServer)
        case .failure(.unavailable):
            // What is known stays; only a first look with no answer says so.
            if phase == .checking { settle(.unreachable) }
        }
    }

    /// Try Again, from the unreachable state.
    func retry() async {
        settle(.checking)
        await load()
    }

    // MARK: The code

    /// A code to show: the one up already while it has a while to run, else a new one.
    func ensureCode() async {
        if case .ready(let current) = code, current.expiresAtMs - nowMs() > Self.reuseMarginMs {
            return
        }
        await newCode()
    }

    /// New Code, or a first one. The server ends the one before it.
    func newCode() async {
        guard code != .loading else { return }
        code = .loading
        switch await source.mintCode() {
        case .success(let minted):
            code = minted.expiresAtMs > nowMs() ? .ready(minted) : .expired(minted)
        case .failure(.notLinked):
            code = .none
            settle(.needsServer)
        case .failure(.unavailable):
            code = .failed
        }
    }

    func expireIfDue() {
        if case .ready(let current) = code, nowMs() >= current.expiresAtMs {
            code = .expired(current)
        }
    }

    /// Connect Again: the install and a fresh code below Connected.
    func connectAgain() async {
        guard !reconnecting else { return }
        reconnecting = true
        await ensureCode()
    }

    // MARK: The hand-off

    /// The bundled plugin, copied to a file named the way the Pebble app's menu shows it. Nil when
    /// this build carries none (previews and the tests).
    func preparePluginFile(bundle: Bundle = .main) -> URL? {
        guard let bundled = bundle.url(forResource: Self.bundledResource, withExtension: "pbw")
        else { return nil }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(Self.handoffFileName)
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: bundled, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    func record(_ outcome: PebbleAppHandoffOutcome) {
        let next: Handoff
        switch outcome {
        case .openedIn(let bundleIdentifier):
            next = PebbleAppHandoff.isPebbleApp(bundleIdentifier) ? .sentToPebble : .sentElsewhere
        case .noOpener:
            next = .noPebbleApp
        case .savedToFiles, .dismissed:
            return
        }
        if handoff != next { handoff = next }
    }

    // MARK: Helpers

    /// Writes only a change: a check that finds what was known publishes nothing.
    private func settle(_ next: Phase) {
        if next == .needsServer || next == .unreachable {
            if code != .none { code = .none }
            if reconnecting { reconnecting = false }
        }
        if phase != next { phase = next }
    }
}
