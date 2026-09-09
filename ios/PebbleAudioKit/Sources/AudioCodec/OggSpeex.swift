import Foundation

// Packaging the watch's own Speex frames for upload, without decoding or re-encoding them.
//
// WHY THIS EXISTS. Everything the cloud upload path did to a segment's audio was undoing work the
// watch had already done. The firmware Speex-encodes on the wrist, the frames arrive over BLE and
// are spooled verbatim in `.spxlog`, and the upload path then decoded them to PCM, wrapped the PCM
// in RIFF/WAVE, and posted **32,000 bytes per second of audio** — a 16.4x expansion of the 1,950
// B/s that actually crossed the Bluetooth link. Measured over this user's real 88 days that is
// 12.38 GB, 141 MB/day. FLAC (`PcmFlac`) brought it to ~37% of the WAV. This brings it to **4.08%**,
// deterministically, by not touching the audio at all: an Ogg container is wrapped around the
// existing frames and the bytes inside it are the bytes the watch produced.
//
// WHY THE RATIO IS EXACT AND NOT AN AVERAGE. The firmware encodes CBR wideband at 320 samples per
// frame, and every one of the 18,578,953 frames in the measured corpus is **exactly 25 bytes**.
// 50 frames/s x 25 B = 1,250 B/s of payload; at 254 packets per page the container costs 4.44%
// on top, giving 1,306 B/s against WAV's 32,000 — 24.51x smaller, on every segment, forever.
// Measured on real segments the ratio is 4.080% every time, to three decimals. FLAC by contrast
// measured 29-45% depending on content, because it actually compresses.
//
// AND IT IS ALSO THE CHEAPEST PATH. Timed over 0.70 h of real audio: the remux costs **0.116 s per
// hour of audio**, against 9.72 s/h to decode the same audio and 1.15 s/h to FLAC-encode it
// (debug build, so treat the ratios rather than the absolutes as the result). Packaging what the
// watch already produced is roughly 1% of the cost of decoding it.
//
// WHY THIS IS SAFE. It is a byte copy. There is no signal processing anywhere in this file, so the
// samples a provider's decoder sees are the samples our decoder sees, bit for bit — the strongest
// form of the argument `PcmFlac` makes with a round-trip test. The `.spxlog` record framing
// (`u32 sequence | u64 sampleIndex | u16 len | payload`, `SegmentStore.recordHeaderBytes`) preserves
// frame boundaries exactly, and the firmware calls `speex_bits_reset` per frame with no extra
// header byte (see `SpeexFrameDecoder`), so each stored payload is already a complete, byte-aligned
// Speex packet — precisely what a `frames_per_packet = 1` Ogg Speex stream carries.
//
// THE ONE THING THAT IS NOT PROVEN is whether the transcription providers' demuxers accept Speex
// inside Ogg. Both list `ogg` as a container and neither names a codec; ffmpeg has had a native
// Speex decoder since 5.0, and Soniox says it auto-detects formats from the header, so the odds are
// good — but "good odds" is not a contract. That is why nothing here is unconditional: see
// `CloudUploadFormatPreference`, which walks Ogg Speex -> FLAC -> WAV and durably remembers a
// provider that has actually rejected a format. A rejection costs one HTTP 400 and one requeue.
//
// WHAT IS DELIBERATELY NOT DONE: gaps are not encoded as granule discontinuities. The corpus has
// 7,867 sequence gaps (0.042% of frames), and the WAV path has always simply concatenated the
// frames it has with nothing inserted for the missing ones. Using a RUNNING FRAME COUNTER for the
// granule position reproduces that timing exactly, so transcript timings do not move; using
// `record.sampleIndex` would introduce jumps at every one of those 7,867 points and shift every
// timestamp after them. Representing loss honestly in the uploaded audio is a bigger change than
// this one and belongs with the gap model, not here.

/// Wraps already-encoded Speex frames in an Ogg container. No decode, no encode — a remux.
///
/// References: the Ogg bitstream framing (RFC 3533) and the Speex Ogg mapping as libspeex's own
/// `speexenc` writes it. Verified against ffmpeg's native Speex decoder on real segments from this
/// user's library: `speex, 16000 Hz, 1 channels`, exact duration, seekable, and the decoded PCM
/// matches this app's own libspeex decode.
public enum OggSpeex {
    public enum Failure: Error, Equatable {
        /// No frames to package. Callers fall back to a PCM-derived format rather than posting an
        /// empty container.
        case emptyAudio
        /// A frame is larger than a single Ogg page can carry as one packet. Unreachable for this
        /// firmware (every frame is 25 bytes) and checked anyway, because the alternative is a
        /// silently malformed container.
        case frameTooLarge(bytes: Int)
        /// The sample rate has no Speex mode. Speex is 8/16/32 kHz only.
        case unsupportedSampleRate(Int)
    }

