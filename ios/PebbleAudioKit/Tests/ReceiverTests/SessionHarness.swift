import Foundation
import Receiver
import SegmentStore
import Testing
import WireProtocol

// A receiver session wired to the REAL segment store, for the tests that are about what ends up
// on disk rather than about the order of sink calls. `AudioReceiverSessionTests` drives a fake
// sink; these drive `SegmentStore` through the same fake link and virtual clock.

/// The real store, with every call reported to the harness's ledger so `settle()` can see the
/// session working through it — and counted, so a test can wait for the audio it pushed.
final class LedgerSink: SegmentSink, @unchecked Sendable {
    let store: SegmentStore
    private let scheduler: TestScheduler
    private let lock = NSLock()
    private var _lastAppended: UInt32?
    private var _appendCalls = 0
    private var _ledger: [Entry] = []

    /// Every append and gap write, in the order the session made them.
    enum Entry: Equatable {
        case append(first: UInt32)
        case gap(first: UInt32, count: UInt32)
    }

    init(store: SegmentStore, scheduler: TestScheduler) {
        self.store = store
        self.scheduler = scheduler
    }

    /// Highest sequence the session has handed to `appendFrames` (whether or not it was new).
    var lastAppended: UInt32? { lock.withLock { _lastAppended } }
    var appendCalls: Int { lock.withLock { _appendCalls } }
    var ledger: [Entry] { lock.withLock { _ledger } }

    func openSegment(
        start: StreamStart, receivedAtMs: Int64, provenance: SegmentProvenance?
    ) async throws -> StreamContinuation? {
        scheduler.noteEvent()
        defer { scheduler.noteEvent() }
        return try await store.openSegment(start: start, receivedAtMs: receivedAtMs, provenance: provenance)
    }

    func appendFrames(streamId: UInt32, frames: [SegmentFrame]) async throws -> [SegmentFrame] {
        scheduler.noteEvent()
        defer { scheduler.noteEvent() }
        let accepted = try await store.appendFrames(streamId: streamId, frames: frames)
        lock.withLock {
            if let first = frames.first?.sequence { _ledger.append(.append(first: first)) }
            _appendCalls += 1
            if let last = frames.last?.sequence { _lastAppended = max(_lastAppended ?? 0, last) }
        }
        return accepted
    }

    func recordGap(streamId: UInt32, gap: GapRecord) async throws {
        scheduler.noteEvent()
        defer { scheduler.noteEvent() }
        try await store.recordGap(streamId: streamId, gap: gap)
        lock.withLock {
            _ledger.append(.gap(first: gap.firstMissingSequence, count: gap.missingFrameCount))
        }
    }

    func closeSegment(reason: SegmentCloseReason) async throws {
        scheduler.noteEvent()
        defer { scheduler.noteEvent() }
        try await store.closeSegment(reason: reason)
    }

    func flush() async throws {
        try await store.flush()
    }
}

/// Thread-safe line capture for a session's `ReceiverLog`.
final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    func append(_ line: String) { lock.withLock { _lines.append(line) } }
    var lines: [String] { lock.withLock { _lines } }
}

/// One session over the recording fake sink, with its log captured. The cadence is the 2 s /
/// 500 ms checkpoint schedule the KMP contract tests were written against.
final class FakeSinkSession {
    let scheduler = TestScheduler()
    let clock: TestClock
    let link: FakeAudioGattLink
    let sink: FakeSegmentSink
    let resumeStore: FakeResumeStore
    let session: AudioReceiverSession
    let lines = LineBox()
    private let task: Task<Void, Never>

    init() {
        clock = TestClock(scheduler: scheduler)
        link = FakeAudioGattLink(scheduler: scheduler)
        sink = FakeSegmentSink(scheduler: scheduler)
        resumeStore = FakeResumeStore(scheduler: scheduler)
        session = AudioReceiverSession(
            link: link, sink: sink, policy: FakeReceiverPolicy(), resumeStore: resumeStore,
            config: ReceiverConfig(
                receiverId: Array(repeating: 3, count: 32), receiverName: "fake-sink",
                checkpointAudioMs: 2_000, checkpointMinIntervalMs: 500),
            clock: clock, log: ReceiverLog { [lines] in lines.append($0) })
        task = session.start()
    }

