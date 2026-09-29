import Foundation

// Port of `core/transcription/.../LocalTranscriptionLifecycle.kt`.

/// Lets the app release the heavy resident local-transcription model on demand.
///
/// A local whisper-family model can hold tens to hundreds of MB resident. On iOS that resident
/// footprint makes the app a jetsam target, especially during the short Core Bluetooth
/// background wakes that are only meant for receiving audio. So instead of keeping the model
/// loaded indefinitely, callers load it for a bounded transcription window and release it on:
///
///  - backgrounding (no local transcription runs while backgrounded),
///  - memory pressure (a system memory warning),
///  - idle timeout (no transcription for a while),
///  - selected-model change (the old model is no longer wanted).
///
/// The tradeoff is cold-start latency before the next local transcription, which is far
/// cheaper than being killed. Releasing is always safe: the next
/// `TranscriptionProvider.transcribe` reloads.
public protocol LocalTranscriptionLifecycle: Sendable {
    /// Immediately releases the loaded model, if any. No-op (and silent) when nothing is loaded.
    func releaseModel(reason: String) async

    /// Releases the model only when it has been loaded but unused for at least `idleTimeoutMs`,
    /// measured against `nowMs`. A no-op while a transcription is recent or nothing is loaded.
    func releaseModelIfIdle(nowMs: Int64, idleTimeoutMs: Int64) async

    /// Lets the model go once the work on it has finished, without interrupting it and without
    /// making the caller wait — for the app leaving the foreground. `releaseModel` stays the
    /// hard version (memory warnings). Interrupting on background entry threw away the segment
    /// in flight and, until 2026-09-29, killed the pipeline loop with it.
    func releaseModelWhenIdle(reason: String) async
}

extension LocalTranscriptionLifecycle {
    public func releaseModelWhenIdle(reason: String) async {
        await releaseModel(reason: reason)
    }
}