    /// Packets per data page.
    ///
    /// 254 is the Ogg maximum for packets that each need a single lacing value, and it is chosen
    /// over the more common 50 purely for overhead: 4.44% vs 6.18%. Measured, the two produce
    /// **bit-identical** decoded PCM, so this is a size knob and nothing else.
    public static let packetsPerPage = 254

    /// The Ogg page header before its lacing table: capture pattern, version, type, granule,
    /// serial, page sequence, CRC, and the lacing count.
    static let pageHeaderBytes = 27

    /// Length of the Speex identification header packet. Fixed by the format; the field is written
    /// into the header itself and strict parsers check it.
    static let speexHeaderBytes = 80

    /// Logical-stream serial number.
    ///
    /// A constant rather than a random value on purpose. Serial numbers only have to be unique
    /// among the logical streams multiplexed into ONE physical stream, and every file this writes
    /// carries exactly one; making it constant instead means the same frames always remux to the
    /// same bytes, which is what lets a test assert an exact container rather than "something that
    /// parses". ASCII "PBLA".
    static let streamSerial: UInt32 = 0x5042_4C41

    /// Vendor string in the Ogg comment packet. Deliberately the toolkit name and nothing else:
    /// this string leaves the device, so it carries no identifier of the user, the segment, or the
    /// watch.
    static let vendorString = "PebbleAudioKit"

    /// Speex frame sizes by mode, used to derive the mode from the sample rate.
    /// 0 = narrowband (8 kHz), 1 = wideband (16 kHz), 2 = ultra-wideband (32 kHz).
    static func mode(forSampleRateHz rate: Int) throws -> Int32 {
        switch rate {
        case 8_000: return 0
        case 16_000: return 1
        case 32_000: return 2
        default: throw Failure.unsupportedSampleRate(rate)
        }
    }

    /// Remuxes `frames` — raw Speex packets, in stream order — into an Ogg Speex stream.
    ///
    /// `frameSamples` is the encoder's frame size (320 for this firmware's wideband) and is what
    /// the granule position advances by per packet; `bitRateBps` is written into the identification
    /// header. Both come from the segment's own `SegmentMeta`, so a segment recorded under a
    /// different firmware setting still describes itself correctly.
    public static func encode(
        frames: [Data],
        sampleRateHz: Int,
        frameSamples: Int,
        bitRateBps: Int
    ) throws -> Data {
        guard !frames.isEmpty, frames.contains(where: { !$0.isEmpty }) else {
            throw Failure.emptyAudio
        }
        let modeValue = try mode(forSampleRateHz: sampleRateHz)
        let samplesPerPacket = max(1, frameSamples)

        // Sized up front so the container is built in one allocation. Container overhead is under
        // 5% of the payload, and the payload for a 15-minute segment is ~1.13 MB.
        var out = Data()
        out.reserveCapacity(
            frames.reduce(0) { $0 + $1.count } + speexHeaderBytes + 64
                + (frames.count / packetsPerPage + 3) * (pageHeaderBytes + packetsPerPage))

        var pageSequence: UInt32 = 0

        // Page 0: beginning-of-stream, the identification header alone. The Speex mapping requires
        // this packet to be the only one on its page.
        out.append(
            page(
                headerType: 0x02, granulePosition: 0, sequence: pageSequence,
                packets: [
                    identificationHeader(
                        sampleRateHz: sampleRateHz, mode: modeValue, frameSamples: samplesPerPacket,
                        bitRateBps: bitRateBps)
                ]))
        pageSequence += 1

        // Page 1: the comment header, likewise alone on its page.
        out.append(
            page(
                headerType: 0x00, granulePosition: 0, sequence: pageSequence,
                packets: [commentPacket()]))
        pageSequence += 1

        // Data pages. The granule position of a page is the total number of samples decodable once
        // that page has been consumed — a RUNNING COUNT of frames emitted, not the spool's
        // `sampleIndex` (see the note at the top of this file).
        var index = 0
        var framesEmitted = 0
        while index < frames.count {
            let end = min(index + packetsPerPage, frames.count)
            let chunk = Array(frames[index..<end])
            for frame in chunk where frame.count >= 255 {
                // One lacing value per packet is the invariant that makes `packetsPerPage` a
                // packet count rather than a byte budget.
                throw Failure.frameTooLarge(bytes: frame.count)
            }
            index = end
            framesEmitted += chunk.count
            let isLast = index >= frames.count
            out.append(
                page(
                    headerType: isLast ? 0x04 : 0x00,
                    granulePosition: Int64(framesEmitted) * Int64(samplesPerPacket),
                    sequence: pageSequence,
                    packets: chunk))
            pageSequence += 1
        }
        return out
    }

    /// Total samples an `encode`d stream will report, i.e. the duration the provider will see.
    /// Exposed so a caller can state the duration without parsing back what it just wrote.
    public static func sampleCount(frameCount: Int, frameSamples: Int) -> Int {
        frameCount * max(1, frameSamples)
    }

