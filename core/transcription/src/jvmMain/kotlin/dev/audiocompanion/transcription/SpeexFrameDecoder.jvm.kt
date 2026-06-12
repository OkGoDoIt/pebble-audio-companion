package dev.audiocompanion.transcription

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow

actual class SpeexFrameDecoder actual constructor(
    private val sampleRateHz: Int,
    private val bitRateBps: Int,
    private val frameSamples: Int,
    private val hasHeaderByte: Boolean,
) {
    actual fun decode(frames: Flow<ByteArray>, pcmChunkBytes: Int): Flow<ByteArray> = flow {
        throw TranscriptionException.TranscriptionFailed(
            "Speex decoding is only available on Android and iOS targets",
        )
    }
}
