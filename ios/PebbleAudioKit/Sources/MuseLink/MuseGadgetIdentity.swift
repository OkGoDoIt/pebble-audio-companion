import Foundation

/// A Muse gadget's stable identity, as Meta's Linux gadget SDK defines it
/// (`linux/src/musegadget/identity.py`): a random, locally administered MAC-shaped value
/// generated once. Nothing about it is tied to hardware — it is not the watch's or the phone's
/// Bluetooth address — so the same identity can be used wherever the gadget's link runs.
///
/// The derived names must keep Meta's exact shapes. The Muse app compares the text after
/// `MuseGadget` in the BLE name with the text after `homelink-` in the node id.
public struct MuseGadgetIdentity: Sendable, Equatable, Codable {
    public static let nodeIDPrefix = "homelink-"
    public static let bleNamePrefix = "MuseGadget"

    /// Lowercase `xx:xx:xx:xx:xx:xx`, locally administered unicast.
    public let mac: String

    public init?(mac: String) {
        guard Self.isValidMAC(mac) else { return nil }
        self.mac = mac
    }

    /// The last six hex digits of the MAC, lowercase.
    public var suffix: String { String(mac.replacingOccurrences(of: ":", with: "").suffix(6)) }
    public var nodeID: String { Self.nodeIDPrefix + suffix }
    public var deviceID: String { "hatch-link:" + mac }
    /// No separator: Meta's Linux SDK writes `MuseGadgetA1B2C3`. (Its ESP32 firmware uses a hyphen;
    /// the Linux shape is the one a non-ESP32 gadget is told to copy.)
    public var bleName: String { Self.bleNamePrefix + suffix.uppercased() }

    public static func generate() -> MuseGadgetIdentity {
        var generator = SystemRandomNumberGenerator()
        return generate(using: &generator)
    }

    public static func generate<G: RandomNumberGenerator>(using generator: inout G) -> MuseGadgetIdentity {
        var octets = (0..<6).map { _ in UInt8.random(in: 0...255, using: &generator) }
        octets[0] = (octets[0] & 0xFC) | 0x02  // unicast, locally administered
        let mac = octets.map { String(format: "%02x", $0) }.joined(separator: ":")
        return MuseGadgetIdentity(mac: mac)!
    }

    static func isValidMAC(_ mac: String) -> Bool {
        let parts = mac.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count == 6 && parts.allSatisfy { part in
            part.count == 2 && part.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let mac = try container.decode(String.self, forKey: .mac)
        guard Self.isValidMAC(mac) else {
            throw DecodingError.dataCorruptedError(
                forKey: .mac, in: container, debugDescription: "not a lowercase MAC")
        }
        self.mac = mac
    }
}