    // MARK: - Packets

    /// The 80-byte Speex identification header, laid out exactly as libspeex writes it.
    static func identificationHeader(
        sampleRateHz: Int, mode: Int32, frameSamples: Int, bitRateBps: Int
    ) -> Data {
        var header = Data()
        header.append(contentsOf: Array("Speex   ".utf8))  // 8-byte magic, space padded
        // 20-byte version string, NUL padded. The value libspeex itself writes for 1.2.x.
        var version = Array("speex-1.2".utf8)
        version.append(contentsOf: [UInt8](repeating: 0, count: 20 - version.count))
        header.append(contentsOf: version)
        header.appendLittleEndian(Int32(1))  // speex_version_id
        header.appendLittleEndian(Int32(speexHeaderBytes))  // header_size
        header.appendLittleEndian(Int32(sampleRateHz))
        header.appendLittleEndian(mode)
        header.appendLittleEndian(Int32(4))  // mode_bitstream_version
        header.appendLittleEndian(Int32(1))  // nb_channels
        // A non-positive rate is written as libspeex's "unknown" sentinel rather than as a lie; a
        // real value is preferred because strict parsers do read it.
        header.appendLittleEndian(bitRateBps > 0 ? Int32(bitRateBps) : Int32(-1))
        header.appendLittleEndian(Int32(frameSamples))
        header.appendLittleEndian(Int32(0))  // vbr — the firmware encoder is CBR
        header.appendLittleEndian(Int32(1))  // frames_per_packet
        header.appendLittleEndian(Int32(0))  // extra_headers
        header.appendLittleEndian(Int32(0))  // reserved1
        header.appendLittleEndian(Int32(0))  // reserved2
        return header
    }

    /// Minimal Vorbis-style comment packet: a vendor string and zero user comments.
    static func commentPacket() -> Data {
        var packet = Data()
        let vendor = Array(vendorString.utf8)
        packet.appendLittleEndian(UInt32(vendor.count))
        packet.append(contentsOf: vendor)
        packet.appendLittleEndian(UInt32(0))  // user comment count
        return packet
    }

    // MARK: - Pages

    /// One Ogg page. Every packet must be under 255 bytes so it needs a single lacing value, which
    /// is checked by the caller; the frames this ships are 25.
    static func page(
        headerType: UInt8, granulePosition: Int64, sequence: UInt32, packets: [Data]
    ) -> Data {
        var page = Data()
        page.reserveCapacity(pageHeaderBytes + packets.count + packets.reduce(0) { $0 + $1.count })
        page.append(contentsOf: Array("OggS".utf8))
        page.append(0)  // stream structure version
        page.append(headerType)
        page.appendLittleEndian(granulePosition)
        page.appendLittleEndian(streamSerial)
        page.appendLittleEndian(sequence)
        page.appendLittleEndian(UInt32(0))  // CRC placeholder — filled in below
        page.append(UInt8(packets.count))
        for packet in packets { page.append(UInt8(packet.count)) }
        for packet in packets { page.append(packet) }

        // The checksum covers the whole page with its own CRC field zeroed, which is why it is
        // written last over a placeholder rather than accumulated as we go.
        let crc = checksum(page)
        page.replaceSubrange(22..<26, with: withUnsafeBytes(of: crc.littleEndian) { Data($0) })
        return page
    }

    /// Ogg's CRC32: polynomial 0x04C11DB7, **no input or output reflection**, initial value 0, no
    /// final XOR. Deliberately not the reflected CRC-32 every zip/png library ships — using that
    /// one produces a container that every demuxer rejects, and it is the single easiest mistake
    /// to make in this file.
    static func checksum(_ bytes: Data) -> UInt32 {
        var crc: UInt32 = 0
        for byte in bytes {
            crc = (crc << 8) ^ crcTable[Int(((crc >> 24) & 0xFF) ^ UInt32(byte))]
        }
        return crc
    }

    private static let crcTable: [UInt32] = {
        (0..<256).map { index -> UInt32 in
            var value = UInt32(index) << 24
            for _ in 0..<8 {
                value = (value & 0x8000_0000) != 0 ? (value << 1) ^ 0x04C1_1DB7 : (value << 1)
            }
            return value
        }
    }()
}

extension Data {
    fileprivate mutating func appendLittleEndian(_ value: Int32) {
        appendLittleEndian(UInt32(bitPattern: value))
    }

    fileprivate mutating func appendLittleEndian(_ value: UInt32) {
        append(contentsOf: [
            UInt8(truncatingIfNeeded: value),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 24),
        ])
    }

    fileprivate mutating func appendLittleEndian(_ value: Int64) {
        let bits = UInt64(bitPattern: value)
        append(contentsOf: (0..<8).map { UInt8(truncatingIfNeeded: bits >> (8 * UInt64($0))) })
    }
}
