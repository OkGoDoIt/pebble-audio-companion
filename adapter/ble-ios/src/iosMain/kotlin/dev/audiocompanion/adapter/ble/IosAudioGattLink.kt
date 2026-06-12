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
import platform.CoreBluetooth.CBManagerStatePoweredOn
import platform.CoreBluetooth.CBPeripheral
import platform.CoreBluetooth.CBPeripheralDelegateProtocol
import platform.CoreBluetooth.CBService
import platform.CoreBluetooth.CBUUID
import platform.Foundation.NSData
import platform.Foundation.NSError
import platform.Foundation.NSNumber
import platform.Foundation.create
import platform.darwin.dispatch_get_main_queue
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
class IosAudioGattLink : AudioGattLink {
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
     * Joins the existing system link when possible:
     * retrieveConnectedPeripherals(withServices:) -> connect(); otherwise a pending connect()
     * on the stored peripheral identifier. Scanning is a foreground-only onboarding fallback.
     */
    fun connect() {
        val manager = centralManager ?: CBCentralManager(
            delegate = delegate,
            queue = dispatch_get_main_queue(),
            options = mapOf(CBCentralManagerOptionRestoreIdentifierKey to IosAudioCompanionGatt.RESTORE_IDENTIFIER),
        ).also { centralManager = it }
        _lastError.value = null
        _connectionState.value = LinkState.Connecting
        if (manager.state == CBManagerStatePoweredOn) {
            connectWhenPoweredOn(manager)
        }
    }

    /** True while a user-initiated disconnect is in flight, so it is not reported as an error. */
    private var intentionalDisconnect = false

    override fun disconnect() {
        val manager = centralManager ?: return
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
        if (central.state == CBManagerStatePoweredOn && connectionState.value == LinkState.Connecting) {
            connectWhenPoweredOn(central)
        }
    }

    internal fun onCentralRestore(
        central: CBCentralManager,
        willRestoreState: Map<Any?, *>,
    ) {
        @Suppress("UNCHECKED_CAST")
        val peripherals = willRestoreState["CBCentralManagerRestoredStatePeripheralsKey"] as? List<CBPeripheral>
        val restored = peripherals?.firstOrNull() ?: return
        peripheral = restored
        restored.delegate = delegate
        _connectionState.value = LinkState.Connecting
        central.connectPeripheral(restored, options = null)
    }

    internal fun onPeripheralDiscovered(
        central: CBCentralManager,
        didDiscoverPeripheral: CBPeripheral,
        advertisementData: Map<Any?, *>,
        RSSI: NSNumber,
    ) {
        central.stopScan()
        peripheral = didDiscoverPeripheral
        didDiscoverPeripheral.delegate = delegate
        central.connectPeripheral(didDiscoverPeripheral, options = null)
    }

    internal fun onPeripheralConnected(
        central: CBCentralManager,
        didConnectPeripheral: CBPeripheral,
    ) {
        peripheral = didConnectPeripheral
        didConnectPeripheral.delegate = delegate
        _connectionState.value = LinkState.Connecting
        didConnectPeripheral.discoverServices(listOf(IosAudioCompanionGatt.SERVICE_UUID))
    }

    internal fun onPeripheralConnectFailed(
        central: CBCentralManager,
        didFailToConnectPeripheral: CBPeripheral,
        error: NSError?,
    ) {
        failAndReset(error?.localizedDescription ?: "Failed to connect")
    }

    internal fun onPeripheralDisconnected(
        central: CBCentralManager,
        didDisconnectPeripheral: CBPeripheral,
        error: NSError?,
    ) {
        resetCharacteristics()
        _lastError.value = if (intentionalDisconnect) {
            null
        } else {
            error?.localizedDescription ?: "Peripheral disconnected"
        }
        intentionalDisconnect = false
        _connectionState.value = LinkState.Disconnected
    }

    internal fun onServicesDiscovered(
        peripheral: CBPeripheral,
        didDiscoverServices: NSError?,
    ) {
        if (didDiscoverServices != null) {
            failAndReset(didDiscoverServices.localizedDescription)
            return
        }
        val service = peripheral.services?.filterIsInstance<CBService>()
            ?.firstOrNull { it.UUID == IosAudioCompanionGatt.SERVICE_UUID }
        if (service == null) {
            failAndReset("Audio Companion service not found")
            return
        }
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
            failAndReset("Audio Companion characteristics not found")
            return
        }
        pendingNotifyCharacteristics = mutableListOf(control, data)
        _lastError.value = null
        peripheral.setNotifyValue(true, forCharacteristic = pendingNotifyCharacteristics.removeAt(0))
    }

    internal fun onNotificationStateUpdated(
        peripheral: CBPeripheral,
        didUpdateNotificationStateForCharacteristic: CBCharacteristic,
        error: NSError?,
    ) {
        if (error != null) {
            failAndReset(error.localizedDescription)
            return
        }
        if (pendingNotifyCharacteristics.isEmpty()) {
            _lastError.value = null
            _connectionState.value = LinkState.Ready
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
        val connected = listOf(
            IosAudioCompanionGatt.SERVICE_UUID,
            IosAudioCompanionGatt.PEBBLE_PAIRING_SERVICE_UUID,
            IosAudioCompanionGatt.DEVICE_INFORMATION_SERVICE_UUID,
            IosAudioCompanionGatt.BATTERY_SERVICE_UUID,
        ).flatMap { serviceUuid ->
            manager.retrieveConnectedPeripheralsWithServices(listOf(serviceUuid))
                .filterIsInstance<CBPeripheral>()
        }
            .distinctBy { it.identifier.UUIDString }
        val existing = connected.firstOrNull { it.name?.contains("Pebble", ignoreCase = true) == true }
            ?: connected.firstOrNull()
        if (existing != null) {
            peripheral = existing
            existing.delegate = delegate
            manager.connectPeripheral(existing, options = null)
        } else {
            manager.scanForPeripheralsWithServices(
                listOf(
                    IosAudioCompanionGatt.SERVICE_UUID,
                    IosAudioCompanionGatt.PEBBLE_PAIRING_SERVICE_UUID,
                ),
                options = null,
            )
        }
    }

    private fun failAndReset(message: String) {
        pendingInfoRead?.resumeWithException(IllegalStateException(message))
        pendingInfoRead = null
        pendingControlWrite?.resumeWithException(IllegalStateException(message))
        pendingControlWrite = null
        centralManager?.stopScan()
        resetCharacteristics()
        _lastError.value = message
        _connectionState.value = LinkState.Disconnected
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
