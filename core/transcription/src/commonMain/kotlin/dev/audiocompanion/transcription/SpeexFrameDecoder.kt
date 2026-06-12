package dev.audiocompanion.transcription

import kotlinx.coroutines.flow.Flow

/**
 * Decodes firmware Speex wideband frames to bounded PCM16 chunks for transcription.
 *
 * Audio Companion STREAM_DATA frames carry raw output from PebbleOS `voice_speex_encode_frame()`;
 * unlike the official dictation path, there is no extra frame-quality/header byte.
 */
expect class SpeexFrameDecoder(
    sampleRateHz: Int = 16_000,
    bitRateBps: Int = 9_800,
    frameSamples: Int = 320,
    hasHeaderByte: Boolean = false,
) {
    fun decode(frames: Flow<ByteArray>, pcmChunkBytes: Int = 16_000 * Short.SIZE_BYTES):
        Flow<ByteArray>
}
