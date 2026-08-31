import Foundation
import LiveAudio
import SegmentStore
import Transcription

/// The live/foreground-only half: waveform decode, rolling previews, playback, WAV export.
///
/// Everything here is suspended on background entry — a short Core Bluetooth wake must not decode
/// audio for a screen nobody is looking at.
public actor LiveAudioService {
    private let monitor: LiveAudioMonitor?
    private let localLive: LiveTranscriber?
    private let cloudLive: CloudLiveTranscriber?
    private let waveformBuilder: SegmentWaveformBuilder?
    private let exporter: AudioExportManager?
    private let playback: SegmentPlaybackController?
    private let store: SegmentStore
    private let hasDurableTranscript: @Sendable (String) -> Bool
    private let automaticWavExportEnabled: @Sendable () -> Bool
    private let log: RuntimeLog

    private var cloudLiveTask: Task<Void, Never>?

    public init(
        store: SegmentStore,
        monitor: LiveAudioMonitor? = nil,
        localLive: LiveTranscriber? = nil,
        cloudLive: CloudLiveTranscriber? = nil,
        waveformBuilder: SegmentWaveformBuilder? = nil,
        exporter: AudioExportManager? = nil,
        playback: SegmentPlaybackController? = nil,
        hasDurableTranscript: @escaping @Sendable (String) -> Bool,
        automaticWavExportEnabled: @escaping @Sendable () -> Bool,
        log: RuntimeLog = .silent
    ) {
        self.store = store
        self.monitor = monitor
        self.localLive = localLive
        self.cloudLive = cloudLive
        self.waveformBuilder = waveformBuilder
        self.exporter = exporter
        self.playback = playback
        self.hasDurableTranscript = hasDurableTranscript
        self.automaticWavExportEnabled = automaticWavExportEnabled
        self.log = log
    }

    public func start() async {
        guard let cloudLive, cloudLiveTask == nil else { return }
        cloudLiveTask = await cloudLive.start()
    }

    public func stop() {
        cloudLiveTask?.cancel()
        cloudLiveTask = nil
    }

    /// Background entry: stop decoding the waveform. The receive path is untouched.
    public func setForeground(_ value: Bool) async {
        await monitor?.setActive(value)
        await cloudLive?.setForeground(value)
    }

    // --- pipeline steps ------------------------------------------------------------------------

    /// Chunk-based live preview: one chunk, then prune anything the durable transcript
    /// superseded.
    ///
    /// Cost: this path now follows the user's transcription mode, so in a remote mode a chunk
    /// can go to the cloud. While the realtime socket is actually delivering text for the open
    /// segment it owns that audio outright — the chunk path stands down and only advances its
    /// cursor, so the same seconds are never transcribed (or billed) twice, and a takeover after
    /// a socket failure resumes at the handoff instead of re-running the whole segment.
    public func localLivePass() async throws -> Bool {
        guard let localLive else { return false }
        if let streaming = await cloudLive?.deliveringSegmentId(),
            await store.openSegmentId == streaming
        {
            await localLive.markCoveredByOtherSource()
            await localLive.prune(hasFinalTranscript: hasDurableTranscript)
            return false
        }
        let worked = try await localLive.processOnce()
        await localLive.prune(hasFinalTranscript: hasDurableTranscript)
        return worked
    }

    public func cloudLivePrune() async {
        await cloudLive?.prune(hasDurableTranscript: hasDurableTranscript)
    }

    /// True when a segment is open AND a live transcriber follows it — the 5 s pacing case.
    public func isFollowingOpenSegment() async -> Bool {
        guard localLive != nil || cloudLive != nil else { return false }
        return await store.openSegmentId != nil
    }

    public func exportWavIfEnabled() async throws {
        guard let exporter, automaticWavExportEnabled() else { return }
        _ = try await exporter.exportAllClosedSegments(overwrite: false)
    }

    // --- user actions ----------------------------------------------------------------------------

    public func exportSegment(_ segmentId: String) async throws -> AudioExportResult {
        guard let exporter else { return AudioExportResult(directory: "", files: []) }
        return try await exporter.exportSegment(segmentId, overwrite: true)
    }

    public func exportAll() async throws -> AudioExportResult {
        guard let exporter else { return AudioExportResult(directory: "", files: []) }
        return try await exporter.exportAllClosedSegments(overwrite: true)
    }

    /// Stored-segment waveform, decoded off the UI path. The builder wants a synchronous frames
    /// provider but frames live behind the store actor, so they are read first and handed over.
    public func waveform(_ segmentId: String) async -> SegmentWaveform? {
        guard let waveformBuilder, let meta = await store.readMeta(segmentId) else { return nil }
        let frames = await store.readFrames(segmentId)
        return await waveformBuilder.build(meta: meta) { frames }
    }

    public func stopPlayback() {
        playback?.stop()
    }

    public nonisolated var exportDirectory: String? { exporter?.directory }
}
