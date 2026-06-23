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
 * The platform seam (implementation plan Section 6.1). Implemented per platform in
 * :adapter:ble-android / :adapter:ble-ios; :core:* never touches BLE APIs directly,
 * which keeps the whole receiver testable on the JVM with scripted byte streams.
 */
interface AudioGattLink {
    val connectionState: StateFlow<LinkState>

    /** Last platform BLE failure, if the current disconnected state followed an error. */
    val lastError: StateFlow<String?>

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
