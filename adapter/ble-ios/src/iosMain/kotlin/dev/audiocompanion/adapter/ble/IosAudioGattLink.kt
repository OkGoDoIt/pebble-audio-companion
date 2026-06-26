package dev.audiocompanion.adapter.ble

import dev.audiocompanion.protocol.ProtocolConstants
import dev.audiocompanion.transport.AudioGattLink
import dev.audiocompanion.transport.LinkState
import kotlinx.cinterop.BetaInteropApi
import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.allocArrayOf
import kotlinx.cinterop.convert
import kotlinx.cinterop.memScoped
import kotlinx.cinterop.ObjCSignatureOverride
import kotlinx.cinterop.usePinned
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.suspendCancellableCoroutine
import platform.CoreBluetooth.CBCentralManager
import platform.CoreBluetooth.CBCentralManagerDelegateProtocol
import platform.CoreBluetooth.CBCentralManagerOptionRestoreIdentifierKey
import platform.CoreBluetooth.CBCharacteristic
import platform.CoreBluetooth.CBCharacteristicWriteWithResponse
import platform.CoreBluetooth.CBManagerStatePoweredOff
import platform.CoreBluetooth.CBManagerStatePoweredOn
import platform.CoreBluetooth.CBManagerStateResetting
import platform.CoreBluetooth.CBManagerStateUnauthorized
import platform.CoreBluetooth.CBManagerStateUnsupported
import platform.CoreBluetooth.CBManagerStateUnknown
import platform.CoreBluetooth.CBPeripheral
import platform.CoreBluetooth.CBPeripheralDelegateProtocol
import platform.CoreBluetooth.CBService
import platform.CoreBluetooth.CBUUID
import platform.Foundation.NSData
import platform.Foundation.NSError
import platform.Foundation.NSLog
import platform.Foundation.NSNumber
import platform.Foundation.NSUserDefaults
import platform.Foundation.NSUUID
import platform.Foundation.create
import platform.darwin.dispatch_after
import platform.darwin.dispatch_async
import platform.darwin.dispatch_get_main_queue
import platform.darwin.dispatch_time
import platform.darwin.DISPATCH_TIME_NOW
import platform.darwin.NSObject
import platform.posix.memcpy
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

object IosAudioCompanionGatt {
    const val RESTORE_IDENTIFIER = "audio-companion-central"

    val PEBBLE_PAIRING_SERVICE_UUID: CBUUID = CBUUID.UUIDWithString("FED9")
    val DEVICE_INFORMATION_SERVICE_UUID: CBUUID = CBUUID.UUIDWithString("180A")
    val BATTERY_SERVICE_UUID: CBUUID = CBUUID.UUIDWithString("180F")
    val SERVICE_UUID: CBUUID = CBUUID.UUIDWithString(ProtocolConstants.SERVICE_UUID)
    val INFO_CHARACTERISTIC_UUID: CBUUID = CBUUID.UUIDWithString(ProtocolConstants.INFO_CHARACTERISTIC_UUID)
    val CONTROL_CHARACTERISTIC_UUID: CBUUID = CBUUID.UUIDWithString(ProtocolConstants.CONTROL_CHARACTERISTIC_UUID)
    val DATA_CHARACTERISTIC_UUID: CBUUID = CBUUID.UUIDWithString(ProtocolConstants.DATA_CHARACTERISTIC_UUID)
}

/**
 * Core Bluetooth implementation of [AudioGattLink] (plan 6.4).
 *
 * The app creates this at launch so Core Bluetooth can restore the central. It prefers joining
 * an existing system connection over scanning and keeps notification handling append-and-return
 * fast: no decode, no transcription, just forwarding whole protocol messages into flows.
 */
