package dev.audiocompanion.transcription

internal object PcmWav {
    private const val HEADER_BYTES = 44
    private const val PCM_FORMAT = 1

    fun encodeMono16(pcm: ByteArray, sampleRateHz: Int): ByteArray {
        require(sampleRateHz > 0) { "sampleRateHz must be positive" }
        val out = ByteArray(HEADER_BYTES + pcm.size)
        out.writeAscii(0, "RIFF")
        out.writeU32Le(4, (36 + pcm.size).toUInt())
        out.writeAscii(8, "WAVE")
        out.writeAscii(12, "fmt ")
        out.writeU32Le(16, 16u)
        out.writeU16Le(20, PCM_FORMAT.toUShort())
        out.writeU16Le(22, 1u)
        out.writeU32Le(24, sampleRateHz.toUInt())
        out.writeU32Le(28, (sampleRateHz * Short.SIZE_BYTES).toUInt())
        out.writeU16Le(32, Short.SIZE_BYTES.toUShort())
        out.writeU16Le(34, 16u)
        out.writeAscii(36, "data")
        out.writeU32Le(40, pcm.size.toUInt())
        pcm.copyInto(out, destinationOffset = HEADER_BYTES)
        return out
    }

    private fun ByteArray.writeAscii(offset: Int, value: String) {
        value.encodeToByteArray().copyInto(this, offset)
    }

    private fun ByteArray.writeU16Le(offset: Int, value: UShort) {
        this[offset] = (value.toInt() and 0xFF).toByte()
        this[offset + 1] = ((value.toInt() ushr 8) and 0xFF).toByte()
    }

    private fun ByteArray.writeU32Le(offset: Int, value: UInt) {
        this[offset] = (value.toInt() and 0xFF).toByte()
        this[offset + 1] = ((value.toInt() ushr 8) and 0xFF).toByte()
        this[offset + 2] = ((value.toInt() ushr 16) and 0xFF).toByte()
        this[offset + 3] = ((value.toInt() ushr 24) and 0xFF).toByte()
    }
}
