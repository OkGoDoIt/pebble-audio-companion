package dev.audiocompanion.adapter.ble

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothProfile
import android.content.Context
import dev.audiocompanion.protocol.ProtocolConstants
import dev.audiocompanion.transport.AudioGattLink
import dev.audiocompanion.transport.LinkState
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.receiveAsFlow
import java.util.UUID

/**
 * Android GATT client implementation of [AudioGattLink] (plan 6.3).
 *
 * Skeleton only for now: structure, UUIDs, and notification routing are in place; connection
 * management (CDM association, CompanionDeviceService presence, foreground service,
 * autoConnect/MTU/CCCD handling) lands with the adapter milestone.
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

    private val controlChannel = Channel<ByteArray>(Channel.UNLIMITED)
    private val dataChannel = Channel<ByteArray>(Channel.UNLIMITED)

    override val controlNotifications: Flow<ByteArray> = controlChannel.receiveAsFlow()
    override val dataNotifications: Flow<ByteArray> = dataChannel.receiveAsFlow()

    private var gatt: BluetoothGatt? = null

    /**
     * Connects with autoConnect=true (free reconnect-on-radio-contact, no scans) over LE
     * transport, then discovers [SERVICE_UUID] and subscribes Control + Data.
     */
    fun connect(device: BluetoothDevice) {
        _connectionState.value = LinkState.Connecting
        // TODO(adapter): device.connectGatt(context, /* autoConnect = */ true, callback,
        //  BluetoothDevice.TRANSPORT_LE); requestMtu(REQUESTED_MTU); discoverServices();
        //  write CCCDs for Control and Data; then publish LinkState.Ready.
        TODO("GATT connection management is implemented in the adapter milestone")
    }

    fun disconnect() {
        gatt?.close()
        gatt = null
        _connectionState.value = LinkState.Disconnected
    }

    override suspend fun readInfo(): ByteArray {
        // TODO(adapter): readCharacteristic(INFO_CHARACTERISTIC_UUID) bridged to a suspend
        //  call via onCharacteristicRead (encrypted link required by the watch).
        TODO("Info reads are implemented in the adapter milestone")
    }

    override suspend fun writeControl(message: ByteArray) {
        // TODO(adapter): writeCharacteristic(CONTROL_CHARACTERISTIC_UUID, message,
        //  WRITE_TYPE_DEFAULT) bridged to a suspend call via onCharacteristicWrite.
        TODO("Control writes are implemented in the adapter milestone")
    }

    private val callback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            when (newState) {
                BluetoothProfile.STATE_CONNECTED -> {
                    // TODO(adapter): requestMtu + discoverServices before Ready.
                }
                BluetoothProfile.STATE_DISCONNECTED ->
                    _connectionState.value = LinkState.Disconnected
            }
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            // TODO(adapter): resolve characteristics, enable notifications (CCCD writes),
            //  then _connectionState.value = LinkState.Ready.
        }

        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
        ) {
            // Every notification is exactly one protocol message (spec Section 1).
            when (characteristic.uuid) {
                CONTROL_CHARACTERISTIC_UUID -> controlChannel.trySend(value)
                DATA_CHARACTERISTIC_UUID -> dataChannel.trySend(value)
            }
        }
    }
}
