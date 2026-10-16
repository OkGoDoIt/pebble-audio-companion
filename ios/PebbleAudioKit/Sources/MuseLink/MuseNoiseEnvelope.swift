import Foundation

// The Hatch Noise envelope: HTTP-shaped streams multiplexed inside the Noise session — a port of
// Meta's `linux/src/musegadget/noise/{_proto,envelope,framing}.py` (Apache-2.0). Hand-rolled
// protobuf, five small messages, no dependency.

/// Malformed protobuf or envelope.
public struct MuseProtoError: Error, Equatable, CustomStringConvertible {
    public let description: String
    init(_ description: String) { self.description = description }
}

enum MuseProto {
    static let wireVarint = 0
    static let wireFixed64 = 1
    static let wireDelimited = 2
    static let wireFixed32 = 5

    static func varint(_ value: UInt64) -> Data {
        var value = value
        var out = Data()
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            out.append(byte)
        } while value != 0
        return out
    }

    static func key(_ field: Int, _ wireType: Int) -> Data {
        varint(UInt64(field << 3 | wireType))
    }

    static func varintField(_ field: Int, _ value: UInt64) -> Data {
        key(field, wireVarint) + varint(value)
    }

    /// int64 and int32 both go out as their 64-bit two's complement.
    static func int64Field(_ field: Int, _ value: Int64) -> Data {
        varintField(field, UInt64(bitPattern: value))
    }

    static func boolField(_ field: Int, _ value: Bool) -> Data {
        varintField(field, value ? 1 : 0)
    }

    static func delimitedField(_ field: Int, _ payload: Data) -> Data {
        key(field, wireDelimited) + varint(UInt64(payload.count)) + payload
    }

    static func stringField(_ field: Int, _ value: String) -> Data {
        delimitedField(field, Data(value.utf8))
    }

    /// A cursor over one message's bytes.
    struct Reader {
        let bytes: [UInt8]
        var offset = 0

        init(_ data: Data) { bytes = [UInt8](data) }

        var atEnd: Bool { offset >= bytes.count }

        mutating func readVarint() throws(MuseProtoError) -> UInt64 {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            for index in 0..<10 {
                guard offset < bytes.count else { throw MuseProtoError("truncated varint") }
                let byte = bytes[offset]
                offset += 1
                if index == 9 && byte & 0xFE != 0 { throw MuseProtoError("malformed varint") }
                value |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
            throw MuseProtoError("malformed varint")
        }

        mutating func readKey() throws(MuseProtoError) -> (field: Int, wireType: Int) {
            let key = try readVarint()
            let field = Int(key >> 3)
            let wireType = Int(key & 0x07)
            guard field != 0, field <= (1 << 29) - 1, !(19000...19999).contains(field) else {
                throw MuseProtoError("invalid field number")
            }
            guard [wireVarint, wireFixed64, wireDelimited, wireFixed32].contains(wireType) else {
                throw MuseProtoError("invalid wire type")
            }
            return (field, wireType)
        }

        mutating func readDelimited() throws(MuseProtoError) -> Data {
            let length = try readVarint()
            guard length <= UInt64(bytes.count - offset) else { throw MuseProtoError("truncated delimited field") }
            let end = offset + Int(length)
            defer { offset = end }
            return Data(bytes[offset..<end])
        }

        mutating func readString() throws(MuseProtoError) -> String {
            guard let text = String(data: try readDelimited(), encoding: .utf8) else {
                throw MuseProtoError("invalid utf-8 string")
            }
            return text
        }

        mutating func skip(_ wireType: Int) throws(MuseProtoError) {
            switch wireType {
            case wireVarint: _ = try readVarint()
            case wireDelimited: _ = try readDelimited()
            case wireFixed64, wireFixed32:
                let width = wireType == wireFixed64 ? 8 : 4
                guard offset + width <= bytes.count else { throw MuseProtoError("truncated fixed field") }
                offset += width
            default: throw MuseProtoError("invalid wire type")
            }
        }

        mutating func expect(_ wireType: Int, _ actual: Int, _ name: String) throws(MuseProtoError) {
            guard wireType == actual else { throw MuseProtoError("\(name) wrong wire type") }
        }
    }

    static func int32(_ raw: UInt64) throws(MuseProtoError) -> Int32 {
        let signed = Int64(bitPattern: raw)
        guard let value = Int32(exactly: signed) else { throw MuseProtoError("int32 value out of range") }
        return value
    }
}

public struct MuseHeader: Sendable, Equatable {
    public var key: String
    public var value: String
    public init(_ key: String, _ value: String) {
        self.key = key
        self.value = value
    }

