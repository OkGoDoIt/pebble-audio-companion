import AppDB
import Foundation
import SegmentStore
import Transcription

// The audio-content stage: keeps `audio_content_spans` in step with the transcripts, and keeps
// the in-memory masks that stop audio judged to hold no conversation from reaching the AI
// layer and the conversation-boundary evidence. Design: `docs/audio-content-classification.md`.
//
// Cost shape. The method is a pass over one transcript's turn timings — no model, no audio —
// and it runs only for a segment whose transcription state, closedness or transcript file
// changed since it was last classified (or when the method's version moves). In steady state a
// pass compares an in-memory dictionary against the segment index and reads nothing. The
// backfill of an existing library is the same work spread over passes, `budget` segments at a
// time; it only runs when the pass itself runs (foreground, or backgrounded on a cool
// charger — `BackgroundWorkPolicy`).

/// Which stored stretches of each segment are withheld from whom, on the segment's
/// stored-audio clock (what transcript turns are timed on).
///
/// Read synchronously by the transcript seams (`EnrichmentService.transcriptOf` and the recap's
/// `transcriptTextOf`), which cannot await; written by `AudioContentService`.
public final class AudioContentMask: @unchecked Sendable {
    private let lock = NSLock()
    private var ai: [String: [Range<Int64>]] = [:]
    private var speech: [String: [Range<Int64>]] = [:]
    private var aiGenerations: [String: Int] = [:]
    private var speechGenerations: [String: Int] = [:]

    public init() {}

    /// Stretches whose turns must not reach a model: audio a CONTENT judgement or a person
    /// found to hold no conversation. Not the word-rate verdicts (there is nothing in a
    /// wordless minute to withhold, and a stray word is real speech) and not loops (the model
    /// input already collapses those, with a note — `withLoopedArtefactsCollapsed`).
    public func aiRanges(_ segmentId: String) -> [Range<Int64>] {
        lock.withLock { ai[segmentId] ?? [] }
    }

    /// Stretches whose turns are not SPEECH evidence for conversation boundaries: the above plus
    /// transcriber loops, whose "words" were never said and used to keep a quiet stretch from
    /// ever ending a conversation.
    public func speechRanges(_ segmentId: String) -> [Range<Int64>] {
        lock.withLock { speech[segmentId] ?? [] }
    }

    /// Changes whenever this segment's AI ranges do; 0 while it has none. Folded into the
    /// transcript version the AI workers memoise against, so a verdict that withholds text
    /// re-runs the titles and follow-ups built from it — and nothing else.
    public func aiGeneration(_ segmentId: String) -> Int {
        lock.withLock { aiGenerations[segmentId] ?? 0 }
    }

    /// Changes whenever this segment's speech ranges do; 0 while it has none. Part of the
    /// boundary layer's evidence cache key.
    public func speechGeneration(_ segmentId: String) -> Int {
        lock.withLock { speechGenerations[segmentId] ?? 0 }
    }

    /// Returns true when anything changed.
    @discardableResult
    func set(segmentId: String, ai newAi: [Range<Int64>], speech newSpeech: [Range<Int64>]) -> Bool {
        lock.withLock {
            let oldAi = ai[segmentId] ?? []
            let oldSpeech = speech[segmentId] ?? []
            guard oldAi != newAi || oldSpeech != newSpeech else { return false }
            if oldAi != newAi { aiGenerations[segmentId] = (aiGenerations[segmentId] ?? 0) &+ 1 }
            if oldSpeech != newSpeech {
                speechGenerations[segmentId] = (speechGenerations[segmentId] ?? 0) &+ 1
            }
            ai[segmentId] = newAi.isEmpty ? nil : newAi
            speech[segmentId] = newSpeech.isEmpty ? nil : newSpeech
            return true
        }
    }

    func forget(_ segmentIds: some Sequence<String>) {
        lock.withLock {
            for id in segmentIds {
                ai[id] = nil
                speech[id] = nil
            }
        }
    }

    var maskedSegmentIds: Set<String> {
        lock.withLock { Set(ai.keys).union(speech.keys) }
    }
}

