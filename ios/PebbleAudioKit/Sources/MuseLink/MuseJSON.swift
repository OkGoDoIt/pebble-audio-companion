import Foundation

/// A JSON value, for the gadget protocol's loosely typed messages.
///
/// The Muse wire messages are small JSON objects whose fields vary by `type`/`action`, and the
/// reference implementation (Meta's `linux/src/musegadget`, Apache-2.0) validates them field by
/// field. Decoding them into fixed `Codable` structs would turn "a field has the wrong type" into a
/// whole-message decode failure with no way to answer with the right error status, so messages
/// are decoded into this and read field by field instead. `Bool` is distinct from `number`, as the
/// reference rejects `true` where it expects a version number.
public enum MuseJSON: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([MuseJSON])
    case object([String: MuseJSON])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([MuseJSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: MuseJSON].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            // Integral values go out without a fraction ("5", not "5.0"), as Python's json does.
            if value.rounded() == value, abs(value) < 9.0e15 {
                try container.encode(Int64(value))
            } else {
                try container.encode(value)
            }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public subscript(key: String) -> MuseJSON? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var number: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    public var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var object: [String: MuseJSON]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var array: [MuseJSON]? {
        if case .array(let value) = self { return value }
        return nil
    }

    /// Parses UTF-8 JSON; `nil` for anything that isn't valid JSON.
    public static func parse(_ data: Data) -> MuseJSON? {
        try? JSONDecoder().decode(MuseJSON.self, from: data)
    }

    /// Compact UTF-8 JSON (no whitespace, slashes unescaped, keys sorted so output is stable).
    public func compactData() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Encoding a value built from these cases cannot fail.
        return (try? encoder.encode(self)) ?? Data("null".utf8)
    }

    public func compactString() -> String {
        String(decoding: compactData(), as: UTF8.self)
    }
}

extension MuseJSON: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByIntegerLiteral, ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(dictionaryLiteral elements: (String, MuseJSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    public init(arrayLiteral elements: MuseJSON...) { self = .array(elements) }
}