    deinit { task.cancel() }

    @discardableResult
    func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<500 {
            await clock.settle()
            if condition() { return true }
        }
        return false
    }

    func authorize() async {
        let before = link.controlWrites.count
        link.linkState.value = .ready
        await waitUntil { self.link.controlWrites.count > before }
        let token = link.controlWrites.compactMap { bytes -> AuthRequest? in
            if case .decoded(let m) = AudioCompanionProtocol.decodeControlIn(bytes) { return m as? AuthRequest }
            return nil
        }.last?.requestToken ?? -1
        link.pushControl(AuthResult(requestToken: token, statusRaw: 0, grantedProtoVersion: 1))
        await waitUntil { self.session.state.value == .authorized }
    }

    func disconnect() async {
        link.linkState.value = .disconnected
        await waitUntil { self.session.state.value == .disconnected }
    }

    func checkpoints() -> [Checkpoint] {
        link.controlWrites.compactMap {
            if case .decoded(let m) = AudioCompanionProtocol.decodeControlIn($0) { return m as? Checkpoint }
            return nil
        }
    }
}

/// One session over a real store in a temporary directory.
final class StoreBackedSession {
    let scheduler = TestScheduler()
    let clock: TestClock
    let link: FakeAudioGattLink
    let store: SegmentStore
    let sink: LedgerSink
    let resumeStore: FakeResumeStore
    let session: AudioReceiverSession
    let root: URL
    private let task: Task<Void, Never>

    init(log: ReceiverLog = .silent) throws {
        clock = TestClock(scheduler: scheduler)
        link = FakeAudioGattLink(scheduler: scheduler)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // One clock for both: the session stamps `receivedAtMs` from its own, and the store's
        // reattach window compares that against the close time it stamped from this one.
        store = SegmentStore(root: root, nowMs: { [clock] in clock.nowMs })
        sink = LedgerSink(store: store, scheduler: scheduler)
        resumeStore = FakeResumeStore(scheduler: scheduler)
        session = AudioReceiverSession(
            link: link, sink: sink, policy: FakeReceiverPolicy(), resumeStore: resumeStore,
            config: ReceiverConfig(receiverId: Array(repeating: 7, count: 32), receiverName: "harness"),
            clock: clock, log: log)
        task = session.start()
    }

    deinit {
        task.cancel()
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<2_000 {
            await clock.settle()
            if condition() { return true }
        }
        return false
    }

    func connectAndAuthorize() async throws {
        let before = link.controlWrites.count
        link.linkState.value = .ready
        try #require(await waitUntil { link.controlWrites.count > before }, "no AUTH_REQUEST")
        let token = try #require(
            link.controlWrites.compactMap { bytes -> AuthRequest? in
                if case .decoded(let m) = AudioCompanionProtocol.decodeControlIn(bytes) { return m as? AuthRequest }
                return nil
            }.last
        ).requestToken
        link.pushControl(AuthResult(requestToken: token, statusRaw: 0, grantedProtoVersion: 1))
        try #require(await waitUntil { self.session.state.value == .authorized }, "not authorized")
    }

    func disconnect() async throws {
        link.linkState.value = .disconnected
        try #require(await waitUntil { self.session.state.value == .disconnected }, "teardown did not finish")
    }

    /// Pushes frames and waits until the session has handed the last of them to the store.
    func push(_ data: StreamData) async throws {
        link.pushData(data)
        let last = data.firstSequence + UInt32(data.frameCount) - 1
        try #require(
            await waitUntil { (self.sink.lastAppended ?? 0) >= last }, "frames through \(last) never reached the store")
    }

    func checkpoints() -> [Checkpoint] {
        link.controlWrites.compactMap {
            if case .decoded(let m) = AudioCompanionProtocol.decodeControlIn($0) { return m as? Checkpoint }
            return nil
        }
    }

    func segments() async -> [SegmentMeta] { await store.listSegments() }
}
