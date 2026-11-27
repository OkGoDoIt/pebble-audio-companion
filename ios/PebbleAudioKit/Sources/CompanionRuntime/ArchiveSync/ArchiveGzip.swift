import Compression
import Foundation

/// A batch body as a gzip member (RFC 1952): the 10-byte header, the raw DEFLATE stream Apple's
/// `COMPRESSION_ZLIB` writes, then the CRC-32 and length of the original. Sync batches are JSON
/// transcripts; measured on the phone's batches they come out about 7x smaller.
enum ArchiveGzip {
    /// Nil when the encoder can't do better than the input (it then goes as it is).
    static func compress(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let capacity = data.count + 64 * 1024
        var deflated = Data(count: capacity)
        let written = deflated.withUnsafeMutableBytes { output in
            data.withUnsafeBytes { input in
                compression_encode_buffer(
                    output.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    input.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0, written + 18 < data.count else { return nil }
        var out = Data([0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0x03])
        out.append(deflated.prefix(written))
        var crc = crc32(data).littleEndian
        var size = UInt32(truncatingIfNeeded: data.count).littleEndian
        withUnsafeBytes(of: &crc) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: &size) { out.append(contentsOf: $0) }
        return out
    }

    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { bytes in
            for byte in bytes.bindMemory(to: UInt8.self) {
                crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}
