import Foundation
import MuseLink
import Testing
import WireProtocol
@testable import CompanionRuntime

struct MuseTimerTests {
    private func fixture() -> (MuseTools, TimerWatch, MusePreferencesStore) {
        let preferences = MusePreferencesStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        return (MuseTools(preferences: preferences, data: nil), TimerWatch(), preferences)
    }

    @Test func timerLifecyclePreservesOmittedFieldsAndReturnsLiveStatus() async {
        let (tools, watch, _) = fixture()
        await watch.reply("42,2,119001,600\nTea")
        let updated = await tools.run(MuseTools.timersCommand, ["action": "update", "id": 42, "label": "Tea"], watch: watch)
        #expect(updated["payload"]?["remaining_seconds"]?.number == 120)
        #expect(updated["payload"]?["state"]?.string == "paused")
        #expect(await watch.requests.last == .timers(.update, id: 42, label: "Tea"))
        await watch.reply("42,1,100001,600\nTea")
        let status = await tools.run(MuseTools.timersCommand, ["action": "get", "id": 42], watch: watch)
        #expect(status["payload"]?["remaining_seconds"]?.number == 101)
        await watch.reply("")
        let cancelled = await tools.run(MuseTools.timersCommand, ["action": "cancel", "id": 42], watch: watch)
        #expect(cancelled["payload"]?["cancelled"]?.bool == true)
    }

    @Test func listsAllLabelsAndRefusesPartialOrMalformedSnapshots() async {
        let (tools, watch, _) = fixture()
        await watch.reply("42\n43\n")
        await watch.reply("42,1,42001,60\nPasta\nDinner")
        await watch.reply("43,3,0,90\nTea")
        let list = await tools.run(MuseTools.timersCommand, ["action": "list"], watch: watch)
        #expect(list["payload"]?["timers"]?.array?.count == 2)
        #expect(list["payload"]?["timers"]?.array?.first?["label"]?.string == "Pasta\nDinner")
        await watch.reply("broken")
        #expect(await tools.run(MuseTools.timersCommand, ["action": "list"], watch: watch)["ok"]?.bool == false)
        await watch.reply("42\n")
        await watch.reply("44,1,5000,60\nWrong timer")
        #expect(await tools.run(MuseTools.timersCommand, ["action": "list"], watch: watch)["ok"]?.bool == false)
    }

    @Test func rejectsInvalidIDsDurationsAndUnexpectedFieldsWithoutWriting() async {
        let (tools, watch, _) = fixture()
        for params: MuseJSON in [
            ["action": "pause", "id": .number(1.5)], ["action": "get", "id": 0],
            ["action": "create", "seconds": 0], ["action": "create", "seconds": .number(1.1)],
            ["action": "update", "id": 42], ["action": "resume", "id": 42, "seconds": 60],
            ["action": "create", "seconds": 60, "label": true],
            ["action": "create", "seconds": 60, "label": .string(String(repeating: "é", count: 25))],
        ] {
            #expect(await tools.run(MuseTools.timersCommand, params, watch: watch)["ok"]?.bool == false)
        }
        #expect(await watch.requests.isEmpty)
    }

    @Test func retrySharesInFlightWriteAndNewQuestionMayIntentionallyRepeat() async {
        let (tools, watch, _) = fixture()
        await watch.reply("42,1,60000,60\nTea")
        let params: MuseJSON = ["action": "create", "seconds": 60, "label": "Tea"]
        async let first = tools.run(MuseTools.timersCommand, params, watch: watch)
        async let retry = tools.run(MuseTools.timersCommand, params, watch: watch)
        #expect(await first == retry)
        #expect(await watch.requests.count == 1)
        await tools.questionBegan()
        await watch.reply("43,1,60000,60\nTea")
        #expect(await tools.run(MuseTools.timersCommand, params, watch: watch)["payload"]?["id"]?.number == 43)
        #expect(await watch.requests.count == 2)
    }

    @Test func uncertainWriteIsNotRetriedAndRevokedPermissionBeatsCachedSuccess() async {
        let (tools, watch, preferences) = fixture()
        let params: MuseJSON = ["action": "create", "seconds": 60]
        let result = await tools.run(MuseTools.timersCommand, params, watch: watch)
        #expect(result["outcome_unknown"]?.bool == true)
        #expect(await tools.run(MuseTools.timersCommand, params, watch: watch) == result)
        #expect(await watch.requests.count == 1)
        await tools.questionBegan()
        await watch.reply("42,1,60000,60\n")
        #expect(await tools.run(MuseTools.timersCommand, params, watch: watch)["ok"]?.bool == true)
        preferences.update { $0.watchActions.remove(.timer) }
        #expect(await tools.run(MuseTools.timersCommand, params, watch: watch) == MuseTools.turnedOff)
        #expect(await watch.requests.count == 2)
    }

    @Test func anotherTimerDoesNotEraseRetryProtectionAndAliasesShareIt() async {
        let (tools, watch, _) = fixture()
        let tea: MuseJSON = ["action": "create", "seconds": 60, "label": "Tea"]
        let unknown = await tools.run(MuseTools.timersCommand, tea, watch: watch)
        await watch.reply("42,1,90000,90\nPasta")
        _ = await tools.run(MuseTools.timerCommand, ["seconds": 90, "label": "Pasta"], watch: watch)
        #expect(await tools.run(MuseTools.timersCommand, tea, watch: watch) == unknown)
        #expect(await tools.run(MuseTools.timersCommand, ["action": "create", "seconds": 90, "label": "Pasta"], watch: watch)["ok"]?.bool == true)
        #expect(await watch.requests.count == 2)
    }

    @Test func onlyDefinitiveUnsupportedCreationUsesLegacyFallback() async {
        let (tools, watch, _) = fixture()
        await watch.reply("", status: .unsupported)
        await watch.reply("")
        let result = await tools.run(MuseTools.timerCommand, ["seconds": 60], watch: watch)
        #expect(result["payload"]?["managed"]?.bool == false)
        #expect(await watch.requests.last == .timer(seconds: 60, label: ""))
    }
}

private actor TimerWatch: MuseWatchSide {
    var requests: [WatchActionRequest] = []
    var replies: [WatchActionResult] = []
    func reply(_ text: String, status: WatchActionStatus = .done) {
        replies.append(.init(actionId: 1, statusRaw: status.rawValue, text: Array(text.utf8)))
    }
    func runWatchAction(_ request: WatchActionRequest, wait: Duration) async -> WatchActionResult? {
        requests.append(request)
        let result = replies.isEmpty ? nil : replies.removeFirst()
        await Task.yield()
        return result
    }
    func showStatus(_ text: String) async {}
}
