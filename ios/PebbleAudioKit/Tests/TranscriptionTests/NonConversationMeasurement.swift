import AudioCodec
import Foundation
import SegmentStore
import Testing

#if canImport(SoundAnalysis)
    import AVFoundation
    import SoundAnalysis
#endif

// A MEASUREMENT, not a unit test: the raw per-window evidence for telling conversation from
// audio that is loud but holds none (music, TV, a café, a fan, stray words). It runs only when
// `PEBBLE_NONCONV_ROOTS` names one or more app-container backups (colon-separated, the newest
// LAST so its copy of a segment wins) and `PEBBLE_NONCONV_OUT` names a directory OUTSIDE the
// repo, and it only writes files there. Nothing it produces may be committed: the outputs are
// derived from private recordings.
//
// What it writes, per segment that has both audio and a transcript (plus any segment id listed
// in the optional `PEBBLE_NONCONV_EXTRA` file, e.g. NoSpeech verdicts whose audio survives):
// - `levels/<id>.u16`: RMS of every 100 ms bucket of the decoded audio, little-endian UInt16,
//   on the same decoded (media) timeline the transcript's timings are on.
// - `sound/<id>.u8`: Apple's built-in sound classifier (`SNClassifierIdentifier.version1`)
//   over the same audio, one record per classifier window: UInt32 media start ms, then one
//   byte (score x 255) per class in `sound/classes.txt` order.
// - `index.jsonl`: which root each segment came from, its audio length, and the decode and
//   classifier cost, so a phone budget can be estimated before anything is deployed.
//
// Decoding is exactly `TranscriptionProcessor.segmentPcmSource`'s: frames in stream order
// through a fresh Speex decoder. Already-written segments are skipped, so a run can resume.
@Suite struct NonConversationMeasurement {
    private struct Job: Sendable {
        let segmentId: String
        let root: URL
    }

    private struct IndexLine: Encodable {
        let segmentId: String
        let root: String
        let audioMs: Int64
        let decodeMs: Double
        let classifyMs: Double
        let classifierWindows: Int
    }

    @Test func dumpWindowEvidence() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let rootsRaw = env["PEBBLE_NONCONV_ROOTS"], let outPath = env["PEBBLE_NONCONV_OUT"]
        else { return }
        let roots = rootsRaw.split(separator: ":").map {
            URL(fileURLWithPath: String($0), isDirectory: true)
        }
        let out = URL(fileURLWithPath: outPath, isDirectory: true)
        let fm = FileManager.default
        for sub in ["levels", "sound"] {
            try fm.createDirectory(
                at: out.appendingPathComponent(sub), withIntermediateDirectories: true)
        }

        // Newest root last wins: the same segment in two backups is the same audio, but the
        // later transcript may be a retranscription.
        var chosen: [String: URL] = [:]
        for root in roots {
            let dir = root.appendingPathComponent("transcription/transcripts")
            let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            for name in names where name.hasSuffix(".transcript.json") {
                let id = String(name.dropLast(".transcript.json".count))
                let log = root.appendingPathComponent("segments/\(id).spxlog")
                if fm.fileExists(atPath: log.path) { chosen[id] = root }
            }
        }
        if let extraPath = env["PEBBLE_NONCONV_EXTRA"],
            let extra = try? String(contentsOfFile: extraPath, encoding: .utf8)
        {
            for id in extra.split(whereSeparator: \.isNewline).map(String.init) where !id.isEmpty {
                for root in roots
                where fm.fileExists(atPath: root.appendingPathComponent("segments/\(id).spxlog").path)
                {
                    chosen[id] = root
                }
            }
        }
        var jobs = chosen.map { Job(segmentId: $0.key, root: $0.value) }
            .sorted { $0.segmentId < $1.segmentId }
            .filter {
                !fm.fileExists(atPath: out.appendingPathComponent("sound/\($0.segmentId).u8").path)
            }
        if let limit = env["PEBBLE_NONCONV_LIMIT"].flatMap(Int.init) {
            jobs = Array(jobs.prefix(limit))
        }
        print("non-conversation evidence: \(chosen.count) segments, \(jobs.count) still to do")

        #if canImport(SoundAnalysis)
            let classes = try SNClassifySoundRequest(classifierIdentifier: .version1)
                .knownClassifications
            try classes.joined(separator: "\n").write(
                to: out.appendingPathComponent("sound/classes.txt"), atomically: true,
                encoding: .utf8)
            let overlap = env["PEBBLE_NONCONV_OVERLAP"].flatMap(Double.init) ?? 0
            let width = env["PEBBLE_NONCONV_WIDTH"].flatMap(Int.init)
                ?? max(1, ProcessInfo.processInfo.activeProcessorCount - 2)

            let indexURL = out.appendingPathComponent("index.jsonl")
            if !fm.fileExists(atPath: indexURL.path) {
                fm.createFile(atPath: indexURL.path, contents: nil)
            }
            let index = try FileHandle(forWritingTo: indexURL)
            defer { try? index.close() }
            try index.seekToEnd()

