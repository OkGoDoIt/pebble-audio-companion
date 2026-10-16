import Foundation

/// Chunked framing for setup messages larger than one BLE packet
/// (`linux/src/musegadget/ble_framing.py`). Both directions use the same frame: `0xFE`, chunk
/// index, total chunks, then a payload fragment. A packet that doesn't start with `0xFE` is a
/// complete, unchunked message.
public enum MuseBLEFraming {
    public static let chunkMagic: UInt8 = 0xFE
    public static let headerBytes = 3
    public static let maxPacketBytes = 160
    public static let maxChunks = 255
    public static let maxMessageBytes = 8192
    public static let defaultATTMTU = 23
    /// Pause between notifications of one message; the reference paces them so the phone's
    /// stack doesn't drop any.
    public static let chunkStagger: Duration = .milliseconds(50)

    public struct MessageTooLarge: Error, Equatable {
        public let chunks: Int
    }

    /// Splits `data` into framed packets that each fit one notification at `mtu`.
    public static func encode(_ data: Data, mtu: Int = defaultATTMTU) throws -> [Data] {
        let notifyMax = min(mtu > 3 ? mtu - 3 : 20, maxPacketBytes)
        let usable = notifyMax - headerBytes
        var fragments: [Data] = stride(from: 0, to: data.count, by: usable).map { start in
            data.subdata(in: (data.startIndex + start)..<(data.startIndex + min(start + usable, data.count)))
        }
        if fragments.isEmpty { fragments = [Data()] }
        guard fragments.count <= maxChunks else { throw MessageTooLarge(chunks: fragments.count) }
        let total = UInt8(fragments.count)
        return fragments.enumerated().map { index, fragment in
            Data([chunkMagic, UInt8(index), total]) + fragment
        }
    }
}

/// Reassembles chunked writes, strictly in order. Index 0, or a change in the total, starts a new
/// message; an out-of-order chunk or an oversize message discards what was collected.
public struct MuseChunkAssembler: Sendable {
    private let maxBytes: Int
    private var buffer = Data()
    private var total = 0
    private var next = 0

    public init(maxBytes: Int = MuseBLEFraming.maxMessageBytes) {
        self.maxBytes = maxBytes
    }

    public mutating func reset() {
        buffer = Data()
        total = 0
        next = 0
    }

    /// Adds one write; returns a complete message once one is available.
    public mutating func feed(_ packet: Data) -> Data? {
        let bytes = [UInt8](packet)
        guard bytes.count >= MuseBLEFraming.headerBytes, bytes[0] == MuseBLEFraming.chunkMagic else {
            return packet
        }
        let index = Int(bytes[1])
        let packetTotal = Int(bytes[2])
        let fragment = Data(bytes[MuseBLEFraming.headerBytes...])
        if packetTotal == 0 {
            reset()
            return nil
        }
        if index == 0 || packetTotal != total {
            reset()
            total = packetTotal
        }
        if index != next || index >= total {
            reset()
            return nil
        }
        if buffer.count + fragment.count > maxBytes {
            reset()
            return nil
        }
        buffer.append(fragment)
        next = index + 1
        if next < total { return nil }
        let message = buffer
        reset()
        return message
    }
}
