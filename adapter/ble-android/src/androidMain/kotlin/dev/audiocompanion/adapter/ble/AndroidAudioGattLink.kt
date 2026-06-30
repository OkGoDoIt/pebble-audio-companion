package dev.audiocompanion.adapter.ble

import android.annotation.SuppressLint
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.content.Context
import android.os.Build
import dev.audiocompanion.protocol.ProtocolConstants
import dev.audiocompanion.transport.AudioGattLink
import dev.audiocompanion.transport.LinkState
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.suspendCancellableCoroutine
import java.util.UUID
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * Android GATT client implementation of [AudioGattLink] (plan 6.3).
 *
 * The app layer owns Companion Device Manager association and foreground-service lifetime. This
 * class owns only the watch-hosted Audio Companion GATT session: LE reconnect, MTU negotiation,
 * service/characteristic resolution, CCCD subscription, encrypted Info reads, and encrypted
 * Control writes.
 */
@SuppressLint("MissingPermission") // BLUETOOTH_CONNECT is requested by the app layer before use
class AndroidAudioGattLink(
    private val context: Context,
) : AudioGattLink {

    companion object {
        val SERVICE_UUID: UUID = UUID.fromString(ProtocolConstants.SERVICE_UUID)
        val INFO_CHARACTERISTIC_UUID: UUID = UUID.fromString(ProtocolConstants.INFO_CHARACTERISTIC_UUID)
        val CONTROL_CHARACTERISTIC_UUID: UUID = UUID.fromString(ProtocolConstants.CONTROL_CHARACTERISTIC_UUID)
        val DATA_CHARACTERISTIC_UUID: UUID = UUID.fromString(ProtocolConstants.DATA_CHARACTERISTIC_UUID)

        /** Client Characteristic Configuration Descriptor. */
        val CCCD_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

        /** Request the max; effective MTU = min(with watch's 256). */
        const val REQUESTED_MTU = 517
    }

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

    private var gatt: BluetoothGatt? = null
    private var connectedDeviceAddress: String? = null
    private var lastDevice: BluetoothDevice? = null
    private var infoCharacteristic: BluetoothGattCharacteristic? = null
    private var controlCharacteristic: BluetoothGattCharacteristic? = null
    private var dataCharacteristic: BluetoothGattCharacteristic? = null

    private val lock = Any()
    private var pendingInfoRead: kotlinx.coroutines.CancellableContinuation<ByteArray>? = null
    private var pendingControlWrite: kotlinx.coroutines.CancellableContinuation<Unit>? = null
    private var pendingCccdQueue: ArrayDeque<BluetoothGattCharacteristic> = ArrayDeque()

    /**
     * Connects with autoConnect=true (free reconnect-on-radio-contact, no scans) over LE
     * transport, then discovers [SERVICE_UUID] and subscribes Control + Data.
     */
    fun connect(device: BluetoothDevice) {
        // Idempotent: connect() is sent on every app open and CDM presence event. If we already
        // have a GATT client for this device (connected, or autoConnect-reconnecting), don't
        // bounce it — restarting would drop a working link and lose audio.
        if (gatt != null && device.address == connectedDeviceAddress) {
            return
        }
        disconnect()
        lastDevice = device
        connectedDeviceAddress = device.address
        _lastError.value = null
        _connectionState.value = LinkState.Connecting
        gatt = device.connectGatt(context, true, callback, BluetoothDevice.TRANSPORT_LE)
    }

    override fun disconnect() {
        disconnectWithError(null)
    }

    /**
     * Forces a fresh GATT client for the last device: close the current (possibly stale)
     * connection and reconnect (autoConnect resumes on radio contact). The receiver session calls
     * this when keepalive pings go unanswered.
     */
    override fun resync() {
        val device = lastDevice ?: return
        disconnect() // closes the current client and clears gatt so connect() rebuilds it
        connect(device)
    }

    private fun disconnectWithError(message: String?) {
        val oldGatt = gatt
        gatt = null
        connectedDeviceAddress = null
        infoCharacteristic = null
        controlCharacteristic = null
        dataCharacteristic = null
        synchronized(lock) {
            pendingCccdQueue.clear()
            pendingInfoRead?.resumeWithException(IllegalStateException("GATT disconnected"))
            pendingInfoRead = null
            pendingControlWrite?.resumeWithException(IllegalStateException("GATT disconnected"))
            pendingControlWrite = null
        }
        oldGatt?.disconnect()
        oldGatt?.close()
        _lastError.value = message
        _connectionState.value = LinkState.Disconnected
    }

    override suspend fun readInfo(): ByteArray {
        val localGatt = gatt ?: throw IllegalStateException("GATT is not connected")
        val characteristic = infoCharacteristic ?: throw IllegalStateException("Info characteristic not ready")
        return suspendCancellableCoroutine { continuation ->
            synchronized(lock) {
                check(pendingInfoRead == null) { "Info read already in flight" }
                pendingInfoRead = continuation
            }
            continuation.invokeOnCancellation {
                synchronized(lock) {
                    if (pendingInfoRead === continuation) pendingInfoRead = null
                }
            }
            if (!localGatt.readCharacteristic(characteristic)) {
                synchronized(lock) {
                    if (pendingInfoRead === continuation) pendingInfoRead = null
                }
                continuation.resumeWithException(IllegalStateException("Failed to start Info read"))
            }
        }
    }

    override suspend fun writeControl(message: ByteArray) {
        val localGatt = gatt ?: throw IllegalStateException("GATT is not connected")
        val characteristic = controlCharacteristic ?: throw IllegalStateException("Control characteristic not ready")
        return suspendCancellableCoroutine { continuation ->
            synchronized(lock) {
                check(pendingControlWrite == null) { "Control write already in flight" }
                pendingControlWrite = continuation
            }
            continuation.invokeOnCancellation {
                synchronized(lock) {
                    if (pendingControlWrite === continuation) pendingControlWrite = null
                }
            }
            characteristic.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
            val started = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                localGatt.writeCharacteristic(
                    characteristic,
                    message,
                    BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT,
                ) == BluetoothStatusCodes.SUCCESS
            } else {
                @Suppress("DEPRECATION")
                characteristic.value = message
                @Suppress("DEPRECATION")
                localGatt.writeCharacteristic(characteristic)
            }
            if (!started) {
                synchronized(lock) {
                    if (pendingControlWrite === continuation) pendingControlWrite = null
                }
                continuation.resumeWithException(IllegalStateException("Failed to start Control write"))
            }
        }
    }

    private val callback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                disconnectWithError("Bluetooth connection failed with status $status")
                return
            }
            when (newState) {
                BluetoothProfile.STATE_CONNECTED -> {
                    _connectionState.value = LinkState.Connecting
                    if (!gatt.requestMtu(REQUESTED_MTU)) {
                        gatt.discoverServices()
                    }
                }
                BluetoothProfile.STATE_DISCONNECTED ->
                    disconnectWithError("Bluetooth peripheral disconnected")
            }
        }

        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
            gatt.discoverServices()
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                disconnectWithError("Bluetooth service discovery failed: $status")
                return
            }
            val service = gatt.getService(SERVICE_UUID)
            val info = service?.getCharacteristic(INFO_CHARACTERISTIC_UUID)
            val control = service?.getCharacteristic(CONTROL_CHARACTERISTIC_UUID)
            val data = service?.getCharacteristic(DATA_CHARACTERISTIC_UUID)
            if (service == null || info == null || control == null || data == null) {
                disconnectWithError("Audio Companion service or characteristics not found")
                return
            }

            infoCharacteristic = info
            controlCharacteristic = control
            dataCharacteristic = data
            synchronized(lock) {
                pendingCccdQueue = ArrayDeque(listOf(control, data))
            }
            writeNextCccd(gatt)
        }

        override fun onDescriptorWrite(
            gatt: BluetoothGatt,
            descriptor: BluetoothGattDescriptor,
            status: Int,
        ) {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                disconnectWithError("Notification subscription failed: $status")
                return
            }
            writeNextCccd(gatt)
        }

        @Deprecated("Android < 13 callback")
        override fun onCharacteristicRead(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int,
        ) {
            @Suppress("DEPRECATION")
            onInfoRead(characteristic, characteristic.value, status)
        }

        override fun onCharacteristicRead(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
            status: Int,
        ) {
            onInfoRead(characteristic, value, status)
        }

        override fun onCharacteristicWrite(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int,
        ) {
            if (characteristic.uuid != CONTROL_CHARACTERISTIC_UUID) return
            val continuation = synchronized(lock) {
                pendingControlWrite.also { pendingControlWrite = null }
            } ?: return
            if (status == BluetoothGatt.GATT_SUCCESS) {
                continuation.resume(Unit)
            } else {
                continuation.resumeWithException(IllegalStateException("Control write failed: $status"))
            }
        }

        @Deprecated("Android < 13 callback")
        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
        ) {
            @Suppress("DEPRECATION")
            onNotification(characteristic, characteristic.value)
        }

        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
        ) {
            onNotification(characteristic, value)
        }
    }

    private fun writeNextCccd(gatt: BluetoothGatt) {
        val characteristic = synchronized(lock) { pendingCccdQueue.removeFirstOrNull() }
        if (characteristic == null) {
            _connectionState.value = LinkState.Ready
            return
        }
        if (!gatt.setCharacteristicNotification(characteristic, true)) {
            disconnectWithError("Failed to enable local notifications")
            return
        }
        val descriptor = characteristic.getDescriptor(CCCD_UUID)
        if (descriptor == null) {
            disconnectWithError("Bluetooth notification descriptor not found")
            return
        }
        val started = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            gatt.writeDescriptor(
                descriptor,
                BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE,
            ) == BluetoothStatusCodes.SUCCESS
        } else {
            @Suppress("DEPRECATION")
            descriptor.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
            @Suppress("DEPRECATION")
            gatt.writeDescriptor(descriptor)
        }
        if (!started) {
            disconnectWithError("Failed to write CCCD")
        }
    }

    private fun onInfoRead(
        characteristic: BluetoothGattCharacteristic,
        value: ByteArray,
        status: Int,
    ) {
        if (characteristic.uuid != INFO_CHARACTERISTIC_UUID) return
        val continuation = synchronized(lock) {
            pendingInfoRead.also { pendingInfoRead = null }
        } ?: return
        if (status == BluetoothGatt.GATT_SUCCESS) {
            continuation.resume(value.copyOf())
        } else {
            continuation.resumeWithException(IllegalStateException("Info read failed: $status"))
        }
    }

    private fun onNotification(
        characteristic: BluetoothGattCharacteristic,
        value: ByteArray,
    ) {
            // Every notification is exactly one protocol message (spec Section 1).
            when (characteristic.uuid) {
                CONTROL_CHARACTERISTIC_UUID -> controlChannel.trySend(value.copyOf())
                DATA_CHARACTERISTIC_UUID -> dataChannel.trySend(value.copyOf())
            }
    }
}
