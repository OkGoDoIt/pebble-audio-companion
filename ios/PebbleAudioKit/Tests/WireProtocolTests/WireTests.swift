import Testing
@testable import WireProtocol

/// Port of `core/protocol/src/commonTest/.../WireTest.kt`.
@Suite struct WireTest {
    @Test func timerLifecycleWireContract() throws {
        let create = WatchActionRequest.timers(.create, seconds: 60, label: "Tea")
        #expect(try create.payload() == [11, 1, 0, 0, 0, 0, 60, 0, 0, 0, 1, 3, 84, 101, 97])
        for request in [create, .timers(.list), .timers(.get, id: 0x12345678),
                        .timers(.pause, id: 42), .timers(.resume, id: 42), .timers(.update, id: 42, label: ""),
                        .timers(.restart, id: 42), .timers(.cancel, id: 42)] {
            #expect(WatchActionRequest.parse(try request.payload()) == request)
        }
        #expect(WatchActionRequest.parse(Array(try create.payload().dropLast())) == nil)
        #expect(WatchActionRequest.parse(try create.payload() + [0]) == nil)
        #expect(throws: WatchActionRequest.Invalid.self) { try WatchActionRequest.timers(.pause).payload() }
        #expect(throws: WatchActionRequest.Invalid.self) { try WatchActionRequest.timers(.update, id: 42).payload() }
    }

    @Test func smartAlarmWireContractRejectsMalformedRequests() throws {
        let create = WatchActionRequest.alarms(.create, hour: 11, minute: 18, smart: 1, enabled: 1)
        #expect(try create.payload() == [10, 1, 0, 11, 18, 1, 1])
        #expect(WatchActionRequest.parse(try create.payload()) == create)
        #expect(WatchActionRequest.parse([10, 1, 0, 24, 18, 1, 1]) == nil)
        #expect(WatchActionRequest.parse([10, 1, 0, 11, 18, 1]) == nil)
        #expect(WatchActionRequest.parse([10, 2, 3, 255, 255, 2, 255]) == nil)
        #expect(WatchActionRequest.parse([10, 2, 3, 255, 30, 255, 255]) == .alarms(.update, id: 3, minute: 30))
    }


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

@Suite struct InfoSnapshotVersionTests {
    private static let v1: [UInt8] = [
        1, 1, 1, 3, 1, 0b011, 0, 0, 0, 0, 0, 0, 2, 0, 9, 4, 0, 0, 0, 0,
    ]

    @Test func aVersionOneSnapshotHasNoRestart() {
        guard case .decoded(let message) = AudioCompanionProtocol.decodeInfo(Self.v1),
            let info = message as? InfoSnapshot
        else { Issue.record("v1 info did not decode"); return }
        #expect(info.infoVersion == 1)
        #expect(info.restart == nil)
        #expect(info.fwVersionText == "4.9.2")
    }

    // The golden fixture: a watchdog restart that made the fault-loop guard stand down. The
    // phone reads the reason, the counters and the stuck task's PC/LR instead of an
    // unexplained "disabled".
    @Test func aVersionTwoSnapshotCarriesTheLastRestart() {
        // spec/fixtures/info_v2_after_fault.bin, byte for byte.
        let bytes: [UInt8] = [
            0x02, 0x01, 0x01, 0x00, 0x01, 0x09, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x24, 0x04, 0x07, 0x00, 0x00, 0x00, 0x10, 0x00, 0x05, 0x01, 0xCD, 0xAB, 0x00, 0x10,
            0x01, 0xEF, 0x00, 0x10,
        ]
        #expect(bytes.count == ProtocolConstants.infoSnapshotV2Bytes)
        guard case .decoded(let message) = AudioCompanionProtocol.decodeInfo(bytes),
            let info = message as? InfoSnapshot, let restart = info.restart
        else { Issue.record("v2 info did not decode with a restart"); return }
        #expect(info.infoVersion == 2)
        #expect(info.fwVersionText == "4.36.0")
        #expect(info.sendBackpressureEventsRaw == 7)
        #expect(restart.reasonRaw == 16)
        #expect(restart.isFault)
        #expect(restart.reasonName == "watchdog")
        #expect(restart.faultBoots == 0)
        #expect(restart.errorReboots == 5)
        #expect(restart.stoodDown)
        #expect(restart.faultPc == 0x1000_ABCD)
        #expect(restart.faultLr == 0x1000_EF01)
        #expect(restart.summary.contains("STOOD DOWN"))
        #expect(restart.summary.contains("pc=0x1000abcd"))
    }

    // A version-2 header on a 20-byte body (a truncated read) is still a valid v1 snapshot.
    @Test func aShortVersionTwoReadFallsBackToTheVersionOneFields() {
        var bytes = Self.v1
        bytes[0] = 2
        guard case .decoded(let message) = AudioCompanionProtocol.decodeInfo(bytes),
            let info = message as? InfoSnapshot
        else { Issue.record("short v2 info did not decode"); return }
        #expect(info.infoVersion == 2)
        #expect(info.restart == nil)
    }
}