public actor AudioContentService {
    private let listSegments: @Sendable () async -> [SegmentMeta]
    private let speechTimingsOf: @Sendable (String) -> [Transcription.TranscriptSegment]?
    private let transcriptVersionOf: @Sendable (String) -> String
    private let store: AudioContentStore
    public nonisolated let mask: AudioContentMask
    private let nowMs: @Sendable () -> Int64
    private let log: RuntimeLog

    /// What each classified segment was computed from (`AudioContentMethod.inputKey`).
    private var inputKeys: [String: String] = [:]
    /// The (state, closed) each segment was last looked at in. A segment is only re-keyed —
    /// one `stat` of its transcript — when this moves, so a pass over an unchanged library
    /// reads nothing.
    private var observed: [String: (TranscriptionState, Bool)] = [:]
    private var loaded = false

    public init(
        listSegments: @escaping @Sendable () async -> [SegmentMeta],
        speechTimingsOf: @escaping @Sendable (String) -> [Transcription.TranscriptSegment]?,
        transcriptVersionOf: @escaping @Sendable (String) -> String,
        store: AudioContentStore,
        mask: AudioContentMask = AudioContentMask(),
        nowMs: @escaping @Sendable () -> Int64,
        log: RuntimeLog = .silent
    ) {
        self.listSegments = listSegments
        self.speechTimingsOf = speechTimingsOf
        self.transcriptVersionOf = transcriptVersionOf
        self.store = store
        self.mask = mask
        self.nowMs = nowMs
        self.log = log
    }

    /// Per-pass cap on segments classified. A segment is milliseconds of CPU; the cap exists
    /// so the first pass after install or a method change cannot hold the loop.
    public static let defaultBudget = 40

    /// One pass. Returns true when it classified anything, so the loop comes straight back for
    /// the rest of a backfill.
    @discardableResult
    public func classifyPass(budget: Int = AudioContentService.defaultBudget) async throws -> Bool {
        let segments = await listSegments()
        if !loaded {
            inputKeys = try await store.inputKeys()
            try await loadMasks(segments: segments)
            loaded = true
        }

        var due: [SegmentMeta] = []
        for meta in segments {
            let now = (meta.transcriptionState, meta.closeReason != nil)
            if let seen = observed[meta.segmentId], seen == now { continue }
            let key = AudioContentMethod.inputKey(
                state: meta.transcriptionState,
                transcriptVersion: meta.transcriptionState == .complete
                    ? transcriptVersionOf(meta.segmentId) : nil)
            if inputKeys[meta.segmentId] == key || !Self.isSettled(meta) {
                // Nothing new, or nothing to say yet. Unsettled segments are looked at again
                // when their state moves; a settled one whose key matches is done.
                observed[meta.segmentId] = now
                continue
            }
            due.append(meta)
        }
        // Newest first: the day a person is looking at is today.
        due.sort { $0.startWallMs > $1.startWallMs }

        var wrote = false
        for meta in due.prefix(max(budget, 0)) {
            try Task.checkCancellation()
            let id = meta.segmentId
            let turns = meta.transcriptionState == .complete ? speechTimingsOf(id) : nil
            let key = AudioContentMethod.inputKey(
                state: meta.transcriptionState,
                transcriptVersion: meta.transcriptionState == .complete ? transcriptVersionOf(id) : nil)
            guard let spans = AudioContentClassifier.classify(meta: meta, turns: turns) else {
                // `Complete` with no file: a fault, not silence. Looked at again when it moves.
                observed[id] = (meta.transcriptionState, meta.closeReason != nil)
                continue
            }
            try await store.replace(segmentId: id, inputKey: key, spans: spans, atMs: nowMs())
            inputKeys[id] = key
            observed[id] = (meta.transcriptionState, meta.closeReason != nil)
            try await refreshMask(meta: meta, spans: spans)
            wrote = true
        }

        // Segments that are gone keep nothing (the delete cascade does this too; retention of a
        // library copied in from elsewhere may not have).
        let alive = Set(segments.map(\.segmentId))
        let gone = inputKeys.keys.filter { !alive.contains($0) }
        if !gone.isEmpty {
            try await store.forget(segmentIds: Array(gone))
            for id in gone { inputKeys[id] = nil }
            mask.forget(gone)
            wrote = true
        }
        observed = observed.filter { alive.contains($0.key) }
        if wrote, due.count > budget {
            log.write("audio content: classified \(budget), \(due.count - budget) left")
        }
        return wrote
    }

    /// A person's correction. The masks of every segment it touches are brought up to date
    /// at once, so the next AI pass and the next regroup read it.
    @discardableResult
    public func correct(
        startMs: Int64, endMs: Int64, kind: AudioContentKind
    ) async throws -> AudioContentOverride {
        let correction = try await store.addOverride(
            startMs: startMs, endMs: endMs, kind: kind, atMs: nowMs())
        try await refreshMasks(overlapping: startMs..<max(endMs, startMs + 1))
        return correction
    }

    public func undoCorrection(_ correction: AudioContentOverride) async throws {
        try await store.removeOverride(id: correction.id)
        try await refreshMasks(overlapping: correction.startMs..<max(correction.endMs, correction.startMs + 1))
    }

    /// Delete cascade: the segment's spans go, and so does any correction lying wholly inside
    /// its time — a statement about a recording the person has since deleted. A correction
    /// that also covers surviving audio stays, because it is still true of that.
    public func forget(segment meta: SegmentMeta) async {
        let id = meta.segmentId
        do {
            try await store.forget(segmentIds: [id])
            let span = meta.startWallMs..<max(ConversationGrouper.segmentEndMs(meta), meta.startWallMs + 1)
            for correction in try await store.overrides(overlappingMs: span)
            where correction.startMs >= span.lowerBound && correction.endMs <= span.upperBound {
                try await store.removeOverride(id: correction.id)
            }
        } catch {
            log.failure("audio content cascade", error)
        }
        inputKeys[id] = nil
        observed[id] = nil
        mask.forget([id])
    }

    // MARK: Masks

    static func isSettled(_ meta: SegmentMeta) -> Bool {
        meta.closeReason != nil
            && (meta.transcriptionState == .complete || meta.transcriptionState == .noSpeech)
    }

    /// Deciders whose no-conversation verdict withholds a stretch from the model. Word-rate and
    /// NoSpeech verdicts are absent on purpose (nothing, or next to nothing, to withhold);
    /// later content methods add themselves here.
    static let aiMaskingDeciders: Set<String> = [AudioContentDecider.user]
    static let speechMaskingDeciders: Set<String> = [
        AudioContentDecider.user, AudioContentDecider.loop,
    ]

    private func loadMasks(segments: [SegmentMeta]) async throws {
        let byId = Dictionary(segments.map { ($0.segmentId, $0) }, uniquingKeysWith: { a, _ in a })
        let stored = Dictionary(grouping: try await store.maskingSpans(), by: \.segmentId)
        var touched = Set(stored.keys)
        // Corrections can mask a segment with no masking span of its own.
        if let first = segments.map(\.startWallMs).min(),
            let last = segments.map({ ConversationGrouper.segmentEndMs($0) }).max(), last > first
        {
            for correction in try await store.overrides(overlappingMs: first..<last) {
                for meta in segments
                where meta.startWallMs < correction.endMs
                    && ConversationGrouper.segmentEndMs(meta) > correction.startMs
                {
                    touched.insert(meta.segmentId)
                }
            }
        }
        for id in touched {
            guard let meta = byId[id] else { continue }
            let spans = try await store.spans(segmentId: id)
            try await refreshMask(meta: meta, spans: spans)
        }
    }

    private func refreshMasks(overlapping window: Range<Int64>) async throws {
        for meta in await listSegments()
        where meta.startWallMs < window.upperBound
            && ConversationGrouper.segmentEndMs(meta) > window.lowerBound
        {
            try await refreshMask(meta: meta, spans: try await store.spans(segmentId: meta.segmentId))
        }
    }

    /// One segment's masks from its stored spans with corrections applied. Each effective
    /// piece is taken back to the stored-audio clock through the segment's own gap records.
    private func refreshMask(meta: SegmentMeta, spans: [SegmentAudioContentSpan]) async throws {
        let start = meta.startWallMs
        let end = max(ConversationGrouper.segmentEndMs(meta), start)
        let corrections = try await store.overrides(overlappingMs: start..<max(end, start + 1))
        let effective = AudioContentStore.effectiveSpans(
            stored: spans.map(\.span), overrides: corrections, window: start..<max(end, start + 1))
        let clock = SegmentMediaClock(meta)
        func media(_ piece: AudioContentSpan) -> Range<Int64> {
            if clock.isExact {
                let low = clock.media(fromWall: piece.startMs - start)
                let high = clock.media(fromWall: piece.endMs - start)
                return low..<max(high, low)
            }
            return (piece.startMs - start)..<(piece.endMs - start)
        }
        var ai: [Range<Int64>] = []
        var speech: [Range<Int64>] = []
        for piece in effective where piece.kind == .noConversation {
            let range = media(piece)
            guard !range.isEmpty else { continue }
            if Self.aiMaskingDeciders.contains(piece.decidedBy) { ai.append(range) }
            if Self.speechMaskingDeciders.contains(piece.decidedBy) { speech.append(range) }
        }
        mask.set(segmentId: meta.segmentId, ai: ai, speech: speech)
    }
}
