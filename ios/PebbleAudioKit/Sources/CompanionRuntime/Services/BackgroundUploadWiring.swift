import AudioCodec
import Foundation
import SegmentStore
import Transcription

// The composition of the suspension-proof cloud upload path (plan Part 4.4 "Background upload
// (iOS)" + Part 4.6's lifecycle bullets). The port of
// `IosAudioCompanionRuntimeFactory.kt`'s `uploadCoordinator` block.
//
// It lives in the kit rather than in the app's composition root for one reason: the decision this
// code makes — whether a segment's audio is uploaded to a cloud provider while the user is not
// looking — has to be provable by tests. Building it here means the tests exercise the SAME
// construction the app ships, instead of a hand-rolled look-alike.

/// How a queue task's state is mirrored onto the segment's own metadata.
///
/// LOAD-BEARING, not cosmetic: `TranscriptionService.enqueueClosedSegments` selects segments by
/// `!isFullyTranscribed` (i.e. this field), and the processor requeues any selected segment whose
/// task is already terminal — that is how a reattached segment gets re-transcribed. Leave the
/// mirror unwired and every finished segment is requeued on every pipeline pass, which for a
/// cloud-primary user means re-uploading the same audio and paying for the same transcript
/// forever.
public func segmentTranscriptionState(for state: TaskState) -> TranscriptionState {
    switch state {
    case .pending: return .pending
    case .running: return .running
    case .uploading: return .uploading
    case .complete: return .complete
    case .noSpeech: return .noSpeech
    case .failed: return .failed
    case .disabled: return .disabled
    }
}

public enum BackgroundUploadWiring {
    /// The background `URLSession` identifier.
    ///
    /// DELIBERATELY different from the KMP app's `dev.audiocompanion.app.transcription-upload`
    /// (plan Part 4.8: "Use a NEW background-session identifier"). The release build installs
    /// OVER the old app and inherits its container, so reusing the identifier would have this app
    /// adopt the dead app's still-queued upload tasks: bodies we never assembled, replayed as
    /// outcomes for job ids no job record here matches. Two apps sharing one background-session
    /// identifier is a real conflict, not a theoretical one.
    public static let sessionIdentifier = "dev.audiocompanion.app.swift-transcription-upload"

    /// `<root>/upload-bodies/` — the pre-assembled multipart bodies the transport uploads from.
    public static func bodyDir(root: URL) -> URL {
        BackgroundCloudUploadCoordinator.defaultBodyDir(root: root)
    }

    /// Segment id → the WAV the cloud provider is asked to transcribe.
    ///
    /// Reads through the SYNCHRONOUS spool reader (like the live/export seams) so assembling a
    /// body never hops the store actor while the app is being suspended. Returns nil for a
    /// segment with no metadata or no audio — the coordinator then skips it rather than uploading
    /// an empty file.
    public static func audioSource(
        files: SegmentFileReader
    ) -> @Sendable (_ segmentId: String) async -> SegmentAudio? {
        { segmentId in
            guard let meta = files.readMeta(segmentId) else { return nil }
            let decoder = SpeexFrameDecoder(
                sampleRateHz: Int(meta.sampleRateHz),
                bitRateBps: Int(meta.bitRateBps),
                frameSamples: meta.frameSamples
            )
            let payloads = files.readFrames(segmentId).map { Data($0.payload) }
            guard let pcm = try? decoder.decodeAll(frames: payloads), !pcm.isEmpty else {
                return nil
            }
            return SegmentAudio(
                wav: PcmWav.encodeMono16(pcm: pcm, sampleRateHz: Int(meta.sampleRateHz)),
                sampleRateHz: Int(meta.sampleRateHz)
            )
        }
    }

