package dev.audiocompanion.protocol

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertIs

class WireTest {

    @Test
    fun u64LittleEndianByteOrder() {
        val bytes = WireWriter().u64(0x0123456789ABCDEFuL).toByteArray()
        assertContentEquals(
            byteArrayOf(0xEF.toByte(), 0xCD.toByte(), 0xAB.toByte(), 0x89.toByte(),
                0x67, 0x45, 0x23, 0x01),
            bytes,
        )
        assertEquals(0x0123456789ABCDEFuL, WireReader(bytes).u64())
    }

    @Test
    fun u64BoundaryValuesRoundTrip() {
        for (value in listOf(
            0uL,
            1uL,
            0xFFuL,
            0x100uL,
            0xFFFFFFFFuL,            // u32 max boundary
            0x100000000uL,           // first value needing the high dword
            0x7FFFFFFFFFFFFFFFuL,    // Long.MAX_VALUE boundary
            0x8000000000000000uL,    // sign-bit boundary
            ULong.MAX_VALUE,
        )) {
            val bytes = WireWriter().u64(value).toByteArray()
            assertEquals(8, bytes.size)
            assertEquals(value, WireReader(bytes).u64(), "round-trip of $value")
        }
    }

    @Test
    fun u64AllOnesIsEightFFBytes() {
        assertContentEquals(
            ByteArray(8) { 0xFF.toByte() },
            WireWriter().u64(ULong.MAX_VALUE).toByteArray(),
        )
    }

    @Test
    fun u32LittleEndianByteOrder() {
        val bytes = WireWriter().u32(0xA1B2C3D4u).toByteArray()
        assertContentEquals(
            byteArrayOf(0xD4.toByte(), 0xC3.toByte(), 0xB2.toByte(), 0xA1.toByte()),
            bytes,
        )
        assertEquals(0xA1B2C3D4u, WireReader(bytes).u32())
        assertEquals(0xFFFFFFFFu, WireReader(WireWriter().u32(0xFFFFFFFFu).toByteArray()).u32())
    }

    @Test
    fun u16LittleEndianByteOrder() {
        val bytes = WireWriter().u16(0xBEEF).toByteArray()
        assertContentEquals(byteArrayOf(0xEF.toByte(), 0xBE.toByte()), bytes)
        assertEquals(0xBEEF, WireReader(bytes).u16())
    }

    @Test
    fun checkpointBoundaryEncodesAllOnes() {
        val cp = Checkpoint(
            requestToken = 0xFF,
            streamId = 0xFFFFFFFFu,
            highestContiguousSequencePersisted = 0xFFFFFFFFu,
            persistedSampleIndex = ULong.MAX_VALUE,
            receiverFlags = 0x3u,
            freeStorageHintKb = 0u,
        )
        val bytes = cp.encode()
        assertEquals(26, bytes.size)
        // persisted_sample_index occupies offsets 10..17 and must be all 0xFF.
        for (i in 10 until 18) {
            assertEquals(0xFF.toByte(), bytes[i], "byte $i")
        }
        val decoded = AudioCompanionProtocol.decodeControlIn(bytes)
        assertIs<DecodeResult.Decoded>(decoded)
        assertEquals(cp, decoded.message)
    }
}