    func encoded() -> Data {
        var out = Data()
        if !key.isEmpty { out += MuseProto.stringField(1, key) }
        if !value.isEmpty { out += MuseProto.stringField(2, value) }
        return out
    }

    static func decode(_ data: Data) throws(MuseProtoError) -> MuseHeader {
        var reader = MuseProto.Reader(data)
        var header = MuseHeader("", "")
        while !reader.atEnd {
            let (field, wire) = try reader.readKey()
            switch field {
            case 1: try reader.expect(MuseProto.wireDelimited, wire, "Header.key"); header.key = try reader.readString()
            case 2: try reader.expect(MuseProto.wireDelimited, wire, "Header.value"); header.value = try reader.readString()
            default: try reader.skip(wire)
            }
        }
        return header
    }
}

/// One frame of a multiplexed stream: the request that opens it, the response that answers it, a
/// later body chunk in either direction, or a reset.
public enum MuseServiceFrameKind: Sendable, Equatable {
    case request(verb: String, path: String, headers: [MuseHeader], body: Data, endBody: Bool)
    case response(status: Int32, headers: [MuseHeader], body: Data, endBody: Bool)
    case bodyChunk(data: Data, endBody: Bool)
    case reset(code: Int32, reason: String)
}

public struct MuseServiceFrame: Sendable, Equatable {
    public var streamID: Int64
    public var kind: MuseServiceFrameKind?

    /// Reset codes, as in the reference's `ResetCode`.
    public static let resetCancelled: Int32 = 1

    func encoded() -> Data {
        var out = Data()
        if streamID != 0 { out += MuseProto.int64Field(1, streamID) }
        switch kind {
        case .none: break
        case .request(let verb, let path, let headers, let body, let endBody)?:
            var inner = Data()
            if !verb.isEmpty { inner += MuseProto.stringField(1, verb) }
            if !path.isEmpty { inner += MuseProto.stringField(2, path) }
            for header in headers { inner += MuseProto.delimitedField(3, header.encoded()) }
            if !body.isEmpty { inner += MuseProto.delimitedField(4, body) }
            if endBody { inner += MuseProto.boolField(5, true) }
            out += MuseProto.delimitedField(2, inner)
        case .response(let status, let headers, let body, let endBody)?:
            var inner = Data()
            if status != 0 { inner += MuseProto.int64Field(1, Int64(status)) }
            for header in headers { inner += MuseProto.delimitedField(2, header.encoded()) }
            if !body.isEmpty { inner += MuseProto.delimitedField(3, body) }
            if endBody { inner += MuseProto.boolField(4, true) }
            out += MuseProto.delimitedField(3, inner)
        case .bodyChunk(let data, let endBody)?:
            var inner = Data()
            if !data.isEmpty { inner += MuseProto.delimitedField(1, data) }
            if endBody { inner += MuseProto.boolField(2, true) }
            out += MuseProto.delimitedField(4, inner)
        case .reset(let code, let reason)?:
            var inner = Data()
            if code != 0 { inner += MuseProto.int64Field(1, Int64(code)) }
            if !reason.isEmpty { inner += MuseProto.stringField(2, reason) }
            out += MuseProto.delimitedField(5, inner)
        }
        return out
    }

    static func decode(_ data: Data) throws(MuseProtoError) -> MuseServiceFrame {
        var reader = MuseProto.Reader(data)
        var frame = MuseServiceFrame(streamID: 0, kind: nil)
        while !reader.atEnd {
            let (field, wire) = try reader.readKey()
            switch field {
            case 1:
                try reader.expect(MuseProto.wireVarint, wire, "ServiceFrame.stream_id")
                frame.streamID = Int64(bitPattern: try reader.readVarint())
            case 2:
                try reader.expect(MuseProto.wireDelimited, wire, "ServiceFrame.request")
                frame.kind = try decodeRequest(try reader.readDelimited())
            case 3:
                try reader.expect(MuseProto.wireDelimited, wire, "ServiceFrame.response")
                frame.kind = try decodeResponse(try reader.readDelimited())
            case 4:
                try reader.expect(MuseProto.wireDelimited, wire, "ServiceFrame.body_chunk")
                frame.kind = try decodeBodyChunk(try reader.readDelimited())
            case 5:
                try reader.expect(MuseProto.wireDelimited, wire, "ServiceFrame.reset")
                frame.kind = try decodeReset(try reader.readDelimited())
            default: try reader.skip(wire)
            }
        }
        return frame
    }