    /// The queue/transcript-store seam, adapted onto the real `TranscriptionQueue`,
    /// `FileTranscriptStore` and `SegmentStore`.
    public static func queueHooks(
        queue: TranscriptionQueue,
        transcripts: FileTranscriptStore,
        store: SegmentStore,
        log: RuntimeLog = .silent
    ) -> BackgroundCloudUploadCoordinator.QueueHooks {
        // Mirrors a task transition onto the segment's metadata. Awaited (not fire-and-forget) so
        // the next pipeline pass cannot observe a Complete task on a still-Pending segment.
        let mirror: @Sendable (String, TaskState) async -> Void = { segmentId, state in
            do {
                try await store.updateTranscriptionState(
                    segmentId, segmentTranscriptionState(for: state)
                )
            } catch {
                log.failure("upload segment state", error)
            }
        }
        return BackgroundCloudUploadCoordinator.QueueHooks(
            pendingSegmentIds: {
                let tasks = (try? queue.all()) ?? []
                // Newest first, matching `TranscriptionQueue.nextRunnable`: the conversation the
                // user just had is the one they will look for first.
                return tasks.filter { $0.state == .pending }.reversed().map(\.segmentId)
            },
            uploadingSegmentIds: { Set((try? queue.uploadingSegmentIds()) ?? []) },
            isUploading: { segmentId in
                (try? queue.load(segmentId))?.state == .uploading
            },
            markUploading: { segmentId in
                do { try queue.markUploading(segmentId) } catch {
                    log.failure("upload mark uploading", error)
                }
                await mirror(segmentId, .uploading)
            },
            saveTranscript: { segmentId, result, modeUsed in
                do {
                    _ = try transcripts.save(
                        segmentId,
                        result: RoutedTranscription(
                            text: result.text,
                            modeUsed: modeUsed,
                            providerId: result.providerId,
                            modelUsed: result.modelUsed,
                            segments: result.segments,
                            words: result.words
                        )
                    )
                } catch {
                    log.failure("upload save transcript", error)
                }
            },
            markComplete: { segmentId, result, modeUsed in
                do {
                    try queue.markComplete(
                        segmentId,
                        result: RoutedTranscription(
                            text: result.text,
                            modeUsed: modeUsed,
                            providerId: result.providerId,
                            modelUsed: result.modelUsed,
                            segments: result.segments,
                            words: result.words
                        )
                    )
                } catch {
                    log.failure("upload mark complete", error)
                }
                await mirror(segmentId, .complete)
            },
            markFailed: { segmentId, message, retryable in
                // The user's only window onto a background upload that died is the diagnostics
                // log, so this always writes a line even when the queue update succeeds.
                log.write("cloud upload failed for \(segmentId): \(message)")
                do {
                    try queue.markFailed(segmentId, error: message, retryable: retryable)
                } catch {
                    log.failure("upload mark failed", error)
                }
                await mirror(segmentId, .failed)
            },
            markNoSpeech: { segmentId in
                do { try queue.markNoSpeech(segmentId) } catch {
                    log.failure("upload mark no speech", error)
                }
                await mirror(segmentId, .noSpeech)
            },
            resetAbandonedUploads: { inFlight in
                let reset = (try? queue.resetAbandonedUploads(inFlight: inFlight)) ?? []
                for segmentId in reset { await mirror(segmentId, .pending) }
                if !reset.isEmpty {
                    log.write("upload reconcile: \(reset.count) abandoned upload(s) requeued")
                }
                return reset
            }
        )
    }

    /// The whole coordinator, wired for production.
    ///
    /// `cloudPrimary` is the gate that decides whether audio leaves the device in the background:
    /// RemoteOnly and RemoteFirst upload; LocalOnly and LocalFirst never do, because in those
    /// modes the user chose on-device transcription as the primary path and a background upload
    /// would send their audio somewhere they did not pick. It is checked on every
    /// `submitPending()`, so a mode change takes effect immediately.
    public static func makeCoordinator(
        uploader: any BackgroundUploader,
        cloudProvider: SelectableCloudTranscriptionProvider,
        queue: TranscriptionQueue,
        transcripts: FileTranscriptStore,
        store: SegmentStore,
        files: SegmentFileReader,
        root: URL,
        settings: any RuntimeSettings,
        nowMs: @escaping @Sendable () -> Int64,
        log: RuntimeLog = .silent,
        /// Overridden only by tests, so the cloud-primary gating can be proven without a real
        /// Speex spool in the way.
        audioSource: (@Sendable (_ segmentId: String) async -> SegmentAudio?)? = nil
    ) -> BackgroundCloudUploadCoordinator {
        BackgroundCloudUploadCoordinator(
            uploader: uploader,
            cloudProvider: cloudProvider,
            jobStore: CloudUploadJobStore(root: root),
            queue: queueHooks(queue: queue, transcripts: transcripts, store: store, log: log),
            audioSource: audioSource ?? Self.audioSource(files: files),
            bodyDir: bodyDir(root: root),
            nowMs: nowMs,
            cloudPrimary: { settings.cloudIsPrimaryTranscription }
        )
    }
}
