import Foundation
import Testing

@testable import AudioCodec

// The correctness argument for uploading the watch's own Speex frames instead of decoded PCM.
//
// There are two things to prove and they are proved differently:
//
//  1. **The container is well formed.** Asserted structurally here — capture pattern, page
//     sequence, CRC (recomputed over each page with its field zeroed, i.e. the check a demuxer
//     makes), granule positions, the 80-byte identification header — and cross-checked outside
//     the test suite against ffmpeg's own demuxer, which reads a remuxed real segment as
//     `speex, 16000 Hz, 1 channels` with the exact duration and seeks correctly.
//  2. **The audio is unchanged.** That is not a round trip in the FLAC sense (encode, decode,
//     compare) because nothing is encoded: the packets come back out of the container byte for
//     byte, and this suite asserts exactly that, on REAL segments — then decodes the extracted
//     packets with this app's own libspeex and compares the PCM to decoding the originals.
//
// The real-data suites skip cleanly where the backup is absent, matching `RealSegmentGroupingTests`
// and `RealQuarantineRecoveryTests`.

private let backupRoot =
    ProcessInfo.processInfo.environment["PEBBLE_SEGMENT_BACKUP"]
    ?? NSHomeDirectory() + "/Desktop/PebbleAudioBackup/audio-companion-20260901-012413/segments"

private var backupAvailable: Bool {
    FileManager.default.fileExists(atPath: backupRoot, isDirectory: nil)
}

/// The `.spxlog` record framing, read here rather than through `SegmentStore` because AudioCodec
/// sits below it in the dependency graph. Mirrors `SegmentFrameLog.parse`:
/// `u32 sequence | u64 sampleIndex | u16 len | payload`, little-endian, 14-byte header.
private struct SpxlogRecord {
    var sequence: UInt32
    var sampleIndex: UInt64
    var payload: Data
}

private func readSpxlog(_ url: URL) -> [SpxlogRecord] {
    guard let data = try? Data(contentsOf: url) else { return [] }
    var records: [SpxlogRecord] = []
    var offset = 0
    let bytes = [UInt8](data)
    func u16(_ at: Int) -> UInt16 { UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8 }
    func u32(_ at: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[at + $1]) << (8 * UInt32($1)) }
    }
    func u64(_ at: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 | UInt64(bytes[at + $1]) << (8 * UInt64($1)) }
    }
    while offset + 14 <= bytes.count {
        let length = Int(u16(offset + 12))
        guard length > 0, offset + 14 + length <= bytes.count else { break }
        records.append(
            SpxlogRecord(
                sequence: u32(offset), sampleIndex: u64(offset + 4),
                payload: Data(bytes[(offset + 14)..<(offset + 14 + length)])))
        offset += 14 + length
    }
    return records.sorted { $0.sequence < $1.sequence }
}

/// A minimal Ogg demuxer: exactly what a provider's parser has to do, written independently of
/// the writer so a shared misunderstanding cannot make both agree.
private struct OggPage {
    var headerType: UInt8
    var granulePosition: Int64
    var serial: UInt32
    var sequence: UInt32
    var packets: [Data]
    /// Whether the stored CRC matches one recomputed over the page with the field zeroed.
    var checksumValid: Bool
}

private func parseOgg(_ data: Data) -> [OggPage] {
    var pages: [OggPage] = []
    var offset = 0
    let bytes = [UInt8](data)
    func u32(_ at: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[at + $1]) << (8 * UInt32($1)) }
    }
    func i64(_ at: Int) -> Int64 {
        Int64(bitPattern: (0..<8).reduce(UInt64(0)) { $0 | UInt64(bytes[at + $1]) << (8 * UInt64($1)) })
    }
    while offset + 27 <= bytes.count {
        guard Array(bytes[offset..<(offset + 4)]) == Array("OggS".utf8) else { break }
        let segmentCount = Int(bytes[offset + 26])
        let lacingStart = offset + 27
        guard lacingStart + segmentCount <= bytes.count else { break }
        let lacing = Array(bytes[lacingStart..<(lacingStart + segmentCount)])
        let bodyStart = lacingStart + segmentCount
        let bodyLength = lacing.reduce(0) { $0 + Int($1) }
        guard bodyStart + bodyLength <= bytes.count else { break }

        var packets: [Data] = []
        var cursor = bodyStart
        var packet = Data()
        for value in lacing {
            packet.append(contentsOf: bytes[cursor..<(cursor + Int(value))])
            cursor += Int(value)
            if value < 255 {
                packets.append(packet)
                packet = Data()
            }
        }

        var page = Data(bytes[offset..<(bodyStart + bodyLength)])
        let storedCrc = u32(offset + 22)
        page.replaceSubrange(22..<26, with: Data([0, 0, 0, 0]))
        pages.append(
            OggPage(
                headerType: bytes[offset + 5],
                granulePosition: i64(offset + 6),
                serial: u32(offset + 14),
                sequence: u32(offset + 18),
                packets: packets,
                checksumValid: OggSpeex.checksum(page) == storedCrc))
        offset = bodyStart + bodyLength
    }
    return pages
}