    private static func decodeRequest(_ data: Data) throws(MuseProtoError) -> MuseServiceFrameKind {
        var reader = MuseProto.Reader(data)
        var verb = "", path = "", headers: [MuseHeader] = [], body = Data(), endBody = false
        while !reader.atEnd {
            let (field, wire) = try reader.readKey()
            switch field {
            case 1: try reader.expect(MuseProto.wireDelimited, wire, "verb"); verb = try reader.readString()
            case 2: try reader.expect(MuseProto.wireDelimited, wire, "path"); path = try reader.readString()
            case 3: try reader.expect(MuseProto.wireDelimited, wire, "headers"); headers.append(try MuseHeader.decode(try reader.readDelimited()))
            case 4: try reader.expect(MuseProto.wireDelimited, wire, "body"); body = try reader.readDelimited()
            case 5: try reader.expect(MuseProto.wireVarint, wire, "end_body"); endBody = try reader.readVarint() != 0
            default: try reader.skip(wire)
            }
        }
        return .request(verb: verb, path: path, headers: headers, body: body, endBody: endBody)
    }

    private static func decodeResponse(_ data: Data) throws(MuseProtoError) -> MuseServiceFrameKind {
        var reader = MuseProto.Reader(data)
        var status: Int32 = 0, headers: [MuseHeader] = [], body = Data(), endBody = false
        while !reader.atEnd {
            let (field, wire) = try reader.readKey()
            switch field {
            case 1: try reader.expect(MuseProto.wireVarint, wire, "status"); status = try MuseProto.int32(try reader.readVarint())
            case 2: try reader.expect(MuseProto.wireDelimited, wire, "headers"); headers.append(try MuseHeader.decode(try reader.readDelimited()))
            case 3: try reader.expect(MuseProto.wireDelimited, wire, "body"); body = try reader.readDelimited()
            case 4: try reader.expect(MuseProto.wireVarint, wire, "end_body"); endBody = try reader.readVarint() != 0
            default: try reader.skip(wire)
            }
        }
        return .response(status: status, headers: headers, body: body, endBody: endBody)
    }

    private static func decodeBodyChunk(_ data: Data) throws(MuseProtoError) -> MuseServiceFrameKind {
        var reader = MuseProto.Reader(data)
        var chunk = Data(), endBody = false
        while !reader.atEnd {
            let (field, wire) = try reader.readKey()
            switch field {
            case 1: try reader.expect(MuseProto.wireDelimited, wire, "data"); chunk = try reader.readDelimited()
            case 2: try reader.expect(MuseProto.wireVarint, wire, "end_body"); endBody = try reader.readVarint() != 0
            default: try reader.skip(wire)
            }
        }
        return .bodyChunk(data: chunk, endBody: endBody)
    }

    private static func decodeReset(_ data: Data) throws(MuseProtoError) -> MuseServiceFrameKind {
        var reader = MuseProto.Reader(data)
        var code: Int32 = 0, reason = ""
        while !reader.atEnd {
            let (field, wire) = try reader.readKey()
            switch field {
            case 1:
                try reader.expect(MuseProto.wireVarint, wire, "code")
                code = try MuseProto.int32(try reader.readVarint())
                guard (0...6).contains(code) else { throw MuseProtoError("unknown reset code") }
            case 2: try reader.expect(MuseProto.wireDelimited, wire, "reason"); reason = try reader.readString()
            default: try reader.skip(wire)
            }
        }
        return .reset(code: code, reason: reason)
    }
}

/// `ServiceRequest{1: service enum, 2: payload}` (device → VM) and `ServiceResponse{1: payload}`
/// (VM → device). The gadget only ever talks to service 0, the daemon.
enum MuseServiceEnvelope {
    static func encodeRequest(service: UInt64 = 0, payload: Data) -> Data {
        var out = Data()
        if service != 0 { out += MuseProto.varintField(1, service) }
        if !payload.isEmpty { out += MuseProto.delimitedField(2, payload) }
        return out
    }

    static func decodeRequestPayload(_ data: Data) throws(MuseProtoError) -> Data {
        var reader = MuseProto.Reader(data)
        var payload = Data()
        while !reader.atEnd {
            let (field, wire) = try reader.readKey()
            switch field {
            case 1:
                try reader.expect(MuseProto.wireVarint, wire, "ServiceRequest.service")
                guard try reader.readVarint() <= 3 else { throw MuseProtoError("unknown service type") }
            case 2: try reader.expect(MuseProto.wireDelimited, wire, "ServiceRequest.payload"); payload = try reader.readDelimited()
            default: try reader.skip(wire)
            }
        }
        return payload
    }

    static func encodeResponse(payload: Data) -> Data {
        payload.isEmpty ? Data() : MuseProto.delimitedField(1, payload)
    }

