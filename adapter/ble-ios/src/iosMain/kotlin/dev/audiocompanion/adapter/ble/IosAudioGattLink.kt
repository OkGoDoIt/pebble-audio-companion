package dev.audiocompanion.adapter.ble

import dev.audiocompanion.protocol.ProtocolConstants
import dev.audiocompanion.transport.AudioGattLink
import dev.audiocompanion.transport.LinkState
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.receiveAsFlow
import platform.CoreBluetooth.CBCentralManager
import platform.CoreBluetooth.CBPeripheral
import platform.CoreBluetooth.CBUUID

/**
 * Core Bluetooth implementation of [AudioGattLink] (plan 6.4).
 *
 * Skeleton only for now: structure, UUIDs, and notification routing are in place. The real
 * implementation creates the CBCentralManager at app launch with
 * CBCentralManagerOptionRestoreIdentifierKey = [RESTORE_IDENTIFIER], rebuilds sessions from
 * willRestoreState, prefers retrieveConnectedPeripherals over scanning, and keeps the
 * didUpdateValueFor handler append-and-return-fast (< 100 ms; no decode, no transcription).
 */
class IosAudioGattLink : AudioGattLink {

    companion object {
        const val RESTORE_IDENTIFIER = "audio-companion-central"

        val SERVICE_UUID: CBUUID = CBUUID.UUIDWithString(ProtocolConstants.SERVICE_UUID)
        val INFO_CHARACTERISTIC_UUID: CBUUID = CBUUID.UUIDWithString(ProtocolConstants.INFO_CHARACTERISTIC_UUID)
        val CONTROL_CHARACTERISTIC_UUID: CBUUID = CBUUID.UUIDWithString(ProtocolConstants.CONTROL_CHARACTERISTIC_UUID)
        val DATA_CHARACTERISTIC_UUID: CBUUID = CBUUID.UUIDWithString(ProtocolConstants.DATA_CHARACTERISTIC_UUID)
    }

    private val _connectionState = MutableStateFlow(LinkState.Disconnected)
    override val connectionState: StateFlow<LinkState> = _connectionState.asStateFlow()

    private val controlChannel = Channel<ByteArray>(Channel.UNLIMITED)
    private val dataChannel = Channel<ByteArray>(Channel.UNLIMITED)

    override val controlNotifications: Flow<ByteArray> = controlChannel.receiveAsFlow()
    override val dataNotifications: Flow<ByteArray> = dataChannel.receiveAsFlow()

    private var centralManager: CBCentralManager? = null
    private var peripheral: CBPeripheral? = null

    /**
     * Joins the existing system link when possible:
     * retrieveConnectedPeripherals(withServices:) -> connect(); otherwise a pending connect()
     * on the stored peripheral identifier. Scanning is a foreground-only onboarding fallback.
     */
    fun connect() {
        _connectionState.value = LinkState.Connecting
        // TODO(adapter): CBCentralManagerDelegate (NSObject subclass) wiring: state restoration,
        //  service/characteristic discovery, setNotifyValue for Control + Data, then Ready.
        TODO("Core Bluetooth connection management is implemented in the adapter milestone")
    }

    override suspend fun readInfo(): ByteArray {
        // TODO(adapter): peripheral.readValueForCharacteristic(info) bridged via
        //  didUpdateValueForCharacteristic.
        TODO("Info reads are implemented in the adapter milestone")
    }

    override suspend fun writeControl(message: ByteArray) {
        // TODO(adapter): peripheral.writeValue(message.toNSData(), control,
        //  CBCharacteristicWriteWithResponse) bridged via didWriteValueForCharacteristic.
        TODO("Control writes are implemented in the adapter milestone")
    }
}