/// 25-byte stand-ins for real frames — every frame the firmware has ever produced is this size.
private func syntheticFrames(_ count: Int) -> [Data] {
    (0..<count).map { index in
        Data((0..<25).map { UInt8(truncatingIfNeeded: index &* 31 &+ $0) })
    }
}

@Suite("PT — Ogg Speex container")
struct PtOggSpeexContainerTests {
    @Test("the stream a provider receives is a valid Ogg bitstream")
    func containerIsWellFormed() throws {
        let frames = syntheticFrames(600)
        let ogg = try OggSpeex.encode(
            frames: frames, sampleRateHz: 16_000, frameSamples: 320, bitRateBps: 9_800)
        let pages = parseOgg(ogg)

        // 600 frames at 254 packets per page is 2 header pages plus 3 data pages.
        #expect(pages.count == 5)
        #expect(pages.allSatisfy { $0.checksumValid })
        #expect(pages.map(\.sequence) == [0, 1, 2, 3, 4])
        #expect(pages.allSatisfy { $0.serial == OggSpeex.streamSerial })
        // BOS on the first page, EOS on the last, nothing set in between.
        #expect(pages[0].headerType == 0x02)
        #expect(pages[4].headerType == 0x04)
        #expect(pages[1...3].allSatisfy { $0.headerType == 0 })
        // Both headers alone on their pages, as the Speex Ogg mapping requires.
        #expect(pages[0].packets.count == 1)
        #expect(pages[1].packets.count == 1)
        #expect(pages[0].packets[0].count == 80)
        #expect(pages[0].granulePosition == 0)
        #expect(pages[1].granulePosition == 0)
        #expect(pages[2].packets.count == OggSpeex.packetsPerPage)
        #expect(pages[4].packets.count == 600 - 2 * OggSpeex.packetsPerPage)
    }

    @Test("the identification header describes this firmware's encoder")
    func identificationHeaderIsCorrect() throws {
        let ogg = try OggSpeex.encode(
            frames: syntheticFrames(4), sampleRateHz: 16_000, frameSamples: 320, bitRateBps: 9_800)
        let header = [UInt8](parseOgg(ogg)[0].packets[0])
        func int32(_ at: Int) -> Int32 {
            Int32(
                bitPattern: (0..<4).reduce(UInt32(0)) {
                    $0 | UInt32(header[at + $1]) << (8 * UInt32($1))
                })
        }
        #expect(Array(header[0..<8]) == Array("Speex   ".utf8))
        #expect(int32(28) == 1)  // speex_version_id
        #expect(int32(32) == 80)  // header_size — must match the packet length
        #expect(int32(36) == 16_000)  // rate
        #expect(int32(40) == 1)  // mode: wideband
        #expect(int32(44) == 4)  // mode_bitstream_version
        #expect(int32(48) == 1)  // nb_channels
        #expect(int32(52) == 9_800)  // bitrate, the real value rather than the -1 sentinel
        #expect(int32(56) == 320)  // frame_size
        #expect(int32(60) == 0)  // vbr — the firmware encoder is CBR
        #expect(int32(64) == 1)  // frames_per_packet
        #expect(int32(68) == 0)  // extra_headers
    }

