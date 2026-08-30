import Foundation

/// Little-endian packed-struct primitives (spec Section 2). Shared by the message codecs
/// and by SegmentStore, whose frame-log records deliberately use the same record shape as
/// STREAM_DATA frame entries. Port of `core/protocol/.../Wire.kt`.
public struct WireWriter {
    private var buf: [UInt8]

    public init(initialCapacity: Int = 32) {
        buf = []
        buf.reserveCapacity(initialCapacity)
    }

    @discardableResult
    public mutating func u8(_ value: Int) -> WireWriter {
        buf.append(UInt8(truncatingIfNeeded: value))
        return self
    }

    @discardableResult
    public mutating func u16(_ value: Int) -> WireWriter {
        buf.append(UInt8(truncatingIfNeeded: value))
        buf.append(UInt8(truncatingIfNeeded: value >> 8))
        return self
    }

    @discardableResult
    public mutating func u32(_ value: UInt32) -> WireWriter {
        buf.append(UInt8(truncatingIfNeeded: value))
        buf.append(UInt8(truncatingIfNeeded: value >> 8))
        buf.append(UInt8(truncatingIfNeeded: value >> 16))
        buf.append(UInt8(truncatingIfNeeded: value >> 24))
        return self
    }

    @discardableResult
    public mutating func u64(_ value: UInt64) -> WireWriter {
        var v = value
        for _ in 0..<8 {
            buf.append(UInt8(truncatingIfNeeded: v))
            v >>= 8
        }
        return self
    }

    @discardableResult
    public mutating func bytes(_ value: [UInt8]) -> WireWriter {
        buf.append(contentsOf: value)
        return self
    }

    @discardableResult
    public mutating func bytes(_ value: Data) -> WireWriter {
        buf.append(contentsOf: value)
        return self
    }

    public func toBytes() -> [UInt8] { buf }
    public func toData() -> Data { Data(buf) }
}

/// Reader over a byte buffer. Callers must check `remaining` before reading.
public struct WireReader {
    private let bytes: [UInt8]
    private var offset: Int

    public init(_ bytes: [UInt8], offset: Int = 0) {
        self.bytes = bytes
        self.offset = offset
    }

    public init(_ data: Data, offset: Int = 0) {
        self.bytes = [UInt8](data)
        self.offset = offset
    }

    public var remaining: Int { bytes.count - offset }

    public mutating func u8() -> Int {
        defer { offset += 1 }
        return Int(bytes[offset])
    }

    public mutating func u16() -> Int {
        defer { offset += 2 }
        return Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
    }

    public mutating func u32() -> UInt32 {
        var v: UInt32 = 0
        for i in stride(from: 3, through: 0, by: -1) {
            v = (v << 8) | UInt32(bytes[offset + i])
        }
        offset += 4
        return v
    }

    public mutating func u64() -> UInt64 {
        var v: UInt64 = 0
        for i in stride(from: 7, through: 0, by: -1) {
            v = (v << 8) | UInt64(bytes[offset + i])
        }
        offset += 8
        return v
    }

    public mutating func readBytes(_ count: Int) -> [UInt8] {
        defer { offset += count }
        return Array(bytes[offset..<(offset + count)])
    }
}
