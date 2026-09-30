import AppDB
import Foundation
import Intelligence
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

/// What a conversation that holds no conversation is called wherever a title is shown. Plain
/// and calm, like quiet: it is a fact about the recording, not an error.
public enum AudioContentPresentation {
    /// `ConversationAnnotation.providerId` of the stand-in, so it is never mistaken for an AI
    /// title and can be withdrawn.
    public static let providerId = "audioContent"
    public static let noConversationTitle = "No conversation"
    public static let noWordsSummary = "Sound was recorded, but no words were heard."
    public static let fewWordsSummary = "A few words were heard, but no conversation."
    public static let musicSummary = "Music was playing, but no conversation was heard."
    /// Words that were not a conversation and are not named: TV, an announcement, the
    /// transcriber repeating itself. "A few words" would understate an hour of television.
    public static let otherSummary = "Sound was recorded, but it holds no conversation."

    /// The stand-in's summary for a conversation whose spans are all no conversation: named
    /// only when every stretch with words in it says the same thing.
    public static func summary(for spans: [SegmentAudioContentSpan]) -> String {
        let worded = spans.filter { $0.wordCount > 0 }
        if worded.isEmpty { return noWordsSummary }
        if worded.allSatisfy({ $0.descriptor == AudioContentDescriptor.music }) { return musicSummary }
        if worded.allSatisfy({ $0.descriptor == AudioContentDescriptor.fewWords }) { return fewWordsSummary }
        return otherSummary
    }
}

/// Which stored stretches of each segment are withheld from whom, on the segment's
/// stored-audio clock (what transcript turns are timed on).
///
/// Read synchronously by the transcript seams (`EnrichmentService.transcriptOf` and the recap's
/// `transcriptTextOf`), which cannot await; written by `AudioContentService`.
public final class AudioContentMask: @unchecked Sendable {
    private let lock = NSLock()
    private var ai: [String: [Range<Int64>]] = [:]
    private var speech: [String: [Range<Int64>]] = [:]
    private var holds: [String: Bool] = [:]
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

    /// Whether any of this segment's classified time is conversation (corrections applied); nil
    /// while it has not been classified. A conversation whose every member answers false holds
    /// no conversation at all, and is presented and treated as such (`EnrichmentService`).
    public func holdsConversation(_ segmentId: String) -> Bool? {
        lock.withLock { holds[segmentId] }
    }

