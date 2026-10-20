import Foundation
import MuseLink
import Receiver
import Testing
import WireProtocol

@testable import CompanionRuntime

/// Muse pairing through the watch's relay (protocol Section 4.3), against a fake watch that
/// records every MUSE_SETUP_* request and answers with scripted ACKs.
struct MuseGadgetServiceTests {
    @Test func pairingRunsTheSetupProtocolThroughTheWatch() async throws {
        let fx = MuseFixture()
        await fx.service.startPairing()

        let open = try #require(fx.link.requests(MuseSetupOpen.self).first)
        let identity = try #require(fx.secrets.identity())
        #expect(open.suffix == identity.suffix.uppercased())
        #expect(open.windowSeconds == MuseGadgetService.windowSeconds)
        #expect(fx.service.pairing.value == .confirmOnWatch)

        fx.link.push(.event(event(.opened, secondsLeft: 300)))
        #expect(await fx.waitUntil { fx.service.pairing.value == .waitingForMuse(gadgetName: identity.bleName, secondsLeft: 300) })
        fx.link.push(.event(event(.clientConnected, mtu: 256, secondsLeft: 290)))
        #expect(await fx.waitUntil { fx.service.pairing.value == .museConnected(gadgetName: identity.bleName) })

        // The Muse app's first write, split by the watch across two notifications.
        let write = Array(#"{"action":"get_device_info"}"#.utf8)
        fx.link.push(.rx(MuseSetupRx(seq: 0, flags: 1, data: Array(write[..<10]))))
        fx.link.push(.rx(MuseSetupRx(seq: 0, flags: 0, data: Array(write[10...]))))

        let reply = await fx.waitForReply()
        let info = try #require(reply)
        #expect(info["type"]?.string == "device_info")
        #expect(info["node_id"]?.string == identity.nodeID)
        #expect(info["network_ready"]?.bool == true)
        // Nothing about the watch goes to Meta: the version is the gadget's own, fixed.
        #expect(info["version"]?.string == MuseGadgetService.gadgetVersion)
    }

    @Test func aBusyWatchIsAskedAgain() async throws {
        let fx = MuseFixture()
        fx.link.busyTxReplies = 2
        await fx.service.startPairing()
        fx.link.push(.event(event(.opened, secondsLeft: 300)))
        fx.link.push(.event(event(.clientConnected, mtu: 256, secondsLeft: 290)))
        fx.link.push(.rx(MuseSetupRx(seq: 0, flags: 0, data: Array(#"{"action":"get_device_info"}"#.utf8))))

        let reply = await fx.waitForReply()
        #expect(reply?["type"]?.string == "device_info")
        // Two refusals, then every packet once.
        let sent = fx.link.requests(MuseSetupTx.self)
        let packets = Set(sent.map(\.data))
        #expect(sent.count == packets.count + 2)
    }

    @Test func aWindowThatTimesOutBeforeMuseConnectsSaysSo() async {
        let fx = MuseFixture()
        await fx.service.startPairing()
        fx.link.push(.event(event(.opened, secondsLeft: 300)))
        fx.link.push(.event(event(.closed, detail: MuseSetupCloseReason.timeout.rawValue)))
        #expect(await fx.waitUntil { fx.service.pairing.value == .failed(.timedOut) })
        #expect(await fx.waitUntil { !fx.link.hasHandler })

        // Connected, then timed out: the setup did not finish.
        await fx.service.startPairing()
        fx.link.push(.event(event(.opened, secondsLeft: 300)))
        fx.link.push(.event(event(.clientConnected, mtu: 256, secondsLeft: 200)))
        fx.link.push(.event(event(.closed, detail: MuseSetupCloseReason.timeout.rawValue)))
        #expect(await fx.waitUntil { fx.service.pairing.value == .failed(.didNotFinish) })
    }

    @Test func aWindowLeftOpenIsClearedFirst() async {
        let fx = MuseFixture()
        fx.link.openReplies = [.badState, .ok]
        await fx.service.startPairing()
        let requests = fx.link.sentMessages()
        #expect(requests.count == 3)
        #expect(requests.first is MuseSetupOpen)
        #expect((requests.dropFirst().first as? MuseSetupClose)?.reason == .cancelled)
        #expect(requests.last is MuseSetupOpen)
        #expect(fx.service.pairing.value == .confirmOnWatch)

        // The cleared window's Closed is not this attempt's ending.
        fx.link.push(.event(event(.closed, detail: MuseSetupCloseReason.appCancelled.rawValue)))
        fx.link.push(.event(event(.opened, secondsLeft: 300)))
        #expect(await fx.waitUntil { if case .waitingForMuse = fx.service.pairing.value { true } else { false } })

        // Saying no on the watch is not a failure.
        fx.link.push(.event(event(.closed, detail: MuseSetupCloseReason.declinedOnWatch.rawValue)))
        #expect(await fx.waitUntil { fx.service.pairing.value == .idle })
    }

    @Test func cancellingClosesTheWindow() async {
        let fx = MuseFixture()
        await fx.service.startPairing()
        fx.link.push(.event(event(.opened, secondsLeft: 300)))
        #expect(await fx.waitUntil { fx.service.pairing.value.isActive && fx.service.pairing.value != .confirmOnWatch })
        await fx.service.cancelPairing()
        #expect((fx.link.sentMessages().last as? MuseSetupClose)?.reason == .cancelled)
        fx.link.push(.event(event(.closed, detail: MuseSetupCloseReason.appCancelled.rawValue)))
        #expect(await fx.waitUntil { fx.service.pairing.value == .idle })
    }

    @Test func lostSetupTrafficRestartsTheMuseAppsLink() async {
        let fx = MuseFixture()
        await fx.service.startPairing()
        fx.link.push(.event(event(.opened, secondsLeft: 300)))
        fx.link.push(.event(event(.clientConnected, mtu: 256, secondsLeft: 290)))
        fx.link.push(.rx(MuseSetupRx(seq: 0, flags: 0, data: Array("{}".utf8))))
        fx.link.push(.rx(MuseSetupRx(seq: 2, flags: 0, data: Array("{}".utf8))))  // seq 1 went missing
        #expect(await fx.waitUntil { !fx.link.requests(MuseSetupDisconnect.self).isEmpty })
    }

    @Test func aWatchThatCannotHostTheWindowIsNotAsked() async {
        let fx = MuseFixture()
        fx.link.capabilities = 0
        await fx.service.startPairing()
        #expect(fx.service.pairing.value == .failed(.watchNeedsUpdate))
        fx.link.capabilities = nil
        await fx.service.startPairing()
        #expect(fx.service.pairing.value == .failed(.watchNotConnected))
        #expect(fx.link.sentMessages().isEmpty)
    }

    @Test func theAssemblerNoticesMissingValues() {
        var assembler = MuseRxAssembler()
        #expect(assembler.feed(MuseSetupRx(seq: 0, flags: 1, data: [1])) == .incomplete)
        #expect(assembler.feed(MuseSetupRx(seq: 0, flags: 0, data: [2])) == .value(Data([1, 2])))
        #expect(assembler.feed(MuseSetupRx(seq: 1, flags: 0, data: [3])) == .value(Data([3])))
        #expect(assembler.feed(MuseSetupRx(seq: 3, flags: 0, data: [4])) == .lost)
        #expect(assembler.feed(MuseSetupRx(seq: 4, flags: 1, data: [5])) == .incomplete)
        #expect(assembler.feed(MuseSetupRx(seq: 5, flags: 0, data: [6])) == .lost)  // 4 never ended
        #expect(assembler.feed(MuseSetupRx(seq: 255, flags: 0, data: [7])) == .lost)
        #expect(assembler.feed(MuseSetupRx(seq: 0, flags: 0, data: [8])) == .value(Data([8])))  // wraps
    }

    @Test func forgettingKeepsTheIdentity() async {
        let fx = MuseFixture()
        let identity = fx.secrets.loadOrCreateIdentity()
        await fx.service.forget()
        #expect(fx.secrets.identity() == identity)
        #expect(fx.service.pairedName.value == nil)
    }
}

// MARK: - Fixture

private func event(
    _ kind: MuseSetupEventKind, detail: UInt8 = 0, mtu: Int = 0, secondsLeft: Int = 0
) -> MuseSetupEvent {
    MuseSetupEvent(eventRaw: kind.rawValue, detail: detail, mtu: mtu, secondsLeft: secondsLeft)
}

private struct AlwaysOnline: MuseSetupNetwork {
    func isOnline() async -> Bool { true }
}

private struct MuseFixture {
    let link = FakeMuseWatchLink()
    let secrets = InMemoryMuseSecrets(sdkToken: "sdk-test-token")
    let service: MuseGadgetService

    init() {
        service = MuseGadgetService(link: link, secrets: secrets, network: AlwaysOnline())
    }

    func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<300 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// The gadget's reply, put back together from the MUSE_SETUP_TX packets.
    func waitForReply() async -> MuseJSON? {
        var reply: MuseJSON?
        _ = await waitUntil {
            var assembler = MuseChunkAssembler()
            for tx in link.uniqueTxInOrder() {
                if let message = assembler.feed(Data(tx)) { reply = MuseJSON.parse(message) }
            }
            return reply != nil
        }
        return reply
    }
}

private final class FakeMuseWatchLink: MuseWatchLink, @unchecked Sendable {
    private let lock = NSLock()
    private var _capabilities: UInt32? = ProtocolConstants.capabilityMuseSetup
    private var handler: (@Sendable (AudioReceiverSession.MuseSetupInbound) -> Void)?
    private var sent: [[UInt8]] = []
    private var token = 0
    private var _busyTxReplies = 0
    private var _openReplies: [AudioReceiverSession.MuseSetupReply] = []

    var capabilities: UInt32? {
        get { lock.withLock { _capabilities } }
        set { lock.withLock { _capabilities = newValue } }
    }
    var busyTxReplies: Int {
        get { lock.withLock { _busyTxReplies } }
        set { lock.withLock { _busyTxReplies = newValue } }
    }
    var openReplies: [AudioReceiverSession.MuseSetupReply] {
        get { lock.withLock { _openReplies } }
        set { lock.withLock { _openReplies = newValue } }
    }
    var hasHandler: Bool { lock.withLock { handler != nil } }

    var watchCapabilities: UInt32? { capabilities }

    func sendMuseSetup(_ build: @escaping @Sendable (Int) -> [UInt8]) async -> AudioReceiverSession.MuseSetupReply {
        lock.withLock {
            token = (token + 1) & 0xFF
            let bytes = build(token)
            sent.append(bytes)
            switch bytes.first.map(Int.init) {
            case MessageId.museSetupOpen:
                return _openReplies.isEmpty ? .ok : _openReplies.removeFirst()
            case MessageId.museSetupTx where _busyTxReplies > 0:
                _busyTxReplies -= 1
                return .busy
            default:
                return .ok
            }
        }
    }

    func setMuseSetupHandler(_ handler: (@Sendable (AudioReceiverSession.MuseSetupInbound) -> Void)?) async {
        lock.withLock { self.handler = handler }
    }

    func push(_ inbound: AudioReceiverSession.MuseSetupInbound) {
        let handler = lock.withLock { self.handler }
        handler?(inbound)
    }

    func sentMessages() -> [ControlInMessage] {
        lock.withLock { sent }.compactMap { bytes in
            if case .decoded(let message) = AudioCompanionProtocol.decodeControlIn(bytes) {
                return message as? ControlInMessage
            }
            return nil
        }
    }

    func requests<T>(_ type: T.Type) -> [T] {
        sentMessages().compactMap { $0 as? T }
    }

    /// TX payloads in send order, each once (a busy reply means the same packet is sent again).
    func uniqueTxInOrder() -> [[UInt8]] {
        var seen: [[UInt8]] = []
        var last: [UInt8]?
        for tx in requests(MuseSetupTx.self) where tx.data != last {
            seen.append(tx.data)
            last = tx.data
        }
        return seen
    }
}
