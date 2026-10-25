import CryptoKit
import Foundation

/// Controlled codec/level experiment on an explicitly labeled public corpus. This is not
/// equivalent to measuring a real watch microphone, room, or unreviewed private speaker label.
@main enum SpeexRoundTrip {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 3 else { throw NSError(domain: "Usage: speex-roundtrip PUBLIC_DIR OUTPUT_DIR", code: 1) }
        let input = URL(fileURLWithPath: args[1]); let output = URL(fileURLWithPath: args[2])
        let original = try JSONSerialization.jsonObject(with: Data(contentsOf: input.appendingPathComponent("manifest.json"))) as! [String: Any]
        for (name, gain, restore) in [("speex", 1.0, 1.0), ("quiet-speex", 0.05, 1.0),
                                      ("quiet-speex-restored", 0.05, 20.0)] {
            let destination = output.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            var manifest = original
            var rows: [[String: Any]] = []
            for var row in original["samples"] as! [[String: Any]] {
                let source = try Data(contentsOf: URL(fileURLWithPath: row["pcmPath"] as! String))
                let samples = source.withUnsafeBytes { bytes in
                    stride(from: 0, to: bytes.count, by: 2).map { index in
                        let value = Int16(bitPattern: UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8)
                        return Int16((Double(value) * gain).rounded())
                    }
                }
                let encoder = try SpeexFrameEncoder()
                var frames: [Data] = []
                for start in stride(from: 0, to: samples.count, by: 320) {
                    var frame = Array(samples[start..<min(start + 320, samples.count)])
                    frame += [Int16](repeating: 0, count: 320 - frame.count)
                    frames.append(try encoder.encodeFrame(frame))
                }
                var decoded = Data(try SpeexFrameDecoder().decodeAll(frames: frames).prefix(source.count))
                if restore != 1 {
                    let scaled: [Int16] = decoded.withUnsafeBytes { bytes in
                        stride(from: 0, to: bytes.count, by: 2).map { index in
                            let value = Int16(bitPattern: UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8)
                            return Int16(clamping: Int((Double(value) * restore).rounded())).littleEndian
                        }
                    }
                    decoded = scaled.withUnsafeBytes { Data($0) }
                }
                let file = destination.appendingPathComponent((row["id"] as! String) + ".pcm")
                try decoded.write(to: file)
                row["pcmPath"] = file.path
                row["condition"] = "controlled-public-" + name
                var evidence = row["evidence"] as! [String: Any]
                evidence["sourceRevision"] = SHA256.hash(data: decoded).map { String(format: "%02x", $0) }.joined()
                row["evidence"] = evidence
                rows.append(row)
            }
            manifest["samples"] = rows
            try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
                .write(to: destination.appendingPathComponent("manifest.json"))
            print("Prepared \(name): \(rows.count) labeled clips")
        }
    }
}
