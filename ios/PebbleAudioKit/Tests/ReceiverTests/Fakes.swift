import Foundation
import Receiver
import SegmentStore
import WireProtocol

// Port of `core/transport/src/commonTest/.../Fakes.kt`.

enum FakeLinkError: Error {
    case linkDead
}

/// Scripted `AudioGattLink`: tests push bytes in and capture control writes.
final class FakeAudioGattLink: AudioGattLink, @unchecked Sendable {
    let linkState = StateSubject<LinkState>(.disconnected)
    var connectionState: StateSubject<LinkState> { linkState }

    let failureState = StateSubject<ConnectFailure?>(nil)
    var lastFailure: StateSubject<ConnectFailure?> { failureState }

    private let lock = NSLock()
    private var _controlWrites: [[UInt8]] = []
    private var _failControlWrites = false
    private var _resyncCount = 0
    private var _infoBytes: [UInt8]

    private let controlChannel = ByteChannel()
    private let dataChannel = ByteChannel()

    init(infoBytes: [UInt8] = FakeAudioGattLink.defaultInfo().encode()) {
        _infoBytes = infoBytes
    }

    /// Raw control writes seen by the watch.
    var controlWrites: [[UInt8]] { lock.withLock { _controlWrites } }

    /// When set, control writes throw to simulate a dead link (no ACK ever returns).
    var failControlWrites: Bool {
        get { lock.withLock { _failControlWrites } }
        set { lock.withLock { _failControlWrites = newValue } }
    }

    /// Number of times the session forced a stale-link resync.
    var resyncCount: Int { lock.withLock { _resyncCount } }

    var infoBytes: [UInt8] {
        get { lock.withLock { _infoBytes } }
        set { lock.withLock { _infoBytes = newValue } }
    }

    func readInfo() async throws -> [UInt8] { infoBytes }

    func writeControl(_ message: [UInt8]) async throws {
        try lock.withLock {
            if _failControlWrites { throw FakeLinkError.linkDead }
            _controlWrites.append(message)
        }
    }

    func resync() {
        lock.withLock { _resyncCount += 1 }
    }

    var controlNotifications: AsyncStream<[UInt8]> { controlChannel.stream() }
    var dataNotifications: AsyncStream<[UInt8]> { dataChannel.stream() }

    func pushControl(_ message: AudioCompanionMessage) {
        controlChannel.send(message.encode())
    }

    func pushControlBytes(_ bytes: [UInt8]) {
        controlChannel.send(bytes)
    }

    func pushData(_ message: AudioCompanionMessage) {
        dataChannel.send(message.encode())
    }

    func pushDataBytes(_ bytes: [UInt8]) {
        dataChannel.send(bytes)
    }

    static func defaultInfo(
        serviceStateRaw: UInt8 = 2,
        flags: Int = ProtocolConstants.infoFlagReceiverAuthorized | ProtocolConstants.infoFlagEnabled
    ) -> InfoSnapshot {
        InfoSnapshot(
            infoVersion: 1,
            protocolMin: 1,
            protocolMax: 1,
            serviceStateRaw: serviceStateRaw,
            codecBitmap: ProtocolConstants.codecBitmapSpeexWideband,
            flags: flags,
            fwVersionPacked: (4 << 24) | (9 << 16) | 2
        )
    }
}

enum SinkEvent: Equatable {
    case open(StreamStart)
    case append(streamId: UInt32, frames: [SegmentFrame])
    case gap(streamId: UInt32, gap: GapRecord)
    case close(SegmentCloseReason)
}

final class FakeSegmentSink: SegmentSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [SinkEvent] = []
    private var _open = false

    var events: [SinkEvent] { lock.withLock { _events } }
    var isOpen: Bool { lock.withLock { _open } }

    func openSegment(start: StreamStart, receivedAtMs: Int64, provenance: SegmentProvenance?) async throws {
        lock.withLock {
            _events.append(.open(start))
            _open = true
        }
    }

    func appendFrames(streamId: UInt32, frames: [SegmentFrame]) async throws -> [SegmentFrame] {
        lock.withLock { _events.append(.append(streamId: streamId, frames: frames)) }
        return frames
    }

    func recordGap(streamId: UInt32, gap: GapRecord) async throws {
        lock.withLock { _events.append(.gap(streamId: streamId, gap: gap)) }
    }

    func closeSegment(reason: SegmentCloseReason) async throws {
        lock.withLock {
            guard _open else { return }
            _events.append(.close(reason))
            _open = false
        }
    }

    var opens: [StreamStart] {
        events.compactMap { if case .open(let start) = $0 { return start } else { return nil } }
    }

    var appends: [[SegmentFrame]] {
        events.compactMap { if case .append(_, let frames) = $0 { return frames } else { return nil } }
    }

    var gaps: [GapRecord] {
        events.compactMap { if case .gap(_, let gap) = $0 { return gap } else { return nil } }
    }

    var closes: [SegmentCloseReason] {
        events.compactMap { if case .close(let reason) = $0 { return reason } else { return nil } }
    }
}

final class FakeReceiverPolicy: ReceiverPolicy, @unchecked Sendable {
    private let lock = NSLock()
    private var _flags: UInt32
    private var _freeKb: UInt32

    init(flags: UInt32 = 0, freeKb: UInt32 = 870_400) {
        _flags = flags
        _freeKb = freeKb
    }

    var flags: UInt32 {
        get { lock.withLock { _flags } }
        set { lock.withLock { _flags = newValue } }
    }

    var freeKb: UInt32 {
        get { lock.withLock { _freeKb } }
        set { lock.withLock { _freeKb = newValue } }
    }

    func receiverFlags() -> UInt32 { flags }
    func freeStorageHintKb() -> UInt32 { freeKb }
}

final class FakeResumeStore: ReceiverResumeStore, @unchecked Sendable {
    private let lock = NSLock()
    private var _saved: ReceiverResumeState?
    private var _history: [ReceiverResumeState] = []

    var saved: ReceiverResumeState? { lock.withLock { _saved } }
    var history: [ReceiverResumeState] { lock.withLock { _history } }

    func save(_ state: ReceiverResumeState) async {
        lock.withLock {
            _saved = state
            _history.append(state)
        }
    }

    func load() async -> ReceiverResumeState? { saved }

    func clear() async {
        lock.withLock { _saved = nil }
    }
}
