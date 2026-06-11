package dev.audiocompanion.transport

import dev.audiocompanion.protocol.AudioCompanionMessage
import dev.audiocompanion.protocol.InfoSnapshot
import dev.audiocompanion.protocol.ProtocolConstants
import dev.audiocompanion.protocol.StreamStart
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.receiveAsFlow

/** Scripted [AudioGattLink]: tests push bytes in and capture control writes. */
class FakeAudioGattLink(
    var infoBytes: ByteArray = defaultInfo().encode(),
) : AudioGattLink {
    val linkState = MutableStateFlow(LinkState.Disconnected)
    override val connectionState: StateFlow<LinkState> = linkState

    val controlWrites = mutableListOf<ByteArray>()

    private val controlChannel = Channel<ByteArray>(Channel.UNLIMITED)
    private val dataChannel = Channel<ByteArray>(Channel.UNLIMITED)

    override suspend fun readInfo(): ByteArray = infoBytes

    override suspend fun writeControl(message: ByteArray) {
        controlWrites += message
    }

    override val controlNotifications: Flow<ByteArray> = controlChannel.receiveAsFlow()
    override val dataNotifications: Flow<ByteArray> = dataChannel.receiveAsFlow()

    fun pushControl(message: AudioCompanionMessage) {
        check(controlChannel.trySend(message.encode()).isSuccess)
    }

    fun pushControlBytes(bytes: ByteArray) {
        check(controlChannel.trySend(bytes).isSuccess)
    }

    fun pushData(message: AudioCompanionMessage) {
        check(dataChannel.trySend(message.encode()).isSuccess)
    }

    fun pushDataBytes(bytes: ByteArray) {
        check(dataChannel.trySend(bytes).isSuccess)
    }

    companion object {
        fun defaultInfo(): InfoSnapshot = InfoSnapshot(
            infoVersion = 1,
            protocolMin = 1,
            protocolMax = 1,
            serviceStateRaw = 2,
            codecBitmap = ProtocolConstants.CODEC_BITMAP_SPEEX_WIDEBAND,
            flags = ProtocolConstants.INFO_FLAG_RECEIVER_AUTHORIZED or ProtocolConstants.INFO_FLAG_ENABLED,
            fwVersionPacked = (4u shl 24) or (9u shl 16) or 2u,
        )
    }
}

sealed interface SinkEvent {
    data class Open(val start: StreamStart) : SinkEvent
    data class Append(val streamId: UInt, val frames: List<SegmentFrame>) : SinkEvent
    data class Gap(val streamId: UInt, val gap: GapRecord) : SinkEvent
    data class Close(val reason: SegmentCloseReason) : SinkEvent
}

class FakeSegmentSink : SegmentSink {
    val events = mutableListOf<SinkEvent>()
    var open = false
        private set

    override suspend fun openSegment(start: StreamStart, receivedAtMs: Long, provenance: SegmentProvenance?) {
        events += SinkEvent.Open(start)
        open = true
    }

    override suspend fun appendFrames(streamId: UInt, frames: List<SegmentFrame>) {
        events += SinkEvent.Append(streamId, frames)
    }

    override suspend fun recordGap(streamId: UInt, gap: GapRecord) {
        events += SinkEvent.Gap(streamId, gap)
    }

    override suspend fun closeSegment(reason: SegmentCloseReason) {
        if (!open) return
        events += SinkEvent.Close(reason)
        open = false
    }

    inline fun <reified T : SinkEvent> eventsOf(): List<T> = events.filterIsInstance<T>()
}

class FakeReceiverPolicy(
    var flags: UInt = 0u,
    var freeKb: UInt = 870_400u,
) : ReceiverPolicy {
    override fun receiverFlags(): UInt = flags
    override fun freeStorageHintKb(): UInt = freeKb
}

class FakeResumeStore : ReceiverResumeStore {
    var saved: ReceiverResumeState? = null
    val history = mutableListOf<ReceiverResumeState>()

    override suspend fun save(state: ReceiverResumeState) {
        saved = state
        history += state
    }

    override suspend fun load(): ReceiverResumeState? = saved
}
