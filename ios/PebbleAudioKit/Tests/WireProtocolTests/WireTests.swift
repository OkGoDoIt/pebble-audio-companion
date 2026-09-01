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

    // MARK: - Info: send_backpressure_events (spec Section 3, wire bytes 16-19)

    /// The whole reason the field carries a flag bit: firmware that predates it leaves the word
    /// zero, and a zero read as a count is a confident, wrong "the radio never refused anything".
    /// Same 20 bytes, same info_version — only bit3 separates the two readings.
    @Test func backpressureCounterIsOnlyACountWhenTheFlagSaysSo() throws {
        let reporting = try #require(
            decodeInfo(flags: 0b1011, backpressureWord: 1487) as? InfoSnapshot
        )
        #expect(reporting.reportsSendBackpressure)
        #expect(reporting.sendBackpressureEvents == 1487)

        // Older firmware: bit3 clear, the word zero. "Not available", never "zero backpressure".
        let older = try #require(decodeInfo(flags: 0b011, backpressureWord: 0) as? InfoSnapshot)
        #expect(!older.reportsSendBackpressure)
        #expect(older.sendBackpressureEvents == nil)
        #expect(older.sendBackpressureEventsRaw == 0)
        // The bits it shares with the reporting snapshot still decode identically.
        #expect(older.receiverAuthorized && older.enabled && !older.consentPending)

        // A firmware that reports it and has never been refused: a REAL zero, and distinct.
        let calm = try #require(decodeInfo(flags: 0b1011, backpressureWord: 0) as? InfoSnapshot)
        #expect(calm.sendBackpressureEvents == 0)
        #expect(calm.sendBackpressureEvents != older.sendBackpressureEvents)
    }

    /// Byte-exact re-encode of a snapshot carrying a non-zero counter: the field took over
    /// `reserved1` in place, so the 20-byte layout must survive a decode/encode round trip.
    @Test func backpressureCounterReEncodesByteExact() throws {
        let bytes = infoBytes(flags: 0b1011, backpressureWord: 0xFFFF_FFFF)
        let decoded = AudioCompanionProtocol.decodeInfo(bytes)
        guard case .decoded(let message) = decoded else {
            Issue.record("expected Decoded, got \(decoded)")
            return
        }
        let info = try #require(message as? InfoSnapshot)
        #expect(info.sendBackpressureEvents == 0xFFFF_FFFF)
        let encoded = info.encode()
        #expect(encoded.count == ProtocolConstants.infoSnapshotBytes)
        #expect(encoded == bytes)
        // Little-endian, at offsets 16..19 and nowhere else.
        #expect(Array(encoded[16..<20]) == [0xFF, 0xFF, 0xFF, 0xFF])
    }

    private func infoBytes(flags: Int, backpressureWord: UInt32) -> [UInt8] {
        InfoSnapshot(
            infoVersion: 1,
            protocolMin: 1,
            protocolMax: 1,
            serviceStateRaw: 3,
            codecBitmap: 1,
            flags: flags,
            fwVersionPacked: (4 << 24) | (9 << 16) | 2,
            sendBackpressureEventsRaw: backpressureWord
        ).encode()
    }

    private func decodeInfo(flags: Int, backpressureWord: UInt32) -> AudioCompanionMessage? {
        guard
            case .decoded(let message) = AudioCompanionProtocol.decodeInfo(
                infoBytes(flags: flags, backpressureWord: backpressureWord)
            )
        else { return nil }
        return message
    }
}
