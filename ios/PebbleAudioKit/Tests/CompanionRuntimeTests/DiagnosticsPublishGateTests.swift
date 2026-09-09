import CompanionRuntime
import Foundation
import Receiver
import SegmentStore
import Testing

// The refresh loop that drained the phone at a full CPU core, pinned at the layer it fed on.
//
// `DiagnosticsService.refresh()` used to publish on every call, because `RuntimeDiagnostics`
// carries a timestamp and the synthesized equality treated a new timestamp as a change. Any
// observer that refreshed in response to an emission therefore looped forever: the Diagnostics
// screen's data source did exactly that (it built its support report through
// `CompanionRuntime.supportReport()`, which refreshes), and the process spent sixty-three CPU
// seconds a minute in the background for as long as residency kept it awake. The bus is now
// cycle-safe by construction: a refresh that changes nothing publishes nothing.
@Suite struct DiagnosticsPublishGateTests {
    private final class FakeFreeSpace: FreeSpaceProvider, @unchecked Sendable {
        func freeBytes() -> Int64 { 10 * 1024 * 1024 * 1024 }
    }

    /// A clock where every read is a new moment, so every refresh carries a new timestamp --
    /// which is exactly what made the synthesized equality treat every refresh as a change.
    /// (The virtual-time `TestClock` cannot be advanced from inside an observer without a parked
    /// sleeper to settle on, and a real clock could hand two refreshes the same millisecond.)
    private final class TickingClock: ReceiverClock, @unchecked Sendable {
        private let lock = NSLock()
        private var now: Int64 = 1_000
        var nowMs: Int64 {
            lock.withLock {
                now += 1_000
                return now
            }
        }
        func sleep(ms: Int64) async throws {
            try await Task.sleep(nanoseconds: UInt64(max(ms, 0)) * 1_000_000)
        }
    }

    private func makeService(clock: TickingClock) throws -> (DiagnosticsService, SegmentStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("diag-gate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = SegmentStore(root: root, nowMs: { clock.nowMs })
        let retention = RetentionManager(
            store: store, freeSpace: FakeFreeSpace(), nowMs: { clock.nowMs },
            config: RetentionConfig())
        let service = DiagnosticsService(
            store: store, retention: retention, tasks: { [] }, isForeground: { true },
            clock: clock)
        return (service, store)
    }

    @Test func aRefreshThatChangesNothingPublishesNothing() async throws {
        let clock = TickingClock()
        let (service, _) = try makeService(clock: clock)

        await service.refresh()
        await service.refresh()
        await service.refresh()

        #expect(service.refreshCount == 3)
        #expect(service.publishCount == 1, "only the first refresh had anything new to say")
    }

    /// The exact shape of the bug: an observer that refreshes on every emission. It must run
    /// twice — once for the replayed initial value, once for the first real snapshot — and then
    /// starve, because the second refresh changes nothing and so publishes nothing.
    @Test func anObserverThatRefreshesOnEveryEmissionCannotLoop() async throws {
        let clock = TickingClock()
        let (service, _) = try makeService(clock: clock)

        let observer = Task {
            for await _ in service.snapshot.stream() {
                await service.refresh()
            }
        }
        // Real time, deliberately: a loop would spin thousands of turns in this window.
        try await Task.sleep(nanoseconds: 300_000_000)
        observer.cancel()

        #expect(service.refreshCount <= 3, "refresh ran \(service.refreshCount) times: the loop is back")
        #expect(service.publishCount == 1)
    }

    @Test func aRealChangeStillPublishes() async throws {
        let clock = TickingClock()
        let (service, store) = try makeService(clock: clock)
        await service.refresh()
        #expect(service.publishCount == 1)

        try await store.openSegment(
            start: Fixture.streamStart(), receivedAtMs: clock.nowMs, provenance: nil)
        await service.refresh()

        #expect(service.publishCount == 2)
        #expect(service.snapshot.value.openSegmentId != nil)
    }
}
