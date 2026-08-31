import CompanionRuntime
import Foundation
import Receiver
import StatusUI
import WireProtocol

// The app-side reader for `WatchLinkFault` — the one place the watch's refusal is turned from
// decoded-and-discarded state into something a surface can show.
//
// The receiver has always published `lastProtocolError`, `watchInfo` and `grantedProtoVersion`,
// and nothing anywhere read any of them. The consequence was the quietest failure in the app: a
// receiver the watch had de-authorized reconnected, re-authorized, resynced and reconnected
// again forever, and every surface described that loop as "Connecting…" — accurate, useless, and
// indistinguishable from a watch that was simply out of range.

extension AppComposition {
    /// What the watch said when it turned this phone away, or nil when it has not.
    ///
    /// Read synchronously (the receiver's published state is nonisolated) so the status card,
    /// which is derived on the main actor without an await, can carry it.
    var watchLinkFault: WatchLinkFault? {
        WatchLinkFault.classify(
            state: receiver.state.value,
            protocolError: receiver.lastProtocolError.value,
            info: receiver.watchInfo.value,
            watchServiceStateRaw: receiver.watchServiceState.value
        )
    }

    /// The raw refusal for Detailed Logs and the support report's technical tail. Never shown
    /// beside the sentence a person reads (B20).
    var watchLinkTraceLine: String? {
        watchLinkFaultTrace(
            protocolError: receiver.lastProtocolError.value,
            info: receiver.watchInfo.value
        )
    }
}