    func setHolds(_ segmentId: String, _ value: Bool) {
        lock.withLock { holds[segmentId] = value }
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
                holds[id] = nil
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
    /// Segments to re-key on the next look even though their own state did not move: a
    /// neighbour's did, and the stray-remark rule reads neighbours.
    private var dirty: Set<String> = []
    /// AI readings by segment (method 2), loaded once and kept in step with what is saved.
    private var judgements: [String: AudioContentJudgement] = [:]
    private let judge: (@Sendable (AiRunRequest) async throws -> RoutedAiResult)?
    private var loaded = false

    public init(
        listSegments: @escaping @Sendable () async -> [SegmentMeta],
        speechTimingsOf: @escaping @Sendable (String) -> [Transcription.TranscriptSegment]?,
        transcriptVersionOf: @escaping @Sendable (String) -> String,
        store: AudioContentStore,
        mask: AudioContentMask = AudioContentMask(),
        nowMs: @escaping @Sendable () -> Int64,
        log: RuntimeLog = .silent,
        judge: (@Sendable (AiRunRequest) async throws -> RoutedAiResult)? = nil
    ) {
        self.judge = judge
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
            judgements = try await store.judgements()
            for (id, present) in try await store.conversationPresence() { mask.setHolds(id, present) }
            try await loadMasks(segments: segments)
            loaded = true
        }

        // Wall order, because the stray-remark rule reads each segment's neighbours and a
        // neighbour settling changes the verdict (and the key) of the segments beside it.
        let ordered = segments.sorted {
            ($0.startWallMs, $0.segmentId) < ($1.startWallMs, $1.segmentId)
        }
        let versionOf = transcriptVersionOf
        func key(_ index: Int) -> String {
            let meta = ordered[index]
            let around = AudioContentClassifier.neighbours(
                of: index, in: ordered, turnsOf: { _ in [] }, versionOf: versionOf)
            return AudioContentMethod.inputKey(
                state: meta.transcriptionState,
                transcriptVersion: meta.transcriptionState == .complete
                    ? versionOf(meta.segmentId) : nil,
                neighbours: around.key + judgementKey(meta.segmentId))
        }

        var due: [(index: Int, key: String)] = []
        for (index, meta) in ordered.enumerated() {
            let id = meta.segmentId
            let now = (meta.transcriptionState, meta.closeReason != nil)
            let moved = observed[id].map { $0 != now } ?? true
            if !moved, !dirty.contains(id) { continue }
            if moved {
                // Its neighbours' keys name it, so they are looked at again too.
                if index > 0 { dirty.insert(ordered[index - 1].segmentId) }
                if index + 1 < ordered.count { dirty.insert(ordered[index + 1].segmentId) }
                observed[id] = now
            }
            let current = key(index)
            if inputKeys[id] == current || !Self.isSettled(meta) {
                // Nothing new, or nothing to say yet. Unsettled segments are looked at again
                // when their state moves; a settled one whose key matches is done.
                dirty.remove(id)
                continue
            }
            // Stays dirty until it is classified, so a backfill past the budget resumes.
            dirty.insert(id)
            due.append((index, current))
        }
        // Newest first: the day a person is looking at is today.
        due.sort { ordered[$0.index].startWallMs > ordered[$1.index].startWallMs }

        var wrote = false
        for (index, currentKey) in due.prefix(max(budget, 0)) {
            try Task.checkCancellation()
            let meta = ordered[index]
            let id = meta.segmentId
            let turns = meta.transcriptionState == .complete ? speechTimingsOf(id) : nil
            let around = AudioContentClassifier.neighbours(
                of: index, in: ordered, turnsOf: speechTimingsOf, versionOf: versionOf)
            guard
                let spans = AudioContentClassifier.classify(
                    meta: meta, turns: turns, neighbours: around.neighbours,
                    judged: currentJudgement(id)?.minutes ?? [])
            else {
                // `Complete` with no file: a fault, not silence. Looked at again when it moves.
                dirty.remove(id)
                continue
            }
            try await store.replace(segmentId: id, inputKey: currentKey, spans: spans, atMs: nowMs())
            inputKeys[id] = currentKey
            dirty.remove(id)
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
        dirty = dirty.filter { alive.contains($0) }
        if wrote, due.count > budget {
            log.write("audio content: classified \(budget), \(due.count - budget) left")
        }
        return wrote
    }

    // MARK: Method 2: AI readings

    /// The reading that applies to a segment's current transcript, if any.
    private func currentJudgement(_ segmentId: String) -> AudioContentJudgement? {
        guard let judgement = judgements[segmentId], judgement.minutes != nil,
            judgement.inputKey
                == AudioContentJudge.inputKey(transcriptVersion: transcriptVersionOf(segmentId))
        else { return nil }
        return judgement
    }

    /// Part of a segment's classification key: which reading it was classified with.
    private func judgementKey(_ segmentId: String) -> String {
        guard let judgement = currentJudgement(segmentId) else { return "|j-" }
        return "|j\(judgement.judgedAtMs ?? 0)"
    }

    /// Readings attempted per transcript before giving up on it.
    public static let maxJudgeAttempts = 4
    /// Segments older than this are backlog: read only on a charger.
    public static let recentMs: Int64 = 24 * 3_600_000

    /// One pass of method 2: ask for an AI reading of up to `budget` segments that hold
    /// conversation minutes and have none for their current transcript. Newest first; the
    /// backlog (older than a day) only when `allowBackfill`. Returns true when it saved a
    /// reading, so the pass comes back for more and the next classification uses it.
    @discardableResult
    public func judgePass(budget: Int = 3, allowBackfill: Bool) async throws -> Bool {
        guard let judge, loaded else { return false }
        let now = nowMs()
        var candidates: [SegmentMeta] = []
        for meta in await listSegments() {
            let id = meta.segmentId
            guard Self.isSettled(meta), meta.transcriptionState == .complete,
                mask.holdsConversation(id) == true || currentJudgement(id) != nil,
                currentJudgement(id) == nil
            else { continue }
            if !allowBackfill, now - meta.startWallMs > Self.recentMs { continue }
            let key = AudioContentJudge.inputKey(transcriptVersion: transcriptVersionOf(id))
            if let previous = judgements[id], previous.inputKey == key {
                if previous.attempts >= Self.maxJudgeAttempts { continue }
                if let next = previous.nextAttemptAtMs, next > now { continue }
            }
            candidates.append(meta)
        }
        candidates.sort { $0.startWallMs > $1.startWallMs }

        var wrote = false
        for meta in candidates.prefix(max(budget, 0)) {
            try Task.checkCancellation()
            let id = meta.segmentId
            let key = AudioContentJudge.inputKey(transcriptVersion: transcriptVersionOf(id))
            let prior = judgements[id].flatMap { $0.inputKey == key ? $0 : nil }
            guard let turns = speechTimingsOf(id) else { continue }
            guard let input = AudioContentJudge.input(turns: turns) else {
                // Nothing to read: recorded as read, with no minutes.
                try await saveJudgement(
                    AudioContentJudgement(segmentId: id, inputKey: key, minutes: [], judgedAtMs: now))
                wrote = true
                continue
            }
            do {
                let result = try await judge(
                    AiRunRequest(
                        requestId: "audio-content-\(id)-\(now)", prompt: AudioContentJudge.template,
                        transcripts: [TranscriptExcerpt(segmentId: id, text: input)]))
                guard let minutes = AudioContentJudge.parse(result.text) else {
                    throw AiError.providerFailed("audio-content judge: no minutes in the reply")
                }
                try await saveJudgement(
                    AudioContentJudgement(
                        segmentId: id, inputKey: key, minutes: minutes, provider: result.providerId,
                        model: result.modelUsed, attempts: (prior?.attempts ?? 0) + 1,
                        judgedAtMs: nowMs()))
                wrote = true
            } catch let error as AiError {
                switch error {
                case .providerUnavailable, .consentRequired:
                    // No AI to ask (none configured, consent off, an account on hold): nothing
                    // is owed and nothing is counted against the segment.
                    return wrote
                case .providerFailed:
                    try await recordJudgeFailure(id: id, key: key, prior: prior, error: error)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try await recordJudgeFailure(id: id, key: key, prior: prior, error: error)
            }
        }
        return wrote
    }

    private func saveJudgement(_ judgement: AudioContentJudgement) async throws {
        try await store.saveJudgement(judgement)
        judgements[judgement.segmentId] = judgement
        // Its classification key names the reading: look at it again on the next pass.
        dirty.insert(judgement.segmentId)
    }

    private func recordJudgeFailure(
        id: String, key: String, prior: AudioContentJudgement?, error: Error
    ) async throws {
        let attempts = (prior?.attempts ?? 0) + 1
        let waitMs = min(Int64(30 * 60_000) << Int64(max(attempts - 1, 0)), 6 * 3_600_000)
        let judgement = AudioContentJudgement(
            segmentId: id, inputKey: key, minutes: nil, attempts: attempts,
            lastError: String(String(describing: error).prefix(300)),
            nextAttemptAtMs: nowMs() + waitMs)
        try await store.saveJudgement(judgement)
        judgements[id] = judgement
        log.write("audio content: reading failed for \(id) (attempt \(attempts)): \(judgement.lastError ?? "")")
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
        dirty.remove(id)
        mask.forget([id])
    }

    /// Range-delete cascade: part of this segment's stored audio was silenced and the words in
    /// it taken out of the transcript (`DeleteCascade`), while the segment itself — its state,
    /// its closedness — did not move.
    ///
    /// That is exactly the change `classifyPass` cannot see: it re-keys a segment only when
    /// `observed` says its state moved, and nothing here moved it. So the segment is handed
    /// back as never looked at. The next pass keys it against the transcript as it now is,
    /// finds the key differs, classifies it again, and looks at its neighbours too (their keys
    /// name it, and the stray-remark rule reads them).
    ///
    /// A correction lying wholly inside the deleted stretch goes with it — a statement about
    /// audio the person has since deleted — and one that also covers surviving audio stays,
    /// the same rule `forget(segment:)` applies to a whole segment. The masks are brought up
    /// to date at once rather than at the next pass, so nothing reads a correction that is no
    /// longer there.
    public func audioRewritten(segment meta: SegmentMeta, mediaRangeMs: Range<Int64>) async {
        let id = meta.segmentId
        observed[id] = nil
        dirty.insert(id)
        let clock = SegmentMediaClock(meta)
        let start = meta.startWallMs + clock.wall(fromMedia: mediaRangeMs.lowerBound)
        let end = meta.startWallMs + clock.wall(fromMedia: mediaRangeMs.upperBound)
        guard end > start else { return }
        do {
            var removed = false
            for correction in try await store.overrides(overlappingMs: start..<end)
            where correction.startMs >= start && correction.endMs <= end {
                try await store.removeOverride(id: correction.id)
                removed = true
            }
            if removed { try await refreshMasks(overlapping: start..<end) }
        } catch {
            log.failure("audio content range cascade", error)
        }
    }

    // MARK: Masks

    static func isSettled(_ meta: SegmentMeta) -> Bool {
        meta.closeReason != nil
            && (meta.transcriptionState == .complete || meta.transcriptionState == .noSpeech)
    }

    /// Deciders whose no-conversation verdict withholds a stretch from the model. Word-rate and
    /// NoSpeech verdicts are absent on purpose (nothing, or next to nothing, to withhold);
    /// later content methods add themselves here.
    static let aiMaskingDeciders: Set<String> = [
        AudioContentDecider.user, AudioContentDecider.contentJudge,
    ]
    static let speechMaskingDeciders: Set<String> = [
        AudioContentDecider.user, AudioContentDecider.loop, AudioContentDecider.contentJudge,
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
        mask.setHolds(meta.segmentId, effective.contains { $0.kind == .conversation })
    }
}
