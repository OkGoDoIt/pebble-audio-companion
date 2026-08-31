import Foundation

// Port of `core/transport/.../AudioGattLink.kt` — the platform seam (implementation plan 6.1).
// Implemented by `CoreBluetoothAudioGattLink`; the receiver session never touches BLE APIs
// directly, which keeps it testable with scripted byte streams.

/// BLE link connection state as seen by the receiver session.
public enum LinkState: Sendable, Equatable {
    case disconnected
    case connecting

    /// Connected, services discovered, characteristics resolved, notifications subscribable.
    case ready
}

/// Why a connection attempt failed, classified from the platform's own error codes (CoreBluetooth
/// `CBError`/`CBATTError` domains) — never from a localized message string. The UI copy layer maps
/// each kind to plain, actionable language; the raw `ConnectFailure.detail` is kept only for logs
/// and support reports, never shown as primary status text.
public enum ConnectFailureKind: Sendable, Equatable {
    /// Bluetooth is switched off on the phone.
    case bluetoothOff

    /// The app lacks Bluetooth permission.
    case bluetoothUnauthorized

    /// Bluetooth LE is unavailable on this device / in this state.
    case bluetoothUnavailable

    /// Couldn't reach the watch (connect failed or the handshake stalled).
    case watchUnreachable

    /// The watch's GATT server rejected an ATT operation (write/read not permitted, insufficient
    /// encryption/authentication). In practice this is almost always a **stale iOS GATT cache**
    /// after a firmware update — the phone wrote to a handle that moved — and clears when the OS
    /// re-discovers (Bluetooth off/on or re-pair). It does not self-heal by retrying the same
    /// cached handles.
    case linkRejected

    /// Anything not otherwise classified.
    case unknown
}

/// A classified connection failure plus the raw platform detail (diagnostics only).
public struct ConnectFailure: Sendable, Equatable {
    public let kind: ConnectFailureKind
    public let detail: String?

    public init(kind: ConnectFailureKind, detail: String? = nil) {
        self.kind = kind
        self.detail = detail
    }
}

/// The platform seam. All BLE specifics live behind this protocol so the whole receiver is
/// testable with fakes on any platform.
public protocol AudioGattLink: Sendable {
    var connectionState: StateSubject<LinkState> { get }

    /// Last platform BLE failure, if the current disconnected state followed an error.
    var lastFailure: StateSubject<ConnectFailure?> { get }

    /// The advertised name of the watch this link is bound to ("Pebble Time 2 A1B2"), or nil
    /// when no watch has ever been seen. Published rather than fetched: the name arrives with
    /// discovery, long after the settings screen has drawn itself. Links that cannot name their
    /// peer (fakes, command-line tools) keep the default and never publish one.
    var deviceName: StateSubject<String?> { get }

    /// Reads the Info characteristic (raw 20-byte snapshot).
    func readInfo() async throws -> [UInt8]

    /// Writes one complete control request message to the Control characteristic.
    func writeControl(_ message: [UInt8]) async throws

    /// One emission per Control notification (one complete message each).
    var controlNotifications: AsyncStream<[UInt8]> { get }

    /// One emission per Data notification (one complete message each).
    var dataNotifications: AsyncStream<[UInt8]> { get }

    /// Expresses the intent to hold a GATT connection, and starts working towards one.
    ///
    /// Idempotent and non-destructive: a live or in-progress link is left alone, so it is safe on
    /// every launch and foreground entry. It never asks the watch to enable Background Audio —
    /// that prompt has its own one-shot arming (plan 4.2). Default no-op for links that cannot
    /// dial (fakes, command-line tools).
    func connect()

    /// Drops the GATT connection (the platform may keep the underlying ACL link for other
    /// apps). No-op when already disconnected; `connectionState` moves to Disconnected.
    func disconnect()

    /// Forces a fresh GATT connection without giving up the intent to stay connected: drop the
    /// current (possibly stale) connection and immediately reconnect, re-running discovery,
    /// subscription and authorization. The receiver session calls this when keepalive pings go
    /// unanswered — a half-dead connection the platform still reports as connected. Default
    /// no-op for links that cannot self-heal.
    func resync()
}

/// One shared, permanently-nil subject for links that never learn a peer name. Shared on
/// purpose: a computed property that minted a new subject per access would hand every
/// subscriber its own stream and silently drop the (correct) nil.
private let unnamedDevice = StateSubject<String?>(nil)

public extension AudioGattLink {
    var deviceName: StateSubject<String?> { unnamedDevice }
    func connect() {}
    func disconnect() {}
    func resync() {}
}
