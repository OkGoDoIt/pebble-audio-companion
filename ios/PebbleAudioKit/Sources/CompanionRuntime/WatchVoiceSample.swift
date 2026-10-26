import AudioCodec
import Foundation
import SegmentStore

/// The microphone a deliberately recorded voice sample came through. Recognition runs on the
/// watch's audio, so a sample recorded through the watch matches it most closely; the phone
/// microphone is a second, different view of the same voice.
public enum VoiceSampleMicrophone: String, Sendable, CaseIterable {
    case phone, watch

    /// Detached sample sources: the audio is copied out of its recording (or never stored),
    /// so deleting or growing a recording never silently removes the sample.
    var sourcePrefix: String { self == .phone ? "enrollment:" : "watch-enrollment:" }

    public static func of(segmentId: String) -> VoiceSampleMicrophone {
        segmentId.hasPrefix(VoiceSampleMicrophone.phone.sourcePrefix) ? .phone : .watch
    }
}

/// Speech the watch captured between two phone-clock instants.
public struct WatchVoiceSampleAudio: Equatable, Sendable {
    public let pcm16LE: Data
    /// How far the watch's audio had reached when this was read, so a caller can tell whether
    /// the window's last seconds are still on their way over Bluetooth.
    public let receivedThroughWallMs: Int64
    public var seconds: Double { Double(pcm16LE.count) / 32_000 }
    public init(pcm16LE: Data, receivedThroughWallMs: Int64) {
        self.pcm16LE = pcm16LE
        self.receivedThroughWallMs = receivedThroughWallMs
    }
}

/// Reads the watch's own audio for a voice sample the person is recording right now. The
/// recording it lands in is usually still open, so the frames are decoded and copied rather
/// than referenced: an open recording's content (and so its revision) changes until it closes.
public struct WatchVoiceSampleReader: Sendable {
    let files: SegmentFileReader
    public init(files: SegmentFileReader) { self.files = files }

    /// Decoded audio recorded between the two instants. Each continuous run is decoded on its
    /// own (codec state never spans a quiet stretch the watch skipped) and the runs are joined.
    /// Nil when nothing from that window or after it is on the phone yet.
    public func audio(fromWallMs start: Int64, toWallMs end: Int64) throws -> WatchVoiceSampleAudio? {
        guard end > start else { return nil }
        var pcm = Data()
        var received: Int64?
        for meta in recentMetas(since: start - 60_000).sorted(by: { $0.startWallMs < $1.startWallMs }) {
            // An open recording's sidecar trails its frames by up to a flush interval, so its
            // frames are read whatever the sidecar says about how far they reach.
            guard meta.sampleRateHz == 16_000, meta.channels == 1, meta.frameSamples == 320,
                  meta.startWallMs < end, meta.isOpen || (Self.endWallMs(meta) ?? .min) > start else { continue }
            let all = files.readFrames(meta.segmentId)
            if let last = all.last {
                let reach = Self.wallMs(ofSample: last.sampleIndex &+ UInt64(meta.frameSamples), in: meta)
                received = max(received ?? reach, reach)
            }
            let frames = all.filter {
                let wall = Self.wallMs(ofSample: $0.sampleIndex, in: meta)
                return wall >= start && wall + Int64(meta.frameDurationMs) <= end
            }
            var run: [FrameRecord] = []
            func flush() throws {
                defer { run.removeAll() }
                // Under half a second is a fragment around a skipped quiet stretch, not speech.
                guard run.count >= 25 else { return }
                pcm.append(try SpeexFrameDecoder(sampleRateHz: Int(meta.sampleRateHz),
                    bitRateBps: Int(meta.bitRateBps), frameSamples: meta.frameSamples)
                    .decodeAll(frames: run.map { Data($0.payload) }))
            }
            for frame in frames {
                if let last = run.last, frame.sequence != last.sequence &+ 1
                    || frame.sampleIndex != last.sampleIndex &+ UInt64(meta.frameSamples) {
                    try flush()
                }
                run.append(frame)
            }
            try flush()
        }
        guard let received else { return nil }
        return WatchVoiceSampleAudio(pcm16LE: pcm, receivedThroughWallMs: received)
    }

    static func wallMs(ofSample index: UInt64, in meta: SegmentMeta) -> Int64 {
        meta.sampleClockAnchorMs + Int64(index * 1_000 / UInt64(max(meta.sampleRateHz, 1)))
    }

    static func endWallMs(_ meta: SegmentMeta) -> Int64? {
        meta.lastSampleIndexExclusive.map { wallMs(ofSample: $0, in: meta) }
    }

    /// Only sidecars written recently: the open recording and any that closed in the window.
    /// Decoding every sidecar in a large library on each poll would cost far more than this.
    private func recentMetas(since wallMs: Int64) -> [SegmentMeta] {
        let directory = files.root.appendingPathComponent("segments", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let cutoff = Date(timeIntervalSince1970: Double(wallMs) / 1_000)
        return entries.compactMap { url in
            guard url.lastPathComponent.hasSuffix(SegmentStore.metaSuffix),
                  let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  modified >= cutoff else { return nil }
            return files.readMeta(String(url.lastPathComponent.dropLast(SegmentStore.metaSuffix.count)))
        }
    }
}
