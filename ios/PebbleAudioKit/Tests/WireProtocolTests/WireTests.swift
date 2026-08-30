import Testing
@testable import WireProtocol

/// Port of `core/protocol/src/commonTest/.../WireTest.kt`.
@Suite struct WireTest {

    @Test func u64LittleEndianByteOrder() {
        var w = WireWriter()
        w.u64(0x0123_4567_89AB_CDEF)
        let bytes = w.toBytes()
        #expect(bytes == [0xEF, 0xCD, 0xAB, 0x89, 0x67, 0x45, 0x23, 0x01])
        var r = WireReader(bytes)
        #expect(r.u64() == 0x0123_4567_89AB_CDEF)
    }

    @Test func u64BoundaryValuesRoundTrip() {
        let values: [UInt64] = [
            0,
            1,
            0xFF,
            0x100,
            0xFFFF_FFFF,             // u32 max boundary
            0x1_0000_0000,           // first value needing the high dword
            0x7FFF_FFFF_FFFF_FFFF,   // Long.MAX_VALUE boundary
            0x8000_0000_0000_0000,   // sign-bit boundary
            UInt64.max,
        ]
        for value in values {
            var w = WireWriter()
            w.u64(value)
            let bytes = w.toBytes()
            #expect(bytes.count == 8)
            var r = WireReader(bytes)
            #expect(r.u64() == value, "round-trip of \(value)")
        }
    }

    @Test func u64AllOnesIsEightFFBytes() {
        var w = WireWriter()
        w.u64(UInt64.max)
        #expect(w.toBytes() == [UInt8](repeating: 0xFF, count: 8))
    }

    @Test func u32LittleEndianByteOrder() {
        var w = WireWriter()
        w.u32(0xA1B2_C3D4)
        let bytes = w.toBytes()
        #expect(bytes == [0xD4, 0xC3, 0xB2, 0xA1])
        var r = WireReader(bytes)
        #expect(r.u32() == 0xA1B2_C3D4)
        var wAllOnes = WireWriter()
        wAllOnes.u32(0xFFFF_FFFF)
        var rAllOnes = WireReader(wAllOnes.toBytes())
        #expect(rAllOnes.u32() == 0xFFFF_FFFF)
    }

    @Test func u16LittleEndianByteOrder() {
        var w = WireWriter()
        w.u16(0xBEEF)
        let bytes = w.toBytes()
        #expect(bytes == [0xEF, 0xBE])
        var r = WireReader(bytes)
        #expect(r.u16() == 0xBEEF)
    }

    @Test func checkpointBoundaryEncodesAllOnes() throws {
        let cp = Checkpoint(
            requestToken: 0xFF,
            streamId: 0xFFFF_FFFF,
            highestContiguousSequencePersisted: 0xFFFF_FFFF,
            persistedSampleIndex: UInt64.max,
            receiverFlags: 0x3,
            freeStorageHintKb: 0
        )
        let bytes = cp.encode()
        #expect(bytes.count == 26)
        // persisted_sample_index occupies offsets 10..17 and must be all 0xFF.
        for i in 10..<18 {
            #expect(bytes[i] == 0xFF, "byte \(i)")
        }
        let decoded = AudioCompanionProtocol.decodeControlIn(bytes)
        guard case .decoded(let message) = decoded else {
            Issue.record("expected Decoded, got \(decoded)")
            return
        }
        let roundTripped = try #require(message as? Checkpoint)
        #expect(roundTripped == cp)
    }
}
