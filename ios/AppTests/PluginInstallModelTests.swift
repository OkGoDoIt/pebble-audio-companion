import CompanionRuntime
import Foundation
import Testing

/// Settings › Watch › Pebble App Plugin: which state the section is in, the code it shows and when
/// it is replaced, and what the server's answer about the plugin turns into.
@Suite("pebble app plugin") @MainActor
struct PluginInstallModelTests {
    /// A clock the test moves.
    final class Clock {
        var nowMs: Int64 = 1_792_000_000_000
    }

    private func make(
        _ configure: (MockPluginInstallSource) -> Void = { _ in }
    ) -> (PluginInstallModel, MockPluginInstallSource, Clock) {
        let clock = Clock()
        let source = MockPluginInstallSource(state: nil, nowMs: { clock.nowMs })
        configure(source)
        return (PluginInstallModel(source: source, nowMs: { clock.nowMs }), source, clock)
    }

    // MARK: States

    @Test func withoutAServerItSendsThePersonToLinkOneAndAsksNothing() async {
        let (model, source, _) = make { $0.archiveLinked = false }
        await model.load()
        #expect(model.phase == .needsServer)
        #expect(!model.showsSetup)
        #expect(model.code == .none)
        #expect(source.minted == 0 && source.checks == 0)
    }

    @Test func notConnectedShowsTheInstallAndAFreshCode() async {
        let (model, source, clock) = make()
        await model.load()
        #expect(model.phase == .notConnected)
        #expect(model.showsSetup)
        #expect(model.code == .ready(ArchivePluginCode(code: "K7QM-3XWD", expiresAtMs: clock.nowMs + 600_000)))
        #expect(source.minted == 1)
    }

    @Test func aFirstLookWithNoAnswerSaysSoAndTryAgainStartsOver() async {
        let (model, source, _) = make { $0.reachable = false }
        await model.load()
        #expect(model.phase == .unreachable)
        #expect(!model.showsSetup && source.minted == 0)

        source.reachable = true
        await model.retry()
        #expect(model.phase == .notConnected)
        #expect(source.minted == 1)
    }

    /// A server that stops answering later changes nothing that was known.
    @Test func aLaterMissedCheckKeepsWhatWasKnown() async {
        let (model, source, _) = make()
        await model.load()
        source.reachable = false
        await model.refreshConnection()
        #expect(model.phase == .notConnected)
        #expect(model.code != .none)
    }

    /// A phone the server stopped accepting reads as unlinked, and the code goes with it.
    @Test func aServerThatUnlinksThePhoneTakesTheSetupAway() async {
        let (model, source, _) = make()
        await model.load()
        source.archiveLinked = false
        await model.refreshConnection()
        #expect(model.phase == .needsServer)
        #expect(model.code == .none && !model.showsSetup)
    }

    // MARK: Connected

    @Test func connectedReadsTheLastUseAndAsksForNoCode() async {
        let (model, source, clock) = make {
            $0.connected = true
            $0.lastUsedAtMs = 1_791_999_880_000
        }
        await model.load()
        #expect(model.phase == .connected(lastReadAtMs: 1_791_999_880_000))
        #expect(!model.showsSetup)
        #expect(source.minted == 0)
        #expect(Copy.PluginInstall.lastRead(1_791_999_880_000, nowMs: clock.nowMs) == "Last read 2 min ago")
        #expect(Copy.PluginInstall.lastRead(nil, nowMs: clock.nowMs) == "Not read yet")
    }

    @Test func connectAgainShowsTheInstallAndACodeUnderConnected() async {
        let (model, source, _) = make { $0.connected = true }
        await model.load()
        await model.connectAgain()
        #expect(model.reconnecting && model.showsSetup)
        #expect(source.minted == 1)
        #expect(model.phase == .connected(lastReadAtMs: nil))
        // A check while reconnecting keeps the code up.
        await model.refreshConnection()
        #expect(model.code != .none)
    }

    /// The person enters the code in the Pebble app; the next check turns the section to
    /// Connected and the used code goes away.
    @Test func theCodeIsUsedAndTheSectionTurnsToConnected() async {
        let (model, source, clock) = make()
        await model.load()
        clock.nowMs += 30_000
        source.connected = true
        source.lastUsedAtMs = clock.nowMs
        await model.tick()
        #expect(model.phase == .connected(lastReadAtMs: clock.nowMs))
        #expect(model.code == .none && !model.showsSetup)
    }

    /// Disconnected on the server: back to the install and a code.
    @Test func aDisconnectedPluginOffersTheSetupAgain() async {
        let (model, source, _) = make { $0.connected = true }
        await model.load()
        source.connected = false
        await model.load()
        #expect(model.phase == .notConnected && model.showsSetup)
        #expect(source.minted == 1)
    }

    // MARK: The code over time

