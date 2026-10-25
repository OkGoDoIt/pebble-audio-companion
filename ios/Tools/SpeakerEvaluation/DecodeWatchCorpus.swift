import Foundation

/// Uses the app's exact fixed-point decoder. Read-only backup input; new files go to a distinct
/// output directory. Rejects crops crossing any sample-counter/sequence discontinuity.
@main enum DecodeWatchCorpus {
    struct Request: Codable {
        let id: String
        let segmentID: String
        let startSample: Int
        let endSample: Int
    }
    struct Record { let sequence: UInt32; let sample: UInt64; let payload: Data }
    struct Result: Codable { let id: String; let pcmPath: String?; let error: String? }
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 4 else { throw NSError(domain: "Usage: decode-watch BACKUP REQUESTS.json OUTPUT_DIR", code: 1) }
        let backup = URL(fileURLWithPath: args[1]).resolvingSymlinksInPath()
        let output = URL(fileURLWithPath: args[3]).resolvingSymlinksInPath()
        guard !output.path.hasPrefix(backup.path + "/"), output != backup else {
            throw NSError(domain: "Output must be outside the backup", code: 1)
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let requests = try JSONDecoder().decode([Request].self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
        var results: [Result] = []
        for (segmentID, group) in Dictionary(grouping: requests, by: \.segmentID).sorted(by: { $0.key < $1.key }) {
            guard segmentID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else {
                throw NSError(domain: "Invalid segment ID", code: 1)
            }
            let log = try Data(contentsOf: backup.appendingPathComponent("segments/\(segmentID).spxlog"))
            var records: [Record] = []
            var offset = 0
            while offset + 14 <= log.count {
                func uint(_ at: Int, _ size: Int) -> UInt64 {
                    (0..<size).reduce(0) { $0 | UInt64(log[at + $1]) << ($1 * 8) }
                }
                let length = Int(uint(offset + 12, 2))
                guard length > 0, length <= 2_048, offset + 14 + length <= log.count else {
                    throw NSError(domain: "Malformed Speex record", code: 1)
                }
                records.append(Record(sequence: UInt32(uint(offset, 4)), sample: uint(offset + 4, 8),
                    payload: log.subdata(in: (offset + 14)..<(offset + 14 + length))))
                offset += 14 + length
            }
            guard offset == log.count else { throw NSError(domain: "Truncated Speex log", code: 1) }
            records.sort { $0.sequence < $1.sequence }
            var seen = Set<UInt32>()
            records = records.filter { seen.insert($0.sequence).inserted }
            var discontinuities: [Int] = []
            for i in records.indices.dropFirst() {
                if records[i].sequence != records[i - 1].sequence &+ 1 || records[i].sample != records[i - 1].sample + 320 {
                    discontinuities.append(i * 320)
                }
            }
            let pcm = try SpeexFrameDecoder().decodeAll(frames: records.map(\.payload))
            for request in group {
                guard request.id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }),
                      request.startSample >= 0, request.endSample > request.startSample,
                      request.endSample <= pcm.count / 2,
                      !discontinuities.contains(where: { $0 > request.startSample && $0 < request.endSample }) else {
                    results.append(Result(id: request.id, pcmPath: nil, error: "Invalid range or capture discontinuity")); continue
                }
                let file = output.appendingPathComponent(request.id + ".pcm")
                try pcm.subdata(in: (request.startSample * 2)..<(request.endSample * 2)).write(to: file, options: .atomic)
                results.append(Result(id: request.id, pcmPath: file.path, error: nil))
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(results), as: UTF8.self))
    }
}
