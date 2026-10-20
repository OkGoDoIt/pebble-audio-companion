import Foundation
import MuseLink
import Receiver
import WireProtocol

/// The audio companion link as the Muse pairing needs it: the watch relays its Muse setup window
/// over the control channel (protocol Section 4.3). `ReceiverService` is the real one.
public protocol MuseWatchLink: Sendable {
    /// Info `watch_capabilities`, nil before the watch's Info has been read.
    var watchCapabilities: UInt32? { get }
    func sendMuseSetup(_ build: @escaping @Sendable (Int) -> [UInt8]) async -> AudioReceiverSession.MuseSetupReply
    func setMuseSetupHandler(_ handler: (@Sendable (AudioReceiverSession.MuseSetupInbound) -> Void)?) async
}

extension ReceiverService: MuseWatchLink {
    public nonisolated var watchCapabilities: UInt32? { watchInfo.value?.watchCapabilities }
}

/// Puts MUSE_SETUP_RX pieces back together into the values the Muse app wrote.
struct MuseRxAssembler {
    enum Result: Equatable {
        case value(Data)
        case incomplete
        /// A value (or part of one) went missing: the setup exchange cannot continue as is.
        case lost
    }

    private var expectedSeq: Int?
    private var partialSeq: Int?
    private var partial = Data()

    mutating func reset() {
        expectedSeq = nil
        partialSeq = nil
        partial = Data()
    }

    mutating func feed(_ rx: MuseSetupRx) -> Result {
        var lost = false
        if let partialSeq, rx.seq != partialSeq {
            // A new value began before the last one finished.
            lost = true
            partial = Data()
            self.partialSeq = nil
        } else if partialSeq == nil, let expectedSeq, rx.seq != expectedSeq {
            // Whole values were skipped.
            lost = true
        }
        partial.append(contentsOf: rx.data)
        if rx.more {
            partialSeq = rx.seq
            return lost ? .lost : .incomplete
        }
        let value = partial
        partial = Data()
        partialSeq = nil
        expectedSeq = (rx.seq + 1) & 0xFF
        return lost ? .lost : .value(value)
    }
}

/// `MuseSetupTransport` over the watch: each packet becomes one MUSE_SETUP_TX, which the watch
/// notifies to the Muse app verbatim.
struct WatchMuseSetupTransport: MuseSetupTransport {
    let link: any MuseWatchLink
    let log: @Sendable (String) -> Void
    /// A busy watch is asked again this often, up to `busyAttempts` times.
    var busyRetry: Duration = .milliseconds(40)
    var busyAttempts = 25

    func send(_ packet: Data) async {
        let bytes = [UInt8](packet)
        guard !bytes.isEmpty, bytes.count <= MuseSetupTx.maxBytes else {
            log("Muse setup: packet of \(bytes.count) bytes does not fit one MUSE_SETUP_TX; dropped")
            return
        }
        for _ in 0..<busyAttempts {
            let reply = await link.sendMuseSetup { MuseSetupTx(requestToken: $0, data: bytes).encode() }
            switch reply {
            case .ok:
                return
            case .busy:
                try? await Task.sleep(for: busyRetry)
            default:
                log("Muse setup: watch did not take a \(bytes.count)-byte packet (\(reply))")
                return
            }
        }
        log("Muse setup: watch stayed busy; dropped a \(bytes.count)-byte packet")
    }

    /// Ends only the Muse app's link to the watch; the phone's own link is untouched.
    func disconnect(after delay: Duration) async {
        try? await Task.sleep(for: delay)
        let reply = await link.sendMuseSetup { MuseSetupDisconnect(requestToken: $0, delayMs: 0).encode() }
        if reply != .ok { log("Muse setup: disconnect not taken (\(reply))") }
    }
}
