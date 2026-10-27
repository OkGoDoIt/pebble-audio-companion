import Foundation
import Testing

@MainActor @Suite("Focus Quiet Time", .serialized)
struct FocusQuietTimeTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "focus-tests-\(UUID())")!
    }

    private func waitUntil(_ predicate: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Focus sync did not reach the expected state")
        throw TestFailure.timeout
    }
    private enum TestFailure: Error { case timeout, unavailable }

    @Test func optInAndFirmwareGate() async throws {
        let store = defaults()
        let probe = FocusDeliveryProbe()
        let model = FocusQuietTimeController(defaults: store, readSystem: { true }, send: { await probe.send($0) })
        FocusQuietTimeBridge.setFilter(true, in: store)
        model.refreshFromBridge()
        model.connectionChanged(connected: true, supported: false)
        #expect(!model.enabled)
        #expect(model.status == .off)
        #expect(await probe.values.isEmpty)
        model.setEnabled(true)
        #expect(model.status == .needsFirmware)
        #expect(await probe.values.isEmpty)
        model.connectionChanged(connected: true, supported: true)
        try await waitUntil { await probe.values == [true] }
        await probe.finish(.applied)
        try await waitUntil { model.status == .following }
        model.refreshFromBridge()
        model.connectionChanged(connected: true, supported: true)
        #expect(await probe.values == [true])
    }

    @Test func turningOffDrainsAfterAnInflightOn() async throws {
        let probe = FocusDeliveryProbe()
        let model = FocusQuietTimeController(defaults: defaults(), readSystem: { true }, send: { await probe.send($0) })
        model.connectionChanged(connected: true, supported: true)
        model.setEnabled(true)
        try await waitUntil { await probe.values == [true] }
        model.setEnabled(false)
        await probe.finish(.applied)
        try await waitUntil { await probe.values == [true, false] }
        await probe.finish(.applied)
        try await waitUntil { model.status == .off }
    }

    @Test func latestFocusWinsAndARepeatedSignalDoesNotRewrite() async throws {
        let store = defaults()
        let probe = FocusDeliveryProbe()
        let model = FocusQuietTimeController(defaults: store, readSystem: { true }, send: { await probe.send($0) })
        model.connectionChanged(connected: true, supported: true)
        model.setEnabled(true)
        try await waitUntil { await probe.values == [true] }
        FocusQuietTimeBridge.setFilter(false, in: store)
        model.refreshFromBridge()
        await probe.finish(.applied)
        try await waitUntil { await probe.values == [true, false] }
        await probe.finish(.applied)
        try await waitUntil { model.status == .ready }
        FocusQuietTimeBridge.setFilter(false, in: store)
        model.refreshFromBridge()
        #expect(await probe.values == [true, false])
    }

    @Test func reconnectIgnoresOldAcknowledgmentAndReadsCurrentFocus() async throws {
        let probe = FocusDeliveryProbe()
        let query = FocusQueryProbe()
        let model = FocusQuietTimeController(defaults: defaults(), readSystem: { await query.value }, send: { await probe.send($0) })
        model.connectionChanged(connected: true, supported: true)
        model.setEnabled(true)
        try await waitUntil { await probe.values == [true] }
        model.connectionChanged(connected: false, supported: false)
        await query.set(false)
        model.connectionChanged(connected: true, supported: true)
        await model.refreshSystem()
        await probe.finish(.applied)
        try await waitUntil { await probe.values == [true, false] }
        await probe.finish(.applied)
        try await waitUntil { model.status == .ready }
    }

    @Test func failedDeliveryIsPendingAndRetriesIdempotently() async throws {
        let probe = FocusDeliveryProbe()
        let model = FocusQuietTimeController(defaults: defaults(), readSystem: { true }, send: { await probe.send($0) })
        model.connectionChanged(connected: true, supported: true)
        model.setEnabled(true)
        try await waitUntil { await probe.values == [true] }
        await probe.finish(.retry)
        try await waitUntil { model.status == .retry }
        model.refreshFromBridge()
        try await waitUntil { await probe.values == [true, true] }
        await probe.finish(.applied)
        try await waitUntil { model.status == .following }
    }

    @Test func newerFilterInvocationWinsOverAnInflightSystemLookup() async throws {
        let store = defaults()
        let probe = FocusDeliveryProbe()
        let query = FocusDelayedQuery()
        let model = FocusQuietTimeController(defaults: store, readSystem: { await query.read() }, send: { await probe.send($0) })
        model.connectionChanged(connected: true, supported: true)
        model.setEnabled(true)
        try await waitUntil { await query.waiting }
        FocusQuietTimeBridge.setFilter(false, in: store)
        model.refreshFromBridge()
        try await waitUntil { await probe.values == [false] }
        await query.finish(true)
        await probe.finish(.applied)
        try await waitUntil { model.status == .ready }
        #expect(!model.filterQuiet)
        #expect(await probe.values == [false])
    }

    @Test func stalePersistedOnIsNotReplayedAfterFailedSystemRead() async throws {
        let store = defaults()
        store.set(true, forKey: FocusQuietTimeBridge.enabledKey)
        FocusQuietTimeBridge.setFilter(true, in: store)
        let probe = FocusDeliveryProbe()
        let model = FocusQuietTimeController(defaults: store, readSystem: { throw TestFailure.unavailable }, send: { await probe.send($0) })
        model.connectionChanged(connected: true, supported: true)
        await model.refreshSystem()
        model.refreshFromBridge()
        #expect(await probe.values.isEmpty)
        #expect(model.status == .checking)
    }

    @Test func focusFilterDefaultsOffAndSuggestsOnWithoutEnablingSync() async throws {
        let intent = QuietTimeFocusFilter()
        #expect(intent.quietTime == false)
        let store = defaults()
        FocusQuietTimeBridge.setFilter(true, in: store)
        #expect(!store.bool(forKey: FocusQuietTimeBridge.enabledKey))
        intent.quietTime = true
        #expect(intent.quietTime)
    }
}

private actor FocusDeliveryProbe {
    var values: [Bool] = []
    private var pending: CheckedContinuation<FocusQuietTimeController.Delivery, Never>?
    func send(_ value: Bool) async -> FocusQuietTimeController.Delivery {
        values.append(value)
        return await withCheckedContinuation { pending = $0 }
    }
    func finish(_ result: FocusQuietTimeController.Delivery) {
        let continuation = pending
        pending = nil
        continuation?.resume(returning: result)
    }
}
private actor FocusQueryProbe {
    var value = true
    func set(_ value: Bool) { self.value = value }
}

private actor FocusDelayedQuery {
    var waiting = false
    private var pending: CheckedContinuation<Bool, Never>?
    func read() async -> Bool {
        waiting = true
        return await withCheckedContinuation { pending = $0 }
    }
    func finish(_ value: Bool) { pending?.resume(returning: value); pending = nil }
}