    @Test("granule positions count frames, so a gap never shifts a timestamp")
    func granulePositionsCountFrames() throws {
        let frames = syntheticFrames(300)
        let ogg = try OggSpeex.encode(
            frames: frames, sampleRateHz: 16_000, frameSamples: 320, bitRateBps: 9_800)
        let dataPages = parseOgg(ogg).dropFirst(2)
        // Strictly increasing by exactly `packets * 320`, and ending at the total sample count.
        var expected: Int64 = 0
        for page in dataPages {
            expected += Int64(page.packets.count) * 320
            #expect(page.granulePosition == expected)
        }
        #expect(expected == 300 * 320)
    }

    @Test("8 and 32 kHz map to their Speex modes; anything else is refused")
    func modesAreDerivedFromTheSampleRate() throws {
        #expect(try OggSpeex.mode(forSampleRateHz: 8_000) == 0)
        #expect(try OggSpeex.mode(forSampleRateHz: 16_000) == 1)
        #expect(try OggSpeex.mode(forSampleRateHz: 32_000) == 2)
        #expect(throws: OggSpeex.Failure.unsupportedSampleRate(44_100)) {
            try OggSpeex.mode(forSampleRateHz: 44_100)
        }
    }

    @Test("an empty segment is refused rather than packaged as an empty container")
    func emptyAudioIsRefused() {
        #expect(throws: OggSpeex.Failure.emptyAudio) {
            try OggSpeex.encode(
                frames: [], sampleRateHz: 16_000, frameSamples: 320, bitRateBps: 9_800)
        }
        #expect(throws: OggSpeex.Failure.emptyAudio) {
            try OggSpeex.encode(
                frames: [Data(), Data()], sampleRateHz: 16_000, frameSamples: 320,
                bitRateBps: 9_800)
        }
    }

    @Test("a frame too large for one lacing value is refused, not silently mis-framed")
    func oversizedFrameIsRefused() {
        #expect(throws: OggSpeex.Failure.frameTooLarge(bytes: 255)) {
            try OggSpeex.encode(
                frames: [Data(repeating: 1, count: 255)], sampleRateHz: 16_000, frameSamples: 320,
                bitRateBps: 9_800)
        }
    }

    @Test("the Ogg CRC is the unreflected one, not the CRC-32 every zip library ships")
    func checksumIsOggsVariant() {
        // Values from an independent implementation of the Ogg polynomial (0x04C11DB7, no
        // reflection, init 0, no final XOR). The ORDINARY reflected CRC-32 of "OggS" — what
        // zlib/`zlib.crc32` returns, and what reaching for the nearest CRC helper would give — is
        // 0x7775B7FC. Getting this wrong produces a container every demuxer silently rejects, so
        // it is pinned against a second implementation rather than against itself.
        #expect(OggSpeex.checksum(Data("OggS".utf8)) == 0x5FB0_A94F)
        #expect(OggSpeex.checksum(Data("hello world".utf8)) == 0x737A_F2AE)
        #expect(OggSpeex.checksum(Data()) == 0)
    }

    @Test("the body labels itself as Ogg so a provider can sniff it")
    func bodyLabelsItselfHonestly() throws {
        let body = try CloudAudioBody.passthrough(
            speexFrames: syntheticFrames(50), sampleRateHz: 16_000, frameSamples: 320,
            bitRateBps: 9_800)
        #expect(body.format == .oggSpeex)
        #expect(body.contentType == "audio/ogg")
        #expect(body.filename("segment") == "segment.ogg")
        #expect(body.bytes.prefix(4).elementsEqual("OggS".utf8))
    }
}

@Suite(
    "PT — Ogg Speex against Roger's real library",
    .enabled(if: backupAvailable, "no PebbleAudioBackup on this machine")
)
struct PtOggSpeexRealDataTests {
    /// Real segments, largest first, so the size claims are made on the ones that matter.
    private static func realSegments(_ limit: Int) -> [URL] {
        let entries =
            (try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: backupRoot),
                includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return
            entries
            .filter { $0.pathExtension == "spxlog" }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let b = (try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return a > b
            }
            .prefix(limit)
            .map { $0 }
    }

