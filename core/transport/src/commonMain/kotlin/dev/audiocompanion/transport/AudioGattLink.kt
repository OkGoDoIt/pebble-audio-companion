package dev.audiocompanion.transport

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow

/** BLE link connection state as seen by the receiver session. */
enum class LinkState {
    Disconnected,
    Connecting,

    /** Connected, services discovered, characteristics resolved, notifications subscribable. */
    Ready,
}

/**
 * Why a connection attempt failed, classified from the platform's own error codes (CoreBluetooth
 * `CBError`/`CBATTError` domains, Android GATT status) — never from a localized message string. The
 * UI copy layer maps each kind to plain, actionable language; the raw [ConnectFailure.detail] is
 * kept only for logs and support reports, never shown as primary status text.
 */
enum class ConnectFailureKind {
    /** Bluetooth is switched off on the phone. */
    BluetoothOff,

    /** The app lacks Bluetooth permission. */
    BluetoothUnauthorized,

    /** Bluetooth LE is unavailable on this device / in this state. */
    BluetoothUnavailable,

    /** Couldn't reach the watch (connect failed or the handshake stalled). */
    WatchUnreachable,

    /**
     * The watch's GATT server rejected an ATT operation (write/read not permitted, insufficient
     * encryption/authentication). In practice this is almost always a **stale iOS GATT cache** after
     * a firmware update — the phone wrote to a handle that moved — and clears when the OS re-discovers
     * (Bluetooth off/on or re-pair). It does not self-heal by retrying the same cached handles.
     */
    LinkRejected,

    /** Anything not otherwise classified. */
    Unknown,
}

/** A classified connection failure plus the raw platform detail (diagnostics only). */
data class ConnectFailure(val kind: ConnectFailureKind, val detail: String? = null)

/**
 * The platform seam (implementation plan Section 6.1). Implemented per platform in
 * :adapter:ble-android / :adapter:ble-ios; :core:* never touches BLE APIs directly,
 * which keeps the whole receiver testable on the JVM with scripted byte streams.
 */
interface AudioGattLink {
    val connectionState: StateFlow<LinkState>

    /** Last platform BLE failure, if the current disconnected state followed an error. */
    val lastFailure: StateFlow<ConnectFailure?>

    /** Reads the Info characteristic (raw 20-byte snapshot). */
    suspend fun readInfo(): ByteArray

    /** Writes one complete control request message to the Control characteristic. */
    suspend fun writeControl(message: ByteArray)

    /** One emission per Control notification (one complete message each). */
    val controlNotifications: Flow<ByteArray>

    /** One emission per Data notification (one complete message each). */
    val dataNotifications: Flow<ByteArray>

    /**
     * Drops the GATT connection (the platform may keep the underlying ACL link for other
     * apps). No-op when already disconnected; [connectionState] moves to Disconnected.
     */
    fun disconnect() {}

    /**
     * Forces a fresh GATT connection without giving up the intent to stay connected: drop the
     * current (possibly stale) connection and immediately reconnect, re-running discovery,
     * subscription and authorization. The receiver session calls this when keepalive pings go
     * unanswered — a half-dead connection the platform still reports as connected. Default no-op
     * for links that cannot self-heal.
     */
    fun resync() {}
}
