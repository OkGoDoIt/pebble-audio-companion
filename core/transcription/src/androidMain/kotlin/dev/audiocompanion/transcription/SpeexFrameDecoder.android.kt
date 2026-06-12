package dev.audiocompanion.transcription

import coredevices.speex.SpeexCodec
import coredevices.speex.SpeexDecodeResult
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.io.Buffer
import kotlinx.io.readByteArray

actual class SpeexFrameDecoder actual constructor(
    private val sampleRateHz: Int,
    private val bitRateBps: Int,
    private val frameSamples: Int,
    private val hasHeaderByte: Boolean,
) {
    actual fun decode(frames: Flow<ByteArray>, pcmChunkBytes: Int): Flow<ByteArray> = flow {
        val speex = SpeexCodec(
            sampleRate = sampleRateHz.toLong(),
            bitRate = bitRateBps,
            frameSize = frameSamples,
        )
        val framePcm = ByteArray(frameSamples * Short.SIZE_BYTES)
        val chunk = Buffer()
        try {
            frames.collect { frame ->
                val result = speex.decodeFrame(frame, framePcm, hasHeaderByte = hasHeaderByte)
                if (result != SpeexDecodeResult.Success) {
                    throw TranscriptionException.TranscriptionFailed(
                        "failed to decode Speex frame: $result",
                    )
                }
                chunk.write(framePcm)
                while (chunk.size >= pcmChunkBytes) {
                    emit(chunk.readByteArray(pcmChunkBytes))
                }
            }
            if (chunk.size > 0) {
                emit(chunk.readByteArray(chunk.size.toInt()))
            }
        } finally {
            chunk.close()
        }
    }
}
