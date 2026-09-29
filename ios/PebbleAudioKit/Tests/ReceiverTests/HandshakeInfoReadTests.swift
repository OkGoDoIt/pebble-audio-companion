import Foundation
import Receiver
import SegmentStore
import Testing
import WireProtocol

// The link keeps one Info read in flight and refuses a second, and the handshake's read is the
// one that must not be refused. On 2026-09-19 14:19:54 foreground entry asked the watch what it
// was doing while the link was still subscribing; the link reached Ready 400 ms later and the
// handshake's read collided with that one ("handshake failed (1); rebuilding the link in 2000 ms:
// operationInFlight"), costing a cancel-and-reconnect of a link that was working.
@Suite struct HandshakeInfoReadTests {

    private func authRequests(_ fx: FakeSinkSession) -> [AuthRequest] {
        fx.link.controlWrites.compactMap {
            if case .decoded(let m) = AudioCompanionProtocol.decodeControlIn($0) { return m as? AuthRequest }
            return nil
        }
    }

    @Test("a handshake that meets an on-demand verify's Info read waits for it instead of failing")
    func theHandshakeWaitsForTheSessionsOwnRead() async {
        let fx = FakeSinkSession()
        fx.link.setInfoReadLatency(100, on: fx.clock)

        // Still subscribing when the app comes to the foreground and asks the watch.
        fx.link.linkState.value = .connecting
        await fx.waitUntil { fx.session.state.value == .connecting }
        let session = fx.session
        let verify = Task { await session.verifyWatchState() }
        await fx.clock.settle()

        // The link reaches Ready with that read still out.
        fx.link.linkState.value = .ready
        await fx.clock.settle()
        #expect(fx.session.state.value == .authorizing)
        #expect(authRequests(fx).isEmpty, "the handshake waits for the read it would collide with")

        await fx.clock.advance(by: 400)
        #expect(await verify.value, "the verify still gets its answer")
        #expect(authRequests(fx).count == 1, "then the handshake reads Info itself and asks to authorize")
        #expect(fx.link.resyncCount == 0, "no rebuild of a link that was working")
        if case .connectionFailed = fx.session.state.value {
            Issue.record("the handshake must not fail on its own session's read")
        }
    }
}