            var done = 0
            try await withThrowingTaskGroup(of: IndexLine?.self) { group in
                var next = 0
                func enqueue() {
                    guard next < jobs.count else { return }
                    let job = jobs[next]
                    next += 1
                    group.addTask {
                        try Self.process(job, classes: classes, overlap: overlap, out: out)
                    }
                }
                for _ in 0..<width { enqueue() }
                while let line = try await group.next() {
                    if let line {
                        var data = try JSONEncoder().encode(line)
                        data.append(0x0A)
                        try index.write(contentsOf: data)
                    }
                    done += 1
                    if done % 50 == 0 { print("  \(done)/\(jobs.count)") }
                    enqueue()
                }
            }
            print("non-conversation evidence: wrote \(done) segments to \(out.path)")
        #else
            print("SoundAnalysis unavailable on this platform; nothing written")
        #endif
    }

    #if canImport(SoundAnalysis)
        private final class Collector: NSObject, SNResultsObserving, @unchecked Sendable {
            let classes: [String]
            var records = Data()
            var windows = 0
            var failure: Error?

            init(classes: [String]) { self.classes = classes }

            func request(_ request: SNRequest, didProduce result: SNResult) {
                guard let result = result as? SNClassificationResult else { return }
                let startMs = UInt32(max(0, result.timeRange.start.seconds * 1000).rounded())
                withUnsafeBytes(of: startMs.littleEndian) { records.append(contentsOf: $0) }
                var row = [UInt8](repeating: 0, count: classes.count)
                for (i, name) in classes.enumerated() {
                    let score = result.classification(forIdentifier: name)?.confidence ?? 0
                    row[i] = UInt8(max(0, min(255, (score * 255).rounded())))
                }
                records.append(contentsOf: row)
                windows += 1
            }

            func request(_ request: SNRequest, didFailWithError error: Error) { failure = error }
        }

        private static func process(
            _ job: Job, classes: [String], overlap: Double, out: URL
        ) throws -> IndexLine? {
            let reader = SegmentFileReader(root: job.root)
            guard let meta = reader.readMeta(job.segmentId) else { return nil }
            let frames = reader.readFrames(job.segmentId)
            guard !frames.isEmpty else { return nil }
            let rate = Int(meta.sampleRateHz)

            let decodeStart = DispatchTime.now()
            let decoder = SpeexFrameDecoder(
                sampleRateHz: rate, bitRateBps: Int(meta.bitRateBps),
                frameSamples: meta.frameSamples)
            let pcm = try decoder.decodeAll(frames: frames.map { Data($0.payload) })
            let decodeMs = Double(DispatchTime.now().uptimeNanoseconds - decodeStart.uptimeNanoseconds) / 1e6

            // Levels: the same 100 ms buckets as `SegmentEnergyMeter`, kept as a series.
            let samples: [Int16] = pcm.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
            let perBucket = max(1, rate / 10)
            var levels = Data(capacity: samples.count / perBucket * 2)
            var i = 0
            while i + perBucket <= samples.count {
                var sum = 0.0
                for s in samples[i..<(i + perBucket)] {
                    let v = Double(s)
                    sum += v * v
                }
                let rms = UInt16(min(65_535, (sum / Double(perBucket)).squareRoot().rounded()))
                withUnsafeBytes(of: rms.littleEndian) { levels.append(contentsOf: $0) }
                i += perBucket
            }
            try levels.write(to: out.appendingPathComponent("levels/\(job.segmentId).u16"))

            // Sound classes over the whole segment. (In the app this would run only on candidate
            // stretches; here every window is kept so candidates can be chosen afterwards.)
            let classifyStart = DispatchTime.now()
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: Double(rate), channels: 1,
                interleaved: false)!
            let analyzer = SNAudioStreamAnalyzer(format: format)
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            request.overlapFactor = overlap
            let collector = Collector(classes: classes)
            try analyzer.add(request, withObserver: collector)
            let chunk = rate
            var position: AVAudioFramePosition = 0
            var start = 0
            while start < samples.count {
                let count = min(chunk, samples.count - start)
                let buffer = AVAudioPCMBuffer(
                    pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
                buffer.frameLength = AVAudioFrameCount(count)
                let dst = buffer.floatChannelData![0]
                for k in 0..<count { dst[k] = Float(samples[start + k]) / 32_768 }
                analyzer.analyze(buffer, atAudioFramePosition: position)
                position += AVAudioFramePosition(count)
                start += count
            }
            analyzer.completeAnalysis()
            let classifyMs = Double(DispatchTime.now().uptimeNanoseconds - classifyStart.uptimeNanoseconds) / 1e6
            if let failure = collector.failure { throw failure }
            try collector.records.write(to: out.appendingPathComponent("sound/\(job.segmentId).u8"))

            return IndexLine(
                segmentId: job.segmentId, root: job.root.path,
                audioMs: Int64(samples.count) * 1000 / Int64(max(rate, 1)),
                decodeMs: decodeMs, classifyMs: classifyMs,
                classifierWindows: collector.windows)
        }
    #endif
}
