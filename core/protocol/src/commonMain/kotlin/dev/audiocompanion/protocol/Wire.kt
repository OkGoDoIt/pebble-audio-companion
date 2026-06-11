package dev.audiocompanion.protocol

/**
 * Little-endian packed-struct primitives (spec Section 2). Shared by the message
 * codecs here and by :core:storage, whose frame-log records deliberately use the
 * same record shape as STREAM_DATA frame entries.
 */
class WireWriter(initialCapacity: Int = 32) {
    private var buf = ByteArray(initialCapacity)
    private var size = 0

    private fun ensure(extra: Int) {
        if (size + extra > buf.size) {
            buf = buf.copyOf(maxOf(buf.size * 2, size + extra))
        }
    }

    fun u8(value: Int): WireWriter {
        ensure(1)
        buf[size++] = (value and 0xFF).toByte()
        return this
    }

    fun u16(value: Int): WireWriter {
        ensure(2)
        buf[size++] = (value and 0xFF).toByte()
        buf[size++] = ((value ushr 8) and 0xFF).toByte()
        return this
    }

    fun u32(value: UInt): WireWriter {
        ensure(4)
        buf[size++] = (value and 0xFFu).toByte()
        buf[size++] = ((value shr 8) and 0xFFu).toByte()
        buf[size++] = ((value shr 16) and 0xFFu).toByte()
        buf[size++] = ((value shr 24) and 0xFFu).toByte()
        return this
    }

    fun u64(value: ULong): WireWriter {
        ensure(8)
        var v = value
        repeat(8) {
            buf[size++] = (v and 0xFFu).toByte()
            v = v shr 8
        }
        return this
    }

    fun bytes(value: ByteArray): WireWriter {
        ensure(value.size)
        value.copyInto(buf, size)
        size += value.size
        return this
    }

    fun toByteArray(): ByteArray = buf.copyOf(size)
}

/** Reader over a ByteArray. Callers must check [remaining] before reading. */
class WireReader(private val bytes: ByteArray, private var offset: Int = 0) {
    val remaining: Int get() = bytes.size - offset

    fun u8(): Int = bytes[offset++].toInt() and 0xFF

    fun u16(): Int {
        val v = (bytes[offset].toInt() and 0xFF) or
            ((bytes[offset + 1].toInt() and 0xFF) shl 8)
        offset += 2
        return v
    }

    fun u32(): UInt {
        var v = 0u
        for (i in 3 downTo 0) {
            v = (v shl 8) or (bytes[offset + i].toUInt() and 0xFFu)
        }
        offset += 4
        return v
    }

    fun u64(): ULong {
        var v = 0uL
        for (i in 7 downTo 0) {
            v = (v shl 8) or (bytes[offset + i].toULong() and 0xFFu)
        }
        offset += 8
        return v
    }

    fun bytes(count: Int): ByteArray {
        val out = bytes.copyOfRange(offset, offset + count)
        offset += count
        return out
    }
}