    static func decodeResponsePayload(_ data: Data) throws(MuseProtoError) -> Data {
        var reader = MuseProto.Reader(data)
        var payload = Data()
        while !reader.atEnd {
            let (field, wire) = try reader.readKey()
            if field == 1 {
                try reader.expect(MuseProto.wireDelimited, wire, "ServiceResponse.payload")
                payload = try reader.readDelimited()
            } else {
                try reader.skip(wire)
            }
        }
        return payload
    }
}

/// `NoiseTransportFrame{1: int64 chunk_id, 2: u32 index, 3: u32 total, 4: bytes}`: splits one
/// envelope across WebSocket messages of at most 65,489 payload bytes each.
enum MuseNoiseFraming {
    static let maxChunkPayload = 65489
    static let maxTotalChunks = 256
    static let maxAssemblyBytes = 16 * 1024 * 1024
    static let maxPendingAssemblies = 16
    static let assemblyTTL: TimeInterval = 60

    static func encode(_ payload: Data, chunkID: Int64 = Int64.random(in: Int64.min...Int64.max)) throws(MuseProtoError) -> [Data] {
        let total = max(1, (payload.count + maxChunkPayload - 1) / maxChunkPayload)
        guard total <= maxTotalChunks else { throw MuseProtoError("payload too large for noise framing") }
        return (0..<total).map { index in
            let start = payload.startIndex + index * maxChunkPayload
            let chunk = payload.subdata(in: start..<min(start + maxChunkPayload, payload.endIndex))
            var out = Data()
            if chunkID != 0 { out += MuseProto.int64Field(1, chunkID) }
            if index != 0 { out += MuseProto.varintField(2, UInt64(index)) }
            out += MuseProto.varintField(3, UInt64(total))
            if !chunk.isEmpty { out += MuseProto.delimitedField(4, chunk) }
            return out
        }
    }

    struct Decoder {
        private struct Assembly {
            var chunks: [Int: Data] = [:]
            let total: Int
            var bytes = 0
            let createdAt: Date
        }

        private var pending: [Int64: Assembly] = [:]

        /// The reassembled payload once its last chunk arrives; `nil` while chunks are missing.
        mutating func decode(_ frame: Data) throws(MuseProtoError) -> Data? {
            var reader = MuseProto.Reader(frame)
            var chunkID: Int64 = 0, index = 0, total = 1, payload = Data()
            while !reader.atEnd {
                let (field, wire) = try reader.readKey()
                switch field {
                case 1: try reader.expect(MuseProto.wireVarint, wire, "chunk_id"); chunkID = Int64(bitPattern: try reader.readVarint())
                case 2:
                    try reader.expect(MuseProto.wireVarint, wire, "chunk_index")
                    let raw = try reader.readVarint()
                    guard raw <= UInt64(UInt32.max) else { throw MuseProtoError("uint32 value out of range") }
                    index = Int(raw)
                case 3:
                    try reader.expect(MuseProto.wireVarint, wire, "total_chunks")
                    let raw = try reader.readVarint()
                    guard raw <= UInt64(UInt32.max) else { throw MuseProtoError("uint32 value out of range") }
                    total = Int(raw)
                case 4: try reader.expect(MuseProto.wireDelimited, wire, "payload"); payload = try reader.readDelimited()
                default: try reader.skip(wire)
                }
            }
            guard (1...maxTotalChunks).contains(total) else { throw MuseProtoError("invalid totalChunks") }
            guard index < total else { throw MuseProtoError("chunkIndex out of range") }
            guard payload.count <= maxChunkPayload else { throw MuseProtoError("noise frame payload too large") }
            let now = Date()
            pending = pending.filter { now.timeIntervalSince($0.value.createdAt) <= assemblyTTL }
            var assembly: Assembly
            if let existing = pending[chunkID] {
                assembly = existing
            } else {
                guard pending.count < maxPendingAssemblies else { throw MuseProtoError("too many pending assemblies") }
                assembly = Assembly(total: total, createdAt: now)
            }
            guard assembly.total == total else { throw MuseProtoError("inconsistent totalChunks") }
            guard assembly.chunks[index] == nil else { throw MuseProtoError("duplicate chunkIndex") }
            assembly.bytes += payload.count
            guard assembly.bytes <= maxAssemblyBytes else { throw MuseProtoError("assembly exceeded byte budget") }
            assembly.chunks[index] = payload
            guard assembly.chunks.count == assembly.total else {
                pending[chunkID] = assembly
                return nil
            }
            pending[chunkID] = nil
            return (0..<assembly.total).reduce(into: Data()) { $0.append(assembly.chunks[$1]!) }
        }
    }
}