@OptIn(ExperimentalForeignApi::class, BetaInteropApi::class)
class IosAudioGattLink(
    private val defaults: NSUserDefaults = NSUserDefaults.standardUserDefaults,
) : AudioGattLink {
    private val _connectionState = MutableStateFlow(LinkState.Disconnected)
    override val connectionState: StateFlow<LinkState> = _connectionState.asStateFlow()
    private val _lastError = MutableStateFlow<String?>(null)
    override val lastError: StateFlow<String?> = _lastError.asStateFlow()

    // Bounded so an unconsumed link (receiver stopped, link still subscribed) cannot grow
    // memory without limit; at ~7 data notifications/s the data bound is ~10 minutes.
    private val controlChannel = Channel<ByteArray>(256, BufferOverflow.DROP_OLDEST)
    private val dataChannel = Channel<ByteArray>(4096, BufferOverflow.DROP_OLDEST)

    override val controlNotifications: Flow<ByteArray> = controlChannel.receiveAsFlow()
    override val dataNotifications: Flow<ByteArray> = dataChannel.receiveAsFlow()

    private var centralManager: CBCentralManager? = null
    private var peripheral: CBPeripheral? = null
    private var infoCharacteristic: CBCharacteristic? = null
    private var controlCharacteristic: CBCharacteristic? = null
    private var dataCharacteristic: CBCharacteristic? = null
    private var pendingInfoRead: kotlinx.coroutines.CancellableContinuation<ByteArray>? = null
    private var pendingControlWrite: kotlinx.coroutines.CancellableContinuation<Unit>? = null
    private var pendingNotifyCharacteristics: MutableList<CBCharacteristic> = mutableListOf()
    private val delegate = IosAudioGattDelegate(this)

    /**
     * Monotonic id for the in-flight connect/handshake attempt. Every transition into
     * [LinkState.Connecting] bumps it; a scheduled watchdog only fires if it is still the current
     * attempt when it wakes, which is how a `dispatch_after` timer is "cancelled" without holding a
     * timer handle. Reaching [LinkState.Ready] or [LinkState.Disconnected] also bumps it so any
     * outstanding timer becomes a no-op.
     */
    private var connectGeneration = 0

    /** Consecutive watchdog timeouts for the current connect sequence; reset once Ready. */
    private var connectAttempts = 0

    /**
     * NSLog so the live device log (Console.app / `idevicesyslog` / Xcode) shows every Core
     * Bluetooth transition with a stable, greppable tag. This is the only place the adapter logs;
     * it is cheap and stays out of the data hot path (notifications are not logged per-frame).
     */
    private fun log(message: String) {
        NSLog("$LOG_TAG state=${connectionState.value} gen=$connectGeneration attempt=$connectAttempts $message")
    }

    /**
     * Joins the existing system link when possible:
     * retrieveConnectedPeripherals(withServices:) -> connect(); otherwise a pending connect()
     * on the stored peripheral identifier. Scanning is a foreground-only onboarding fallback.
     */
    fun connect() = onMainQueue {
        // Single CBCentralManager for the process. connect() is invoked from several coroutine
        // threads at launch (didFinishLaunching + foreground observer + start); serializing the
        // body on the main (delegate) queue guarantees the manager is created exactly once. The
        // previous `centralManager ?: create()` ran on Dispatchers.Default and raced into TWO
        // managers sharing one delegate — the orphan then emitted a spurious Unsupported callback
        // and issued a connect that never completed, which is what stranded the link in
        // "Connecting" forever (or flashed a Bluetooth error).
        val manager = centralManager ?: CBCentralManager(
            delegate = delegate,
            queue = dispatch_get_main_queue(),
            options = mapOf(CBCentralManagerOptionRestoreIdentifierKey to IosAudioCompanionGatt.RESTORE_IDENTIFIER),
        ).also { centralManager = it }
        wantConnected = true
        log("connect() requested, manager.state=${manager.state}")
        // Idempotent: a live or in-progress link must not be bounced. connect() is called on every
        // app foreground/launch, so restarting it here would drop a working connection (and lose
        // audio) each time the app comes to the foreground.
        if (connectionState.value != LinkState.Disconnected) {
            log("connect() ignored; already ${connectionState.value}")
            return@onMainQueue
        }
        connectAttempts = 0
        enterConnecting("connect()")
        if (manager.state == CBManagerStatePoweredOn) {
            connectWhenPoweredOn(manager)
        }
    }

    /**
     * Runs [block] on the main (delegate) serial queue. All Core Bluetooth interaction and link
     * state mutation funnels through here so lifecycle calls from arbitrary coroutine threads are
     * serialized with the manager's delegate callbacks (which are already delivered on this queue).
     */
    private inline fun onMainQueue(crossinline block: () -> Unit) {
        dispatch_async(dispatch_get_main_queue()) { block() }
    }

    /** True while a user-initiated disconnect is in flight, so it is not reported as an error. */
    private var intentionalDisconnect = false

    /**
     * True between [connect] and [disconnect]: we should (re)establish the link whenever possible.
     * Lets an unexpected drop or a Bluetooth-off→on transition reconnect automatically, the way
     * Android's autoConnect/CDM presence does, instead of stranding the link Disconnected.
     */
    private var wantConnected = false

    override fun disconnect() = onMainQueue {
        log("disconnect() requested")
        wantConnected = false
        connectGeneration += 1 // invalidate any pending watchdog
        val manager = centralManager ?: return@onMainQueue
        manager.stopScan()
        val current = peripheral
        if (current != null) {
            intentionalDisconnect = true
            manager.cancelPeripheralConnection(current)
        } else {
            resetCharacteristics()
            _connectionState.value = LinkState.Disconnected
        }
    }

    /**
     * Forces a fresh GATT session without giving up the link: cancel this app's connection to the
     * peripheral and reconnect. On a shared ACL link (the official app is also connected) this
     * re-runs service discovery, CCCD subscription and AUTH without disturbing the other app — the
     * recovery for a half-dead connection CoreBluetooth still reports as connected.
     */
    override fun resync() = onMainQueue {
        log("resync() requested")
        val manager = centralManager
        if (manager == null) {
            connect()
            return@onMainQueue
        }
        wantConnected = true
        connectAttempts = 0
        manager.stopScan()
        val current = peripheral
        if (current != null) {
            // Not an intentional (user) disconnect: onPeripheralDisconnected re-issues the connect
            // because wantConnected stays true, so the link rebuilds itself.
            intentionalDisconnect = false
            enterConnecting("resync (cancel + reconnect)")
            manager.cancelPeripheralConnection(current)
        } else if (manager.state == CBManagerStatePoweredOn) {
            enterConnecting("resync (fresh)")
            connectWhenPoweredOn(manager)
        }
    }

    override suspend fun readInfo(): ByteArray {
        val localPeripheral = peripheral ?: throw IllegalStateException("Peripheral is not connected")
        val characteristic = infoCharacteristic ?: throw IllegalStateException("Info characteristic not ready")
        return suspendCancellableCoroutine { continuation ->
            check(pendingInfoRead == null) { "Info read already in flight" }
            pendingInfoRead = continuation
            continuation.invokeOnCancellation {
                if (pendingInfoRead === continuation) pendingInfoRead = null
            }
            localPeripheral.readValueForCharacteristic(characteristic)
        }
    }

    override suspend fun writeControl(message: ByteArray) {
        val localPeripheral = peripheral ?: throw IllegalStateException("Peripheral is not connected")
        val characteristic = controlCharacteristic ?: throw IllegalStateException("Control characteristic not ready")
        return suspendCancellableCoroutine { continuation ->
            check(pendingControlWrite == null) { "Control write already in flight" }
            pendingControlWrite = continuation
            continuation.invokeOnCancellation {
                if (pendingControlWrite === continuation) pendingControlWrite = null
            }
            localPeripheral.writeValue(message.toNSData(), characteristic, CBCharacteristicWriteWithResponse)
        }
    }

    internal fun onCentralStateChanged(central: CBCentralManager) {
        // Defense in depth: bind to the first manager we see and ignore any stray callback from a
        // different instance, so a transient/orphaned manager (e.g. a spurious Unsupported) cannot
        // tear down a healthy link.
        if (centralManager == null) centralManager = central
        if (central != centralManager) {
            log("ignoring state ${central.state} from non-current central")
            return
        }
        log("centralManagerDidUpdateState -> ${central.state}, wantConnected=$wantConnected")
        when (central.state) {
            CBManagerStatePoweredOn ->
                if (wantConnected && connectionState.value != LinkState.Ready) {
                    connectAttempts = 0
                    enterConnecting("Bluetooth powered on")
                    connectWhenPoweredOn(central)
                }
            // Surface an actionable reason instead of hanging in "Connecting". wantConnected is
            // kept set, so the link reconnects automatically once Bluetooth comes back.
            CBManagerStatePoweredOff ->
                if (wantConnected) failAndReset("Bluetooth is turned off")
            CBManagerStateUnauthorized ->
                if (wantConnected) failAndReset("Bluetooth access is off for this app. Turn it on in Settings.")
            CBManagerStateUnsupported ->
                if (wantConnected) failAndReset("Bluetooth is unavailable to this app right now.")
            CBManagerStateUnknown,
            CBManagerStateResetting ->
                if (wantConnected) {
                    // Core Bluetooth is still starting or briefly restarted its system service.
                    // Clear stale failures so the main status does not keep showing an old error.
                    enterConnecting("Bluetooth resetting/unknown")
                }
            else -> {}
        }
    }

    internal fun onCentralRestore(
        central: CBCentralManager,
        willRestoreState: Map<Any?, *>,
    ) {
        if (centralManager == null) centralManager = central
        if (central != centralManager) return
        @Suppress("UNCHECKED_CAST")
        val peripherals = willRestoreState["CBCentralManagerRestoredStatePeripheralsKey"] as? List<CBPeripheral>
        val restored = peripherals?.firstOrNull() ?: return
        log("willRestoreState restored peripheral ${restored.identifier.UUIDString} (${peripherals.size} total)")
        wantConnected = true
        peripheral = restored
        restored.delegate = delegate
        rememberPeripheral(restored)
        enterConnecting("restore")
        central.connectPeripheral(restored, options = null)
    }

    internal fun onPeripheralDiscovered(
        central: CBCentralManager,
        didDiscoverPeripheral: CBPeripheral,
        advertisementData: Map<Any?, *>,
        RSSI: NSNumber,
    ) {
        log("didDiscoverPeripheral ${didDiscoverPeripheral.name ?: "?"} rssi=$RSSI; connecting")
        central.stopScan()
        peripheral = didDiscoverPeripheral
        didDiscoverPeripheral.delegate = delegate
        rememberPeripheral(didDiscoverPeripheral)
        central.connectPeripheral(didDiscoverPeripheral, options = null)
    }

    internal fun onPeripheralConnected(
        central: CBCentralManager,
        didConnectPeripheral: CBPeripheral,
    ) {
        log("didConnectPeripheral ${didConnectPeripheral.name ?: "?"}; discovering services")
        // A successful connect clears any lingering watchdog-cancel flag (a cancelled *pending*
        // connect fires no disconnect callback to clear it), so a later real drop still reconnects.
        intentionalDisconnect = false
        peripheral = didConnectPeripheral
        didConnectPeripheral.delegate = delegate
        rememberPeripheral(didConnectPeripheral)
        enterConnecting("connected, discovering services")
        didConnectPeripheral.discoverServices(listOf(IosAudioCompanionGatt.SERVICE_UUID))
    }

    internal fun onPeripheralConnectFailed(
        central: CBCentralManager,
        didFailToConnectPeripheral: CBPeripheral,
        error: NSError?,
    ) {
        log("didFailToConnectPeripheral error=${error?.localizedDescription}")
        failAndReset(error?.localizedDescription ?: "Failed to connect")
    }

    internal fun onPeripheralDisconnected(
        central: CBCentralManager,
        didDisconnectPeripheral: CBPeripheral,
        error: NSError?,
    ) {
        log("didDisconnectPeripheral intentional=$intentionalDisconnect wantConnected=$wantConnected error=${error?.localizedDescription}")
        resetCharacteristics()
        if (intentionalDisconnect || !wantConnected) {
            intentionalDisconnect = false
            _lastError.value = null
            // A watchdog-driven cancel sets intentionalDisconnect to suppress this path; it re-drives
            // the connect itself, so leaving the state at Connecting (not Disconnected) here is
            // correct. Only a genuine user disconnect (wantConnected == false) settles to idle.
            if (!wantConnected) {
                connectGeneration += 1
                _connectionState.value = LinkState.Disconnected
                log("-> Disconnected (intentional)")
            }
            return
        }
        // Unexpected drop while we still want the link (watch out of range or reset). Re-issue a
        // pending connect: CoreBluetooth resolves it with no timeout when the watch returns, even
        // in the background, so the receiver reconnects on its own (the watch buffers the gap).
        // The watchdog still guards this re-issued connect so it cannot pend forever.
        enterConnecting("unexpected drop, reconnecting")
        central.connectPeripheral(didDisconnectPeripheral, options = null)
    }

    internal fun onServicesDiscovered(
        peripheral: CBPeripheral,
        didDiscoverServices: NSError?,
    ) {
        if (didDiscoverServices != null) {
            log("didDiscoverServices error=${didDiscoverServices.localizedDescription}")
            failAndReset(didDiscoverServices.localizedDescription)
            return
        }
        val service = peripheral.services?.filterIsInstance<CBService>()
            ?.firstOrNull { it.UUID == IosAudioCompanionGatt.SERVICE_UUID }
        if (service == null) {
            val found = peripheral.services?.filterIsInstance<CBService>()?.map { it.UUID.UUIDString }
            log("didDiscoverServices: companion service missing; found=$found")
            failAndReset("Audio Companion service not found")
            return
        }
        log("didDiscoverServices ok; discovering characteristics")
        peripheral.discoverCharacteristics(
            listOf(
                IosAudioCompanionGatt.INFO_CHARACTERISTIC_UUID,
                IosAudioCompanionGatt.CONTROL_CHARACTERISTIC_UUID,
                IosAudioCompanionGatt.DATA_CHARACTERISTIC_UUID,
            ),
            forService = service,
        )
    }

    internal fun onCharacteristicsDiscovered(
        peripheral: CBPeripheral,
        didDiscoverCharacteristicsForService: CBService,
        error: NSError?,
    ) {
        if (error != null) {
            log("didDiscoverCharacteristics error=${error.localizedDescription}")
            failAndReset(error.localizedDescription)
            return
        }
        val characteristics = didDiscoverCharacteristicsForService.characteristics
            ?.filterIsInstance<CBCharacteristic>()
            .orEmpty()
        infoCharacteristic = characteristics.firstOrNull { it.UUID == IosAudioCompanionGatt.INFO_CHARACTERISTIC_UUID }
        controlCharacteristic = characteristics.firstOrNull {
            it.UUID == IosAudioCompanionGatt.CONTROL_CHARACTERISTIC_UUID
        }
        dataCharacteristic = characteristics.firstOrNull { it.UUID == IosAudioCompanionGatt.DATA_CHARACTERISTIC_UUID }
        val control = controlCharacteristic
        val data = dataCharacteristic
        if (infoCharacteristic == null || control == null || data == null) {
            log("didDiscoverCharacteristics: missing one of info/control/data")
            failAndReset("Audio Companion characteristics not found")
            return
        }
        log("didDiscoverCharacteristics ok; subscribing notifications")
        pendingNotifyCharacteristics = mutableListOf(control, data)
        // Keep arming the watchdog: CCCD subscription is the last handshake step that can stall.
        enterConnecting("subscribing notifications")
        peripheral.setNotifyValue(true, forCharacteristic = pendingNotifyCharacteristics.removeAt(0))
    }

    internal fun onNotificationStateUpdated(
        peripheral: CBPeripheral,
        didUpdateNotificationStateForCharacteristic: CBCharacteristic,
        error: NSError?,
    ) {
        if (error != null) {
            log("didUpdateNotificationState error=${error.localizedDescription}")
            failAndReset(error.localizedDescription)
            return
        }
        if (pendingNotifyCharacteristics.isEmpty()) {
            reachReady()
        } else {
            peripheral.setNotifyValue(true, forCharacteristic = pendingNotifyCharacteristics.removeAt(0))
        }
    }

    internal fun onCharacteristicValueUpdated(
        peripheral: CBPeripheral,
        didUpdateValueForCharacteristic: CBCharacteristic,
        error: NSError?,
    ) {
        val value = didUpdateValueForCharacteristic.value?.toByteArray() ?: ByteArray(0)
        when (didUpdateValueForCharacteristic.UUID) {
            IosAudioCompanionGatt.INFO_CHARACTERISTIC_UUID -> {
                val continuation = pendingInfoRead ?: return
                pendingInfoRead = null
                if (error == null) {
                    continuation.resume(value)
                } else {
                    continuation.resumeWithException(IllegalStateException(error.localizedDescription))
                }
            }
            IosAudioCompanionGatt.CONTROL_CHARACTERISTIC_UUID -> if (error == null) controlChannel.trySend(value)
            IosAudioCompanionGatt.DATA_CHARACTERISTIC_UUID -> if (error == null) dataChannel.trySend(value)
        }
    }

    internal fun onCharacteristicWriteCompleted(
        peripheral: CBPeripheral,
        didWriteValueForCharacteristic: CBCharacteristic,
        error: NSError?,
    ) {
        if (didWriteValueForCharacteristic.UUID != IosAudioCompanionGatt.CONTROL_CHARACTERISTIC_UUID) return
        val continuation = pendingControlWrite ?: return
        pendingControlWrite = null
        if (error == null) {
            continuation.resume(Unit)
        } else {
            continuation.resumeWithException(IllegalStateException(error.localizedDescription))
        }
    }

    private fun connectWhenPoweredOn(manager: CBCentralManager) {
        // Prefer a peripheral CoreBluetooth reports as *currently connected* (system already holds
        // the ACL, e.g. the official Pebble app is connected) over a stored identifier. A stored
        // identifier resolves to a CBPeripheral even when the watch is unreachable, and connecting
        // to it pends forever with no error — the most likely cause of a stuck "Connecting".
        val connected = connectedPeripherals(
            manager,
            listOf(
                IosAudioCompanionGatt.SERVICE_UUID,
                IosAudioCompanionGatt.PEBBLE_PAIRING_SERVICE_UUID,
            ),
        )
        val existing = connected.firstOrNull { it.isLikelyPebble() } ?: connected.firstOrNull()
        if (existing != null) {
            log("connectWhenPoweredOn: using currently-connected peripheral ${existing.name ?: existing.identifier.UUIDString}")
            connectPeripheral(manager, existing)
            return
        }

        restoredPeripheral(manager)?.let { stored ->
            log("connectWhenPoweredOn: using stored peripheral ${stored.identifier.UUIDString}")
            connectPeripheral(manager, stored)
            return
        }

        // Device Information and Battery are too generic to pick blindly: AirPods, keyboards, and
        // other nearby devices may expose them. Use them only when iOS gives us a Pebble-looking
        // name, otherwise fall back to the explicit foreground scan below.
        val namedPebble = connectedPeripherals(
            manager,
            listOf(
                IosAudioCompanionGatt.DEVICE_INFORMATION_SERVICE_UUID,
                IosAudioCompanionGatt.BATTERY_SERVICE_UUID,
            ),
        ).firstOrNull { it.isLikelyPebble() }
        if (namedPebble != null) {
            log("connectWhenPoweredOn: using named Pebble ${namedPebble.name}")
            connectPeripheral(manager, namedPebble)
        } else {
            log("connectWhenPoweredOn: no known peripheral; scanning")
            manager.scanForPeripheralsWithServices(
                listOf(
                    IosAudioCompanionGatt.SERVICE_UUID,
                    IosAudioCompanionGatt.PEBBLE_PAIRING_SERVICE_UUID,
                ),
                options = null,
            )
        }
    }

    private fun connectedPeripherals(
        manager: CBCentralManager,
        serviceUuids: List<CBUUID>,
    ): List<CBPeripheral> = serviceUuids.flatMap { serviceUuid ->
        manager.retrieveConnectedPeripheralsWithServices(listOf(serviceUuid))
            .filterIsInstance<CBPeripheral>()
    }.distinctBy { it.identifier.UUIDString }

    private fun restoredPeripheral(manager: CBCentralManager): CBPeripheral? {
        val uuidString = defaults.stringForKey(KEY_PERIPHERAL_IDENTIFIER) ?: return null
        val uuid = NSUUID(uUIDString = uuidString)
        return manager.retrievePeripheralsWithIdentifiers(listOf<NSUUID>(uuid))
            .filterIsInstance<CBPeripheral>()
            .firstOrNull()
    }

    private fun connectPeripheral(manager: CBCentralManager, target: CBPeripheral) {
        peripheral = target
        target.delegate = delegate
        rememberPeripheral(target)
        manager.connectPeripheral(target, options = null)
    }

    private fun rememberPeripheral(target: CBPeripheral) {
        defaults.setObject(target.identifier.UUIDString, forKey = KEY_PERIPHERAL_IDENTIFIER)
    }

    private fun CBPeripheral.isLikelyPebble(): Boolean =
        name?.contains("Pebble", ignoreCase = true) == true

    /**
     * Moves into [LinkState.Connecting] and (re)arms the handshake watchdog. Every step that keeps
     * us mid-handshake (issuing a connect, a discovery callback, a CCCD subscription) calls this so
     * the watchdog window restarts on real progress and only fires when a step truly stalls.
     */
    private fun enterConnecting(reason: String) {
        _lastError.value = null
        connectGeneration += 1
        _connectionState.value = LinkState.Connecting
        log("-> Connecting ($reason)")
        armWatchdog(connectGeneration)
    }

    /** Reached the fully-subscribed, usable link. Cancels the watchdog and resets retry counters. */
    private fun reachReady() {
        connectGeneration += 1 // invalidate any pending watchdog
        connectAttempts = 0
        _lastError.value = null
        _connectionState.value = LinkState.Ready
        log("-> Ready")
    }

    /**
     * Schedules a one-shot timeout for [generation]. `dispatch_after` cannot be cancelled, so the
     * block re-checks that its generation is still current and we are still Connecting before
     * acting; a completed/superseded attempt makes it a no-op. Runs on the main (delegate) queue,
     * so it is serialized with every Core Bluetooth callback.
     */
    private fun armWatchdog(generation: Int) {
        val nanos = CONNECT_WATCHDOG_MS * 1_000_000L
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, nanos), dispatch_get_main_queue()) {
            if (generation == connectGeneration && connectionState.value == LinkState.Connecting) {
                onConnectTimeout()
            }
        }
    }

    /**
     * The connect/handshake stalled (classic Core Bluetooth trap: `connect()` has no timeout and a
     * stale or unreachable peripheral handle pends forever with no error). Tear the stalled attempt
     * down and re-evaluate the connect path from scratch; after [CONNECT_MAX_ATTEMPTS] surface an
     * actionable failure so the UI leaves "Connecting" and the user gets a retry affordance instead
     * of an indefinite spinner.
     */
    private fun onConnectTimeout() {
        val manager = centralManager ?: return
        // Bluetooth not ready yet (still powering on / resetting): this isn't a stalled connect, so
        // don't burn a retry. onCentralStateChanged drives the real attempt once it powers on; just
        // re-arm so we keep watching.
        if (manager.state != CBManagerStatePoweredOn) {
            log("watchdog: Bluetooth not powered on (state=${manager.state}); re-arming")
            armWatchdog(connectGeneration)
            return
        }
        connectAttempts += 1
        log("watchdog timeout after ${CONNECT_WATCHDOG_MS}ms")
        manager.stopScan()
        // Cancel the stalled attempt. For a pending (never-connected) connect this fires no
        // delegate callback; for a connected-but-stuck-in-discovery peripheral it triggers a
        // disconnect we intentionally swallow here, since we re-drive the connect ourselves.
        peripheral?.let {
            intentionalDisconnect = true
            manager.cancelPeripheralConnection(it)
        }
        peripheral = null
        resetCharacteristics()
        if (connectAttempts >= CONNECT_MAX_ATTEMPTS) {
            log("giving up after $connectAttempts attempts")
            failAndReset("Couldn't reach your Pebble. Make sure it's nearby, then try again.")
            return
        }
        if (manager.state == CBManagerStatePoweredOn) {
            enterConnecting("watchdog retry $connectAttempts")
            connectWhenPoweredOn(manager)
        }
    }

    private fun failAndReset(message: String) {
        connectGeneration += 1 // invalidate any pending watchdog
        pendingInfoRead?.resumeWithException(IllegalStateException(message))
        pendingInfoRead = null
        pendingControlWrite?.resumeWithException(IllegalStateException(message))
        pendingControlWrite = null
        centralManager?.stopScan()
        resetCharacteristics()
        _lastError.value = message
        _connectionState.value = LinkState.Disconnected
        log("-> Disconnected (error: $message)")
    }

    private fun resetCharacteristics() {
        infoCharacteristic = null
        controlCharacteristic = null
        dataCharacteristic = null
        pendingNotifyCharacteristics.clear()
    }

    private fun NSData.toByteArray(): ByteArray = ByteArray(length.toInt()).apply {
        if (length > 0u) {
            usePinned {
                memcpy(it.addressOf(0), bytes, length)
            }
        }
    }

    private fun ByteArray.toNSData(): NSData = memScoped {
        NSData.create(
            bytes = allocArrayOf(this@toNSData),
            length = size.convert(),
        )
    }

    private companion object {
        const val KEY_PERIPHERAL_IDENTIFIER = "ios_audio_companion_peripheral_identifier"

        /** Stable, greppable prefix for the live device log. */
        const val LOG_TAG = "[AudioGattLink]"

        /**
         * How long a single connect/handshake step may stall before the watchdog re-drives it.
         * CoreBluetooth `connect()` itself never times out, so this is the only bound on a pended
         * connection. Sized to comfortably cover a healthy connect + discovery + CCCD round trip
         * to a Pebble (a few seconds) without making a genuine stall feel indefinite.
         */
        const val CONNECT_WATCHDOG_MS = 10_000L

        /** Consecutive stalls before we stop retrying and surface an actionable error. */
        const val CONNECT_MAX_ATTEMPTS = 3
    }
}

