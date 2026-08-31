import Foundation
import LiveAudio

/// A synchronously readable mirror of the live transcript previews.
///
/// The previews themselves live inside two actors (`LiveTranscriber` and `CloudLiveTranscriber`),
/// and the consumer that needs them most — `EnrichmentWorker`'s plan for a LIVE conversation — is
/// a synchronous computation running inside the enrichment pass. That mismatch is why
/// `EnrichmentService.liveTextOf` was left unsupplied: the honest options were to make the whole
/// planning path async, or to block on an actor from a synchronous seam. Both are worse than the
/// third: the live pass, which already owns both actors and already runs every pipeline pass,
/// mirrors the merged text into this cache, and the synchronous readers read the mirror.
///
/// Consequences of the mirror being a mirror, stated plainly:
///  - it is at most one pipeline pass stale (the live pass runs every 5 s while a segment is
///    open), which is nothing next to the tens of seconds of transcription latency behind it;
///  - it holds only what a live transcriber currently has, so it empties on `prune` exactly when
///    the durable transcript takes over. Nothing reads a preview for a segment that has a real
///    transcript.
public final class LivePreviewCache: @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String: String] = [:]

    public init() {}

    /// The rolling live text for a still-open segment, or nil when there is none yet.
    /// Blank text reads as "nothing recognized yet" and is never stored.
    public func text(for segmentId: String) -> String? {
        lock.withLock { texts[segmentId] }
    }

    /// Replaces the whole mirror. Wholesale rather than per-segment so a preview that was pruned
    /// disappears here too, instead of lingering as text with no audio behind it.
    public func replaceAll(_ next: [String: String]) {
        let cleaned = next.compactMapValues { text -> String? in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        lock.withLock {
            if texts != cleaned { texts = cleaned }
        }
    }

    /// Segment ids currently carrying live text (diagnostics and tests).
    public var segmentIds: Set<String> { lock.withLock { Set(texts.keys) } }
}