    @Test("the packets come back out of the container byte for byte")
    func packetsSurviveTheRemuxUnchanged() throws {
        var checked = 0
        for url in Self.realSegments(6) {
            let frames = readSpxlog(url).map(\.payload)
            guard frames.count > 500 else { continue }
            let ogg = try OggSpeex.encode(
                frames: frames, sampleRateHz: 16_000, frameSamples: 320, bitRateBps: 9_800)
            let pages = parseOgg(ogg)
            #expect(pages.allSatisfy { $0.checksumValid })
            let extracted = pages.dropFirst(2).flatMap(\.packets)
            #expect(extracted.count == frames.count)
            #expect(extracted == frames, "\(url.lastPathComponent) did not round-trip")
            checked += 1
        }
        #expect(checked >= 3, "expected several large real segments in the backup")
    }

    @Test("decoding what we send gives the same PCM as decoding what we stored")
    func decodedAudioIsIdentical() throws {
        let decoder = SpeexFrameDecoder(sampleRateHz: 16_000, bitRateBps: 9_800, frameSamples: 320)
        var checked = 0
        for url in Self.realSegments(3) {
            let frames = readSpxlog(url).map(\.payload)
            guard frames.count > 500 else { continue }
            let ogg = try OggSpeex.encode(
                frames: frames, sampleRateHz: 16_000, frameSamples: 320, bitRateBps: 9_800)
            let extracted = parseOgg(ogg).dropFirst(2).flatMap(\.packets)
            // Two independent decode sessions over the same packets: the point is that what the
            // provider pulls out of the container decodes to what the app itself would decode.
            let fromSpool = try decoder.decodeAll(frames: frames)
            let fromContainer = try decoder.decodeAll(frames: extracted)
            #expect(fromSpool == fromContainer)
            #expect(fromSpool.count == frames.count * 320 * 2)
            checked += 1
        }
        #expect(checked >= 2)
    }

    @Test("the size is the deterministic 4.08% of WAV, on every real segment")
    func sizeMatchesTheMeasuredRatio() throws {
        var ratios: [Double] = []
        for url in Self.realSegments(12) {
            let frames = readSpxlog(url).map(\.payload)
            guard frames.count > 500 else { continue }
            // Every frame this firmware has ever produced is 25 bytes (CBR); the whole size
            // argument rests on that, so it is asserted rather than assumed.
            #expect(frames.allSatisfy { $0.count == 25 })
            let ogg = try OggSpeex.encode(
                frames: frames, sampleRateHz: 16_000, frameSamples: 320, bitRateBps: 9_800)
            let wavBytes = frames.count * 320 * 2 + PcmWav.headerBytes
            ratios.append(Double(ogg.count) / Double(wavBytes))
        }
        #expect(ratios.count >= 6)
        // 1,306 B/s against WAV's 32,000. Bounded on both sides: a regression that made the
        // container fatter and one that dropped audio would both show up here.
        #expect(ratios.allSatisfy { $0 > 0.0400 && $0 < 0.0412 })
    }

    @Test("a real segment's gaps do not move its timeline")
    func gapsDoNotShiftTimings() throws {
        // The corpus has 7,867 sequence gaps. Using `sampleIndex` for the granule position would
        // put a discontinuity at every one of them and shift every timestamp after it; a running
        // frame count reproduces exactly what the WAV path has always produced, which is the
        // frames concatenated with nothing inserted for the missing ones.
        var withGaps = 0
        for url in Self.realSegments(20) {
            let records = readSpxlog(url)
            guard let first = records.first, let last = records.last, records.count > 500 else {
                continue
            }
            let expectedSpan = UInt32(records.count - 1)
            guard last.sequence - first.sequence != expectedSpan else { continue }
            withGaps += 1
            let ogg = try OggSpeex.encode(
                frames: records.map(\.payload), sampleRateHz: 16_000, frameSamples: 320,
                bitRateBps: 9_800)
            let finalGranule = parseOgg(ogg).last?.granulePosition ?? -1
            #expect(finalGranule == Int64(records.count) * 320)
            // The alternative that was rejected: the spool's own sample index, which is larger
            // here precisely because frames are missing.
            let sampleIndexSpan = Int64(last.sampleIndex - first.sampleIndex) + 320
            #expect(sampleIndexSpan > finalGranule)
        }
        #expect(withGaps >= 1, "expected at least one real segment with a sequence gap")
    }
}