private class IosAudioGattDelegate(
    private val owner: IosAudioGattLink,
) : NSObject(), CBCentralManagerDelegateProtocol, CBPeripheralDelegateProtocol {

    override fun centralManagerDidUpdateState(central: CBCentralManager) {
        owner.onCentralStateChanged(central)
    }

    override fun centralManager(
        central: CBCentralManager,
        willRestoreState: Map<Any?, *>,
    ) {
        owner.onCentralRestore(central, willRestoreState)
    }

    override fun centralManager(
        central: CBCentralManager,
        didDiscoverPeripheral: CBPeripheral,
        advertisementData: Map<Any?, *>,
        RSSI: NSNumber,
    ) {
        owner.onPeripheralDiscovered(central, didDiscoverPeripheral, advertisementData, RSSI)
    }

    override fun centralManager(
        central: CBCentralManager,
        didConnectPeripheral: CBPeripheral,
    ) {
        owner.onPeripheralConnected(central, didConnectPeripheral)
    }

    @ObjCSignatureOverride
    override fun centralManager(
        central: CBCentralManager,
        didFailToConnectPeripheral: CBPeripheral,
        error: NSError?,
    ) {
        owner.onPeripheralConnectFailed(central, didFailToConnectPeripheral, error)
    }

    @ObjCSignatureOverride
    override fun centralManager(
        central: CBCentralManager,
        didDisconnectPeripheral: CBPeripheral,
        error: NSError?,
    ) {
        owner.onPeripheralDisconnected(central, didDisconnectPeripheral, error)
    }

    override fun peripheral(
        peripheral: CBPeripheral,
        didDiscoverServices: NSError?,
    ) {
        owner.onServicesDiscovered(peripheral, didDiscoverServices)
    }

    override fun peripheral(
        peripheral: CBPeripheral,
        didDiscoverCharacteristicsForService: CBService,
        error: NSError?,
    ) {
        owner.onCharacteristicsDiscovered(peripheral, didDiscoverCharacteristicsForService, error)
    }

    @ObjCSignatureOverride
    override fun peripheral(
        peripheral: CBPeripheral,
        didUpdateNotificationStateForCharacteristic: CBCharacteristic,
        error: NSError?,
    ) {
        owner.onNotificationStateUpdated(peripheral, didUpdateNotificationStateForCharacteristic, error)
    }

    @ObjCSignatureOverride
    override fun peripheral(
        peripheral: CBPeripheral,
        didUpdateValueForCharacteristic: CBCharacteristic,
        error: NSError?,
    ) {
        owner.onCharacteristicValueUpdated(peripheral, didUpdateValueForCharacteristic, error)
    }

    @ObjCSignatureOverride
    override fun peripheral(
        peripheral: CBPeripheral,
        didWriteValueForCharacteristic: CBCharacteristic,
        error: NSError?,
    ) {
        owner.onCharacteristicWriteCompleted(peripheral, didWriteValueForCharacteristic, error)
    }
}