    @Test func aCodePastItsTimeReadsExpiredAndNewCodeReplacesIt() async {
        let (model, source, clock) = make()
        await model.load()
        guard case .ready(let first) = model.code else {
            Issue.record("no code")
            return
        }
        clock.nowMs = first.expiresAtMs - 1
        await model.tick()
        #expect(model.code == .ready(first))
        clock.nowMs = first.expiresAtMs
        await model.tick()
        #expect(model.code == .expired(first))
        // An expired code is not checked for: the clock stays quiet until New Code.
        let checks = source.checks
        await model.tick()
        #expect(source.checks == checks)

        await model.newCode()
        #expect(model.code == .ready(ArchivePluginCode(code: "R4TN-8WPX", expiresAtMs: clock.nowMs + 600_000)))
        #expect(source.minted == 2)
    }

    /// Coming back to the screen keeps a code with a while to run; one about to run out is
    /// replaced rather than shown again.
    @Test func comingBackKeepsALiveCodeAndReplacesOneAboutToEnd() async {
        let (model, source, clock) = make()
        await model.load()
        clock.nowMs += 5 * 60_000
        await model.load()
        #expect(source.minted == 1)
        clock.nowMs += 4 * 60_000
        await model.load()
        #expect(source.minted == 2)
        if case .ready(let current) = model.code {
            #expect(current.code == "R4TN-8WPX")
        } else {
            Issue.record("no code")
        }
    }

    /// The clock wakes when the code runs out, or for the next check, whichever is sooner.
    @Test func theClockWakesForExpiryOrTheNextCheck() async {
        let (model, _, clock) = make()
        #expect(model.nextWake == PluginInstallModel.pollInterval)
        await model.load()
        #expect(model.nextWake == PluginInstallModel.pollInterval)
        guard case .ready(let current) = model.code else { return }
        clock.nowMs = current.expiresAtMs - 3_000
        #expect(model.nextWake == .milliseconds(3_050))
    }

    @Test func aCodeTheServerCannotGiveSaysSoAndCanBeAskedForAgain() async {
        let (model, source, _) = make()
        await model.load()
        source.reachable = false
        await model.newCode()
        #expect(model.code == .failed)
        source.reachable = true
        await model.newCode()
        #expect(model.code != .failed)
    }

    // MARK: The hand-off

    @Test func theHandOffSaysWhereTheFileWent() {
        let (model, _, _) = make()
        model.record(.dismissed)
        #expect(model.handoff == .none)
        model.record(.noOpener)
        #expect(model.handoff == .noPebbleApp)
        model.record(.openedIn(bundleIdentifier: "com.example.files"))
        #expect(model.handoff == .sentElsewhere)
        model.record(.openedIn(bundleIdentifier: "coredevices.coreapp"))
        #expect(model.handoff == .sentToPebble)
    }

    /// The menu shows the file's name, so it goes over as "Pebble Audio.pbw", whatever the build
    /// called its copy; and a build without one hands nothing over.
    @Test func thePluginGoesOverUnderItsOwnName() throws {
        let (model, _, _) = make()
        #expect(model.preparePluginFile(bundle: Bundle(for: Clock.self)) == nil)

        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("plugin-bundle-\(UUID().uuidString).bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundle) }
        try Data("pbw".utf8).write(to: bundle.appendingPathComponent("PebbleAudioPlugin.pbw"))
        let built = try #require(Bundle(url: bundle))
        let url = try #require(model.preparePluginFile(bundle: built))
        #expect(url.lastPathComponent == "Pebble Audio.pbw")
        #expect(try Data(contentsOf: url) == Data("pbw".utf8))
    }

    // MARK: Who can read

    /// The plugin reads the server but is not an assistant: the AI Assistants list, the Settings
    /// row, and the Connect step never show it; Who can read lists it under the watch; and the
    /// privacy view still names it, since it can read.
    @Test func thePluginIsListedUnderTheWatchNeverAmongTheAssistants() {
        let source = MockAssistantsSource(nowMs: 1_792_000_000_000)
        func access(_ kind: String, _ id: String, _ name: String, lastUsed: Int64?) -> ArchiveServerStatus.Access {
            .init(kind: kind, id: id, name: name, scopes: ["archive:read"], connectedAtMs: nil, lastUsedAtMs: lastUsed)
        }
        AssistantsDemo.linked(source, scope: .lastDays(90), access: [
            access("oauth", "c1", "ChatGPT", lastUsed: 1_791_999_000_000),
            access("token", "p-old", "Pebble plugin", lastUsed: 1_791_000_000_000),
            access("token", "p-new", " pebble plugin ", lastUsed: 1_791_999_900_000),
            access("token", "k1", "Pebble plugin helper", lastUsed: nil),
        ])

        #expect(source.assistants.map(\.id) == ["c1", "k1"])
        #expect(source.pebblePlugin?.id == "p-new")
        #expect(source.rowValue == "ChatGPT and Pebble plugin helper")
        #expect(source.privacyServer?.assistants.count == 4)
    }
}
