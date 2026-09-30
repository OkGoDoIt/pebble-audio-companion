import Foundation
import SegmentStore
import WireProtocol

// One logical day as an honest timeline (plan 5.3, 7.10).
//
// THE RULE. Every minute of the day gets exactly one kind, and the first rule that applies wins:
//
//   1 deleted             — `deletedSpans`
//   2 paused              — the pause journal (you / timed / other) and the watch's power save
//   3 audio missing       — visible loss, placed by `CoverageComputer`, causes from the records
//   4 not recording       — coverage `off`: no audio and no record of why
//   5 quiet               — watch-reported suppressed silence
//   6 not transcribed yet / transcription failed — recorded time of a recording in that state
//   7 chapter             — a chapter row
//   8 no conversation     — the classifier's no-conversation span, else transcribed time with
//                           no words
//   9 fallback card       — transcribed words no chapter covers: a stretch of talk, cut where
//                           the talk really stopped (`HistoryTalkCutter`), untitled, with a
//                           verbatim snippet
//
// Rules 1-5 are not re-derived here. They are `CoverageComputer.computeAttributed` — the same
// placement the Today strip draws — with its watch-quiet recut, so History can never call a
// minute missing that Today calls paused. The one ordering that comes from coverage rather than
// from the list above: RECORDED AUDIO WINS over a pause or a loss record covering the same
// moment (`CoverageComputer.priority`). Audio that exists was not paused and was not lost.
//
// A CARD (rules 7 and 9) is a range, not a set of minutes: it absorbs the quiet, the wordless
// recorded time and the loss inside it — loss as `missingMs`, never dropped — and it is cut by
// anything that says nobody was listening or that the words are not known: a deletion, a pause,
// time nothing recorded (except a sub-`foldBelowMs` hole between two recordings of one talk
// stretch), a recording not yet (or never) transcribed.
//
// Then the day is tidied, in this order, and no step may relabel loss:
//   a. neighbours of the same kind merge, and (`HistoryDayRules.carryShortLoss`, the default)
//      loss under `foldBelowMs` beside recorded time or a card becomes that neighbour's
//      `missingMs` — see the rule for why;
//   b. no-conversation shorter than `noConversationMinimumMs` (holes of quiet up to
//      `noConversationHoleMs` bridged) becomes quiet;
//   c. items shorter than `foldBelowMs` fold into a neighbour that can honestly take them
//      (`canFold`) — including a recorded sliver into the watch's power save or unrecorded time
//      beside it; loss, cards, deletions and a pause the person made never fold, and what an item
//      has already taken in travels with it, so folds cannot chain into a relabel no single
//      fold may make;
//   d. calm time at both ends (quiet, not recording, the watch's power save) becomes the
//      leading and trailing edges; today has no trailing edge and ends in the live block.
//
// Pure: no file, database or clock. The caller gathers the inputs (`HistoryDayInputs.swift`).

public enum HistoryDayBuilder {
    public struct Input: Sendable {
        public var dateKey: String
        /// `ZoneTimeline.windows(of: dateKey)`. Several when the zone changed during the day.
        public var windows: [HistoryDayWindow]
        /// Every recording that may have painted anything on the day — including the next day's
        /// first recording, which can carry the record of an outage that happened today.
        public var segments: [SegmentCoverageInput]
        public var pauses: [PauseInterval]
        public var speechRuns: [HistorySpeechRun]
        public var segmentStates: [HistorySegmentState]
        public var chapters: [HistoryChapterInput]
        /// Unused (see `HistoryConversationInput`).
        public var conversations: [HistoryConversationInput]
        /// Transcript turns in time order, for the snippets of cards with no title of their own.
        public var turnPreviews: [HistoryTurnPreview]
        public var followUps: [HistoryFollowUpInput]
        public var contentSpans: [HistoryContentSpanInput]
        public var deletedSpans: [HistoryDeletedSpanInput]
        /// Set when the day is today: the timeline runs to now and has no trailing edge.
        public var nowMs: Int64?
        /// Today, and currently recording: the timeline ends in the live block.
        public var isLive: Bool
        public var rules: HistoryDayRules

        public init(
            dateKey: String, windows: [HistoryDayWindow], segments: [SegmentCoverageInput],
            pauses: [PauseInterval] = [], speechRuns: [HistorySpeechRun] = [],
            segmentStates: [HistorySegmentState] = [], chapters: [HistoryChapterInput] = [],
            conversations: [HistoryConversationInput] = [],
            turnPreviews: [HistoryTurnPreview] = [],
            followUps: [HistoryFollowUpInput] = [],
            contentSpans: [HistoryContentSpanInput] = [],
            deletedSpans: [HistoryDeletedSpanInput] = [], nowMs: Int64? = nil,
            isLive: Bool = false, rules: HistoryDayRules = .default
        ) {
            self.dateKey = dateKey
            self.windows = windows
            self.segments = segments
            self.pauses = pauses
            self.speechRuns = speechRuns
            self.segmentStates = segmentStates
            self.chapters = chapters
            self.conversations = conversations
            self.turnPreviews = turnPreviews
            self.followUps = followUps
            self.contentSpans = contentSpans
            self.deletedSpans = deletedSpans
            self.nowMs = nowMs
            self.isLive = isLive
            self.rules = rules
        }
    }

    public static func build(_ input: Input) -> HistoryDay {
        let windows = input.windows.filter { !$0.range.isEmpty }.sorted { $0.range.lowerBound < $1.range.lowerBound }
        let dayZone = windows.first?.zoneID ?? input.windows.first?.zoneID ?? "UTC"
        let isToday = input.nowMs != nil
        let empty = HistoryDay(
            dateKey: input.dateKey, zoneID: dayZone, isToday: isToday, hasRecordings: false,
            leadingEdge: nil, items: [], trailingEdge: nil)

        var built: [BuiltWindow] = []
        for window in windows {
            let coverage = CoverageComputer.computeAttributed(
                dateKey: input.dateKey, timeZoneID: window.zoneID, segments: input.segments,
                pauses: input.pauses, nowMs: input.nowMs)
            guard let domain = coverage.domain, let range = clip(window.range, to: domain) else {
                continue
            }
            let atoms = Self.atoms(in: range, coverage: coverage, input: input)
            var pieces = Self.pieces(atoms: atoms, input: input)
            pieces = Self.tidy(pieces, rules: input.rules)
            built.append(
                BuiltWindow(
                    zoneID: window.zoneID, pieces: pieces, hasAnything: atoms.contains { $0.atom != .off },
                    lossRecords: coverage.lossRecords.sorted { $0.range.lowerBound < $1.range.lowerBound }))
        }
        guard built.contains(where: \.hasAnything) else { return empty }

        // One list across the windows, with a zone divider wherever the zone changes.
        var entries: [Entry] = []
        for (windowIndex, window) in built.enumerated() where !window.pieces.isEmpty {
            if let lastZone = entries.last(where: { $0.piece != nil })?.zoneID, lastZone != window.zoneID {
                entries.append(
                    Entry(zoneChangeAt: window.pieces[0].start, zoneID: window.zoneID, window: windowIndex))
            }
            entries += window.pieces.map { Entry(piece: $0, zoneID: window.zoneID, window: windowIndex) }
        }

        // The ends of the day: calm time is compressed into one line each. Never loss, never a
        // pause the person made, never anything that can be opened.
        var leadingEdge: HistoryEdge?
        var trailingEdge: HistoryEdge?
        if let firstKept = entries.firstIndex(where: { $0.piece.map { !Self.isCalm($0) } ?? false }) {
            let stripped = entries[..<firstKept].compactMap(\.piece)
            if stripped.contains(where: { $0.end > $0.start }) {
                leadingEdge = HistoryEdge(atMs: entries[firstKept].piece!.start, kind: Self.edgeKind(stripped))
            }
            entries.removeSubrange(..<firstKept)
            if !isToday, let lastKept = entries.lastIndex(where: { $0.piece.map { !Self.isCalm($0) } ?? false }) {
                let stripped = entries[(lastKept + 1)...].compactMap(\.piece)
                if stripped.contains(where: { $0.end > $0.start }) {
                    trailingEdge = HistoryEdge(atMs: entries[lastKept].piece!.end, kind: Self.edgeKind(stripped))
                }
                entries.removeSubrange((lastKept + 1)...)
            }
        }
        // (A day that is calm from end to end keeps its items: a whole day of the watch saving
        // power is worth saying, and there is nothing to anchor an edge to.)
        entries = Self.withoutStrayZoneChanges(entries)

        var live: HistoryLiveBlock?
        if let nowMs = input.nowMs, input.isLive {
            (entries, live) = Self.liveTail(entries, nowMs: nowMs)
        }

        let previews = input.turnPreviews.sorted { $0.startMs < $1.startMs }
        var items: [HistoryItem] = []
        for entry in entries {
            if let piece = entry.piece {
                var item = Self.item(piece, zoneID: entry.zoneID, lossRecords: built[entry.window].lossRecords)
                if case .chapter(var block) = item, block.source == .conversation {
                    block.snippet = Self.snippet(in: block.startMs..<block.endMs, previews: previews)
                    item = .chapter(block)
                }
                items.append(item)
            } else if let atMs = entry.zoneChangeAt {
                items.append(.zoneChange(HistoryZoneChange(atMs: atMs, zoneID: entry.zoneID)))
            }
        }
        if let live { items.append(.live(live)) }
        items = Self.attachingFollowUps(input.followUps, to: items, share: input.rules.followUpSpanShare)

        return HistoryDay(
            dateKey: input.dateKey, zoneID: dayZone, isToday: isToday, hasRecordings: true,
            leadingEdge: leadingEdge, items: items, trailingEdge: isToday ? nil : trailingEdge)
    }

    // MARK: - Vocabulary

    /// Who a pause-journal row says paused capture. The journal stores the surface that STARTED
    /// the pause (`PauseSource`); a phone control the person used is `.you`, the pause schedule
    /// is `.timed`, and anything else — Forget Watch, a cancelled onboarding, a value an older
    /// build wrote — is `.other`, because "you paused capture" is not what happened there.
    public static func pauseActor(forSource source: String) -> HistoryPauseActor {
        switch PauseSource(rawValue: source) {
        case .statusCard?, .liveScreen?, .intent?, .settingsSwitch?: return .you
        case .schedule?: return .timed
        case .forgetWatch?, .onboarding?, nil: return .other
        }
    }

    /// What one loss record says caused it, or nil when it does not say (an undecodable reason).
    /// A receiver skip is the phone noticing frames that never arrived with no word from the
    /// watch. Never a guess.
    public static func lossCause(of gap: GapMeta) -> HistoryLossCause? {
        if gap.origin == GapMeta.originSequenceSkip { return .phoneMissedAudio }
        switch gapReason(of: gap) {
        case .spoolOverflow?: return .watchBufferFull
        case .micConflict?: return .watchDictation
        case .userDisabled?: return .stoppedOnWatch
        case .lowBattery?: return .watchBattery
        case .codecError?: return .watchAudioFault
        case .transportReset?: return .connectionReset
        // Neither is loss (`GapClassifier`), so neither can explain a missing minute.
        case .powerSave?, .silenceSuppressed?, nil: return nil
        }
    }

    // MARK: - Atoms: one kind per elementary interval

    enum Atom: Equatable {
        case deleted(HistoryDeletionCause)
        case paused(HistoryPauseActor)
        case missing
        case off
        case quiet
        case pending
        case failed(String?)
        case noConversation(String?)
        /// Transcribed words, and the recording they came from.
        case speech(String)

        /// Cuts a card: says nobody was listening, or that the words are not known.
        var isBarrier: Bool {
            switch self {
            case .deleted, .paused, .off, .pending, .failed: return true
            case .missing, .quiet, .noConversation, .speech: return false
            }
        }
    }

    struct AtomSpan: Equatable {
        var range: Range<Int64>
        var atom: Atom
    }

    private enum StateLabel: Equatable {
        case failed(String?)
        case pending
        case transcribed

        var rank: Int {
            switch self {
            case .failed: return 0
            case .pending: return 1
            case .transcribed: return 2
            }
        }
    }

    static func atoms(in range: Range<Int64>, coverage: AttributedDayCoverage, input: Input) -> [AtomSpan] {
        let spans = coverage.spansWithWatchQuiet.compactMap { span -> (Range<Int64>, CoverageKind)? in
            clip(span.startMs..<span.endMs, to: range).map { ($0, span.kind) }
        }
        // Only what overlaps this window (a caller may hand over a whole library of runs).
        func near(_ start: Int64, _ end: Int64) -> Bool { start < range.upperBound && end > range.lowerBound }
        let coverageLine = IntervalLine(flattening: spans) { _, _ in false }
        let deletedLine = IntervalLine(
            flattening: input.deletedSpans.filter { near($0.startMs, $0.endMs) }.map { ($0.startMs..<$0.endMs, $0.cause) }
        ) { a, b in a == .user && b != .user }
        let actorRank: (HistoryPauseActor) -> Int = { [.you: 0, .timed: 1, .other: 2, .watchPowerSave: 3][$0]! }
        let userPauseLine = IntervalLine(
            flattening: coverage.pauseRecords.map { ($0.range, pauseActor(forSource: $0.source)) }
        ) { actorRank($0) < actorRank($1) }
        let watchPauseLine = IntervalLine(
            flattening: coverage.watchPauseRecords.map { ($0.range, true) }) { _, _ in false }
        let stateLine = IntervalLine(
            flattening: input.segmentStates.filter { near($0.startMs, $0.endMs) }.map { state -> (Range<Int64>, StateLabel) in
                let label: StateLabel
                switch state.state {
                case .failed: label = .failed(state.failureReason)
                case .pending, .running, .uploading, .disabled: label = .pending
                case .complete, .noSpeech: label = .transcribed
                }
                return (state.startMs..<state.endMs, label)
            }
        ) { $0.rank < $1.rank }
        let contentLine = IntervalLine(
            flattening: input.contentSpans.filter { $0.kind == .noConversation && near($0.startMs, $0.endMs) }
                .map { ($0.startMs..<$0.endMs, $0.descriptor) }
        ) { a, b in a != nil && b == nil }
        let speechLine = IntervalLine(
            flattening: input.speechRuns.filter { near($0.startMs, $0.endMs) }.map { ($0.startMs..<$0.endMs, $0.segmentId) }
        ) { _, _ in false }

        var bounds: [Int64] = [range.lowerBound, range.upperBound]
        for line in [coverageLine.bounds, deletedLine.bounds, userPauseLine.bounds, watchPauseLine.bounds,
            stateLine.bounds, contentLine.bounds, speechLine.bounds]
        {
            bounds += line
        }
        // Chapter edges are cuts the atoms must keep: a chapter claims whole atoms.
        var chapterBounds: Set<Int64> = []
        for chapter in input.chapters where near(chapter.startMs, chapter.endMs) {
            chapterBounds.insert(chapter.startMs)
            chapterBounds.insert(chapter.endMs)
        }
        bounds += chapterBounds
        let cuts = Array(Set(bounds.filter { range.contains($0) || $0 == range.upperBound })).sorted()

        var atoms: [AtomSpan] = []
        for (a, b) in zip(cuts, cuts.dropFirst()) where b > a {
            let atom: Atom
            if let cause = deletedLine.label(at: a) {
                atom = .deleted(cause)
            } else {
                switch coverageLine.label(at: a) ?? .off {
                case .paused:
                    atom = .paused(
                        userPauseLine.label(at: a) ?? (watchPauseLine.label(at: a) != nil ? .watchPowerSave : .other))
                case .missing: atom = .missing
                case .off: atom = .off
                case .quiet: atom = .quiet
                case .recorded:
                    // Recorded audio no recording claims is treated as not transcribed: it has
                    // no transcript anyone could read, and calling it wordless would be a claim.
                    switch stateLine.label(at: a) ?? .pending {
                    case .failed(let reason): atom = .failed(reason)
                    case .pending: atom = .pending
                    case .transcribed:
                        if let descriptor = contentLine.label(at: a) {
                            atom = .noConversation(descriptor)
                        } else if let segmentId = speechLine.label(at: a) {
                            atom = .speech(segmentId)
                        } else {
                            atom = .noConversation(nil)
                        }
                    }
                }
            }
            if let last = atoms.last, last.atom == atom, last.range.upperBound == a, !chapterBounds.contains(a) {
                atoms[atoms.count - 1].range = last.range.lowerBound..<b
            } else {
                atoms.append(AtomSpan(range: a..<b, atom: atom))
            }
        }
        return atoms
    }

    // MARK: - Pieces: cards claim their ranges, everything else is a gap

    enum GapDetail: Equatable {
        case quiet
        case paused(HistoryPauseActor)
        case audioMissing
        case notRecording
        case noConversation(String?)
        case notTranscribedYet
        case transcriptionFailed(String?)
        case deleted(HistoryDeletionCause)

        init(_ atom: Atom) {
            switch atom {
            case .deleted(let cause): self = .deleted(cause)
            case .paused(let actor): self = .paused(actor)
            case .missing: self = .audioMissing
            case .off: self = .notRecording
            case .quiet: self = .quiet
            case .pending: self = .notTranscribedYet
            case .failed(let reason): self = .transcriptionFailed(reason)
            case .noConversation(let descriptor): self = .noConversation(descriptor)
            // Unreachable: every unclaimed word starts or joins a stretch (`pieces`). Recorded,
            // transcribed and in no card would be wordless time, so that is what it is called.
            case .speech: self = .noConversation(nil)
            }
        }

        var kind: HistoryGap.Kind {
            switch self {
            case .quiet: return .quiet
            case .paused: return .paused
            case .audioMissing: return .audioMissing
            case .notRecording: return .notRecording
            case .noConversation: return .noConversation
            case .notTranscribedYet: return .notTranscribedYet
            case .transcriptionFailed: return .transcriptionFailed
            case .deleted: return .deleted
            }
        }
    }

    struct CardSeed: Equatable {
        var id: String
        /// Pieces of one chapter, or stretches of one conversation, that end up side by side
        /// (after a sliver between them folds) are one card again.
        var groupKey: String
        var source: HistoryChapterBlock.Source
        var title: String?
        var summary: String?
        var tags: [String] = []
        var people: [String] = []
        var timesApproximate = false
    }

    struct Piece: Equatable {
        enum Content: Equatable {
            case card(CardSeed)
            case gap(GapDetail)
        }
        var start: Int64
        var end: Int64
        var content: Content
        /// Loss inside this piece that is not its own item: a card's always; a gap's only under
        /// `HistoryDayRules.carryShortLoss`. Never dropped, only summed.
        var missingMs: Int64 = 0
        /// What this piece has taken in by folding, so a later fold cannot pass it on to a
        /// neighbour that could not have taken it directly (unrecorded time → failed → quiet
        /// would make "off" quiet; untranscribed → quiet → card would put it inside a card).
        var holdsUnrecorded = false
        var holdsUntranscribed = false

        var duration: Int64 { end - start }
        var gap: GapDetail? {
            if case .gap(let detail) = content { return detail }
            return nil
        }
        var card: CardSeed? {
            if case .card(let seed) = content { return seed }
            return nil
        }
    }

    static func pieces(atoms: [AtomSpan], input: Input) -> [Piece] {
        guard let domainStart = atoms.first?.range.lowerBound, let domainEnd = atoms.last?.range.upperBound else {
            return []
        }
        var claimed = [Bool](repeating: false, count: atoms.count)
        var cards: [(range: Range<Int64>, seed: CardSeed)] = []

        // Rule 7: chapters, cut at every barrier inside them.
        var chapterFloor = domainStart
        for chapter in input.chapters.sorted(by: { $0.startMs < $1.startMs }) {
            let lower = max(chapter.startMs, chapterFloor)
            guard chapter.endMs > lower, let range = clip(lower..<chapter.endMs, to: domainStart..<domainEnd)
            else { continue }
            chapterFloor = range.upperBound
            var pieceStart: Int64?
            var pieceIndex = 0
            func close(at end: Int64) {
                guard let start = pieceStart else { return }
                let id = pieceIndex == 0 ? chapter.id : "\(chapter.id)~\(start)"
                cards.append((
                    start..<end,
                    CardSeed(
                        id: id, groupKey: "chapter:\(chapter.id)", source: .chapter, title: chapter.title,
                        summary: chapter.summary, tags: chapter.tags, people: chapter.people,
                        timesApproximate: chapter.timesApproximate)
                ))
                pieceIndex += 1
                pieceStart = nil
            }
            for index in atoms.indices where atoms[index].range.lowerBound < range.upperBound
                && atoms[index].range.upperBound > range.lowerBound
            {
                let atom = atoms[index]
                if atom.atom.isBarrier {
                    close(at: atom.range.lowerBound)
                } else {
                    claimed[index] = true
                    if pieceStart == nil { pieceStart = atom.range.lowerBound }
                }
            }
            close(at: range.upperBound)
        }

        // Rule 9: talk no chapter covers. A stretch runs while less than `talkBridgeMs` separates
        // one run of words from the next and nothing between them cuts it; `HistoryTalkCutter`
        // then cuts it where the talk really stopped. The grouper's conversations play no part:
        // its boundaries (and so its titles) are not conversation-sized — one "conversation" in
        // the 2026-09-30 backup runs 24 h 53 min.
        func bridgeable(_ from: Int, _ to: Int) -> Bool {
            // Atoms strictly between two speech atoms: only quiet, wordless recorded time and
            // loss, and none of it inside a chapter. Plus one exception: a hole with nothing
            // recorded that is shorter than `foldBelowMs` — the seconds between two 15-minute
            // recordings of one stream. The tidy step would fold such a sliver into the card
            // anyway (`canFold`), but only once the stretch had already been cut at it.
            guard from + 1 < to else { return true }
            for index in (from + 1)..<to {
                if claimed[index] { return false }
                switch atoms[index].atom {
                case .quiet, .missing, .noConversation: continue
                case .off where atoms[index].range.upperBound - atoms[index].range.lowerBound < input.rules.foldBelowMs:
                    continue
                default: return false
                }
            }
            return true
        }
        var stretches: [[Int]] = []  // the speech atoms of each stretch
        for index in atoms.indices where !claimed[index] {
            guard case .speech = atoms[index].atom else { continue }
            if let current = stretches.last, let lastIndex = current.last,
                atoms[index].range.lowerBound - atoms[lastIndex].range.upperBound < input.rules.talkBridgeMs,
                bridgeable(lastIndex, index)
            {
                stretches[stretches.count - 1].append(index)
            } else {
                stretches.append([index])
            }
        }
        let states = input.segmentStates.sorted {
            $0.startMs != $1.startMs ? $0.startMs < $1.startMs : $0.segmentId < $1.segmentId
        }
        for stretch in stretches {
            let range = atoms[stretch.first!].range.lowerBound..<atoms[stretch.last!].range.upperBound
            let runs = stretch.map { atoms[$0].range }
            let bounds = [range.lowerBound]
                + HistoryTalkCutter.cuts(stretch: range, speechRuns: runs, rules: input.rules.talkCut)
                + [range.upperBound]
            for (start, end) in zip(bounds, bounds.dropFirst()) {
                // Stable id: the first recording overlapping the piece (segment ids survive a
                // regroup; conversation ids do not), and where the piece starts.
                let anchor =
                    states.first { $0.startMs < end && $0.endMs > start }?.segmentId
                    ?? stretch.lazy.compactMap { index -> String? in
                        if case .speech(let segmentId) = atoms[index].atom, atoms[index].range.lowerBound >= start {
                            return segmentId
                        }
                        return nil
                    }.first ?? "-"
                let id = "talk-\(anchor)-\(start)"
                cards.append((
                    start..<end,
                    CardSeed(id: id, groupKey: id, source: .conversation, title: nil, summary: nil)
                ))
            }
        }
        cards.sort { $0.range.lowerBound < $1.range.lowerBound }

        // Lay it out: a card takes its whole range (its loss becomes `missingMs`); every other
        // atom is a gap of its own kind.
        var pieces: [Piece] = []
        var cardIndex = 0
        var index = 0
        while index < atoms.count {
            let atom = atoms[index]
            if cardIndex < cards.count, cards[cardIndex].range.lowerBound <= atom.range.lowerBound {
                let card = cards[cardIndex]
                var missing: Int64 = 0
                while index < atoms.count, atoms[index].range.lowerBound < card.range.upperBound {
                    if atoms[index].atom == .missing {
                        missing += atoms[index].range.upperBound - atoms[index].range.lowerBound
                    }
                    index += 1
                }
                pieces.append(
                    Piece(
                        start: card.range.lowerBound, end: card.range.upperBound,
                        content: .card(card.seed), missingMs: missing))
                cardIndex += 1
                continue
            }
            var piece = Piece(start: atom.range.lowerBound, end: atom.range.upperBound, content: .gap(GapDetail(atom.atom)))
            switch atom.atom {
            case .off: piece.holdsUnrecorded = true
            case .pending, .failed: piece.holdsUntranscribed = true
            default: break
            }
            pieces.append(piece)
            index += 1
        }
        return pieces
    }

    // MARK: - Tidy

    static func tidy(_ input: [Piece], rules: HistoryDayRules) -> [Piece] {
        var pieces = merged(input)
        if rules.carryShortLoss {
            pieces = merged(carryingShortLoss(pieces, rules: rules))
        }
        pieces = merged(applyingNoConversationMinimum(pieces, rules: rules))
        pieces = folded(pieces, rules: rules)
        return pieces
    }

    /// `HistoryDayRules.carryShortLoss`: a loss item shorter than `foldBelowMs` next to a card
    /// or to recorded time (quiet, no conversation, not transcribed yet, transcription failed)
    /// becomes that neighbour's `missingMs` — the way loss inside a card already is. The loss is
    /// still counted to the millisecond and still named; what goes is a separate row for every
    /// second the watch's buffer dropped.
    static func carryingShortLoss(_ input: [Piece], rules: HistoryDayRules) -> [Piece] {
        func carries(_ piece: Piece) -> Bool {
            if piece.card != nil { return true }
            switch piece.gap {
            case .quiet?, .noConversation?, .notTranscribedYet?, .transcriptionFailed?: return true
            default: return false
            }
        }
        var pieces = input
        var index = 0
        while index < pieces.count {
            guard pieces[index].gap == .audioMissing, pieces[index].duration < rules.foldBelowMs else {
                index += 1
                continue
            }
            // The longer of the neighbours that can carry it.
            let candidates = [index - 1, index + 1].filter { pieces.indices.contains($0) && carries(pieces[$0]) }
            guard let target = candidates.max(by: { pieces[$0].duration < pieces[$1].duration }) else {
                index += 1
                continue
            }
            let lost = pieces[index].duration
            if target < index {
                pieces[target].end = pieces[index].end
            } else {
                pieces[target].start = pieces[index].start
            }
            pieces[target].missingMs += lost
            pieces.remove(at: index)
            // Rejoin what the loss had split (pending | loss | pending), then look again here.
            pieces = merged(pieces)
            index = max(0, min(index, target) - 1)
        }
        return pieces
    }

    /// Neighbours of the same kind (same actor, descriptor, reason) join; so do pieces of one
    /// card group, whose loss adds up.
    static func merged(_ pieces: [Piece]) -> [Piece] {
        var result: [Piece] = []
        result.reserveCapacity(pieces.count)
        for piece in pieces {
            guard var last = result.last, last.end == piece.start else {
                result.append(piece)
                continue
            }
            switch (last.content, piece.content) {
            case (.gap(let a), .gap(let b)) where a == b: break
            case (.card(let a), .card(let b)) where a.groupKey == b.groupKey: break
            default:
                result.append(piece)
                continue
            }
            last.end = piece.end
            last.missingMs += piece.missingMs
            last.holdsUnrecorded = last.holdsUnrecorded || piece.holdsUnrecorded
            last.holdsUntranscribed = last.holdsUntranscribed || piece.holdsUntranscribed
            result[result.count - 1] = last
        }
        return result
    }

    /// Recorded sound with nothing said is its own item only when a run of it (quiet holes up to
    /// `noConversationHoleMs` bridged) lasts `noConversationMinimumMs`; shorter runs are part of
    /// the quiet around them. Only no-conversation and those short quiet holes are ever touched:
    /// loss, a pause or unrecorded time ends the run and is left exactly as it is.
    static func applyingNoConversationMinimum(_ pieces: [Piece], rules: HistoryDayRules) -> [Piece] {
        var result = pieces
        var index = 0
        while index < result.count {
            guard case .noConversation(let descriptor)? = result[index].gap else {
                index += 1
                continue
            }
            // Extend the run: [noConversation] ([quiet <= hole] [noConversation])*
            var end = index
            var probe = index + 1
            while probe + 1 < result.count, result[probe].gap == .quiet,
                result[probe].duration <= rules.noConversationHoleMs,
                result[probe + 1].gap == .noConversation(descriptor)
            {
                end = probe + 1
                probe += 2
            }
            let span = result[end].end - result[index].start
            if span >= rules.noConversationMinimumMs {
                result[index].end = result[end].end
                if end > index {
                    // Whatever loss the joined pieces carried stays counted.
                    result[index].missingMs += result[(index + 1)...end].reduce(0) { $0 + $1.missingMs }
                    result.removeSubrange((index + 1)...end)
                }
                index += 1
            } else {
                for position in index...end where result[position].gap == .noConversation(descriptor) {
                    result[position].content = .gap(.quiet)
                }
                index = end + 1
            }
        }
        return result
    }

    /// Whether a short item may be drawn as part of a neighbour. Only where the neighbour's claim
    /// stays true of the item's time — so loss never folds (and nothing folds into loss), unrecorded
    /// time never becomes quiet, and a recording without a transcript never goes inside a card.
    static func canFold(_ item: Piece, into target: Piece, otherNeighbour: Piece? = nil) -> Bool {
        guard let detail = item.gap else { return false }
        // What the item has already taken in travels with it.
        if item.holdsUnrecorded, target.gap == .quiet { return false }
        if item.holdsUntranscribed, target.card != nil { return false }
        // A recorded sliver that says nothing (no card, no loss) may be drawn as part of the
        // watch's power save or of time nothing recorded beside it, so a 14-second blip cannot
        // keep a five-hour night out of the edge. Only a sliver standing ALONE: with recorded
        // time on its other side it joins that instead, or two slivers side by side would hand
        // minutes of audio to "nobody was listening". Never a card, never into a pause the
        // person made or a deletion.
        if item.missingMs == 0, !(otherNeighbour.map(isRecorded) ?? false) {
            switch (detail, target.gap) {
            case (.quiet, .paused(.watchPowerSave)?), (.quiet, .notRecording?),
                (.noConversation, .paused(.watchPowerSave)?), (.noConversation, .notRecording?),
                (.notTranscribedYet, .paused(.watchPowerSave)?), (.notTranscribedYet, .notRecording?),
                (.transcriptionFailed, .paused(.watchPowerSave)?), (.transcriptionFailed, .notRecording?):
                return true
            default: break
            }
        }
        switch detail {
        case .quiet, .notRecording:
            // A card's range, wordless recorded time, or a recording waiting for (or failed at)
            // its transcript may span a sliver of quiet or of nothing recorded. Quiet may never
            // take unrecorded time ("off is never quiet").
            if target.card != nil { return true }
            switch target.gap {
            case .noConversation?, .notTranscribedYet?, .transcriptionFailed?: return true
            default: return false
            }
        case .notTranscribedYet, .transcriptionFailed:
            // Recorded audio: calm recorded neighbours may take it; a card may not.
            switch target.gap {
            case .quiet?, .noConversation?: return true
            default: return false
            }
        case .noConversation:
            // Only reachable with a threshold below `foldBelowMs`; it is wordless recorded time.
            if target.card != nil { return true }
            return target.gap == .quiet
        case .audioMissing, .deleted, .paused:
            // Loss is never absorbed. A deletion is a fact the person made. A pause is a record
            // of nobody listening, and no neighbour can say that for it.
            return false
        }
    }

    /// A card, or a gap that stands for recorded audio.
    static func isRecorded(_ piece: Piece) -> Bool {
        if piece.card != nil { return true }
        switch piece.gap {
        case .quiet?, .noConversation?, .notTranscribedYet?, .transcriptionFailed?: return true
        default: return false
        }
    }

    static func folded(_ input: [Piece], rules: HistoryDayRules) -> [Piece] {
        var pieces = input
        while true {
            // Shortest foldable item first, so a sliver joins its neighbour before that
            // neighbour is itself measured.
            var best: (index: Int, target: Int)?
            for index in pieces.indices where pieces[index].duration < rules.foldBelowMs {
                let candidates = [index - 1, index + 1].filter {
                    let other = $0 < index ? index + 1 : index - 1
                    return pieces.indices.contains($0)
                        && canFold(
                            pieces[index], into: pieces[$0],
                            otherNeighbour: pieces.indices.contains(other) ? pieces[other] : nil)
                }
                guard let target = candidates.max(by: { pieces[$0].duration < pieces[$1].duration }) else { continue }
                if best == nil || pieces[index].duration < pieces[best!.index].duration {
                    best = (index, target)
                }
            }
            guard let (index, target) = best else { return pieces }
            if target < index {
                pieces[target].end = pieces[index].end
            } else {
                pieces[target].start = pieces[index].start
            }
            pieces[target].missingMs += pieces[index].missingMs
            pieces[target].holdsUnrecorded = pieces[target].holdsUnrecorded || pieces[index].holdsUnrecorded
            pieces[target].holdsUntranscribed = pieces[target].holdsUntranscribed || pieces[index].holdsUntranscribed
            pieces.remove(at: index)
            pieces = merged(pieces)
        }
    }

    // MARK: - Edges, zones, live

    struct BuiltWindow {
        var zoneID: String
        var pieces: [Piece]
        var hasAnything: Bool
        /// Sorted by start; what `causes(of:records:)` reads.
        var lossRecords: [CoverageGapRecord]
    }

    /// A piece of the day, or a zone divider, and the window it came from.
    struct Entry {
        var piece: Piece?
        var zoneChangeAt: Int64?
        var zoneID: String
        var window: Int

        init(piece: Piece, zoneID: String, window: Int) {
            self.piece = piece
            self.zoneID = zoneID
            self.window = window
        }

        init(zoneChangeAt: Int64, zoneID: String, window: Int) {
            self.zoneChangeAt = zoneChangeAt
            self.zoneID = zoneID
            self.window = window
        }
    }

    /// Calm time: nobody said anything and nothing went wrong — quiet, unrecorded time, the
    /// watch resting in power save. The only time an edge may hold.
    static func isCalm(_ piece: Piece) -> Bool {
        guard piece.missingMs == 0 else { return false }
        switch piece.gap {
        case .quiet?, .notRecording?, .paused(.watchPowerSave)?: return true
        default: return false
        }
    }

    static func edgeKind(_ stripped: [Piece]) -> HistoryEdge.Kind {
        let quiet = stripped.filter { $0.gap == .quiet }.map(\.duration).reduce(0, +)
        let total = stripped.map(\.duration).reduce(0, +)
        return quiet * 2 > total ? .quiet : .notListening
    }

    static func withoutStrayZoneChanges(_ entries: [Entry]) -> [Entry] {
        var result: [Entry] = []
        for entry in entries {
            if entry.piece == nil {
                // Only between two items, and only the last of several in a row.
                guard result.contains(where: { $0.piece != nil }) else { continue }
                if result.last?.piece == nil { result.removeLast() }
            }
            result.append(entry)
        }
        while let last = result.last, last.piece == nil { result.removeLast() }
        return result
    }

    /// Today while recording: the unsettled tail — the recording still waiting for its
    /// transcript, and the quiet inside it — becomes the live block. A card is never taken into
    /// it (settled talk shows as it settles, and a card's missing time would go with it), and
    /// nor is loss or anything after it.
    static func liveTail(_ entries: [Entry], nowMs: Int64) -> ([Entry], HistoryLiveBlock) {
        var start: Int?
        var index = entries.count - 1
        scan: while index >= 0, let piece = entries[index].piece, piece.missingMs == 0 {
            switch piece.gap {
            case .notTranscribedYet?: start = index
            case .quiet?, .noConversation?: break
            default: break scan
            }
            index -= 1
        }
        let lastEnd = entries.last(where: { $0.piece != nil })?.piece?.end ?? nowMs
        guard let start else {
            // Nothing unsettled: the block marks now, with no length.
            return (entries, HistoryLiveBlock(startMs: lastEnd, endMs: max(nowMs, lastEnd), zoneID: entries.last?.zoneID ?? "UTC"))
        }
        let begin = entries[start].piece!.start
        let zone = entries[start].zoneID
        return (Array(entries[..<start]), HistoryLiveBlock(startMs: begin, endMs: max(nowMs, lastEnd), zoneID: zone))
    }

    // MARK: - Output

    static func item(_ piece: Piece, zoneID: String, lossRecords: [CoverageGapRecord]) -> HistoryItem {
        switch piece.content {
        case .card(let seed):
            return .chapter(
                HistoryChapterBlock(
                    id: seed.id, startMs: piece.start, endMs: piece.end, zoneID: zoneID, source: seed.source,
                    title: seed.title, summary: seed.summary, tags: seed.tags, people: seed.people,
                    missingMs: piece.missingMs, timesApproximate: seed.timesApproximate))
        case .gap(let detail):
            var gap = HistoryGap(
                id: "\(detail.kind.rawValue)-\(piece.start)", kind: detail.kind, startMs: piece.start,
                endMs: piece.end, zoneID: zoneID)
            if piece.missingMs > 0 {
                gap.missingMs = piece.missingMs
                gap.lossCauses = causes(of: piece.start..<piece.end, records: lossRecords)
            }
            switch detail {
            case .paused(let actor): gap.pausedBy = actor
            case .audioMissing: gap.lossCauses = causes(of: piece.start..<piece.end, records: lossRecords)
            case .noConversation(let descriptor):
                gap.descriptor = descriptor
                gap.isOpenable = true
            case .notTranscribedYet: gap.isOpenable = true
            case .transcriptionFailed(let reason):
                gap.failureReason = reason
                gap.isOpenable = true
            case .deleted(let cause): gap.deletedBy = cause
            case .quiet, .notRecording: break
            }
            return .gap(gap)
        }
    }

    /// A fallback card's snippet, verbatim (`previews` is sorted by start). Among the turns in
    /// the card's first five minutes: the first that is long enough to say something (8 words or
    /// more), else the longest; with no turn in those five minutes, the first turn of the card
    /// with 4 words or more; else nil.
    ///
    /// Words are whitespace-separated, which is right for languages written with spaces. Text
    /// with no whitespace at all (Chinese, Japanese, Thai; Korean usually has spaces) counts as
    /// 8 words from 12 characters and as 4 words from 6 — simple, and enough to skip "嗯" and
    /// "はい" without a tokenizer. The 4-word threshold alone picked "That sounds fine then." and
    /// "I left it outside." on the real backup.
    static func snippet(in range: Range<Int64>, previews: [HistoryTurnPreview]) -> String? {
        var low = 0
        var high = previews.count
        while low < high {
            let mid = (low + high) / 2
            if previews[mid].startMs < range.lowerBound { low = mid + 1 } else { high = mid }
        }
        func words(_ text: String) -> Int {
            let parts = text.split(whereSeparator: \.isWhitespace)
            guard parts.count == 1 else { return parts.count }
            // One unbroken token: a spaceless script (or one long word).
            let characters = parts[0].count
            return characters >= 12 ? 8 : (characters >= 6 ? 4 : 1)
        }
        let earlyEnd = range.lowerBound + 5 * 60_000
        var longest: HistoryTurnPreview?
        var longestCount = 0
        var fallback: HistoryTurnPreview?
        var index = low
        while index < previews.count, previews[index].startMs < range.upperBound {
            let preview = previews[index]
            let text = preview.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let count = words(text)
            if preview.startMs < earlyEnd {
                if count >= 8 { return preview.text }
                if !text.isEmpty, text.count > longestCount {
                    longest = preview
                    longestCount = text.count
                }
            } else {
                if let longest { return longest.text }
                if count >= 4 { return preview.text }
            }
            if fallback == nil, count >= 4 { fallback = preview }
            index += 1
        }
        return longest?.text ?? fallback?.text
    }

    /// The recorded causes of the loss in a range, largest share first, each once. `records` is
    /// sorted by start.
    static func causes(of range: Range<Int64>, records: [CoverageGapRecord]) -> [HistoryLossCause] {
        var share: [HistoryLossCause: Int64] = [:]
        for record in records {
            if record.range.lowerBound >= range.upperBound { break }
            guard let overlap = clip(record.range, to: range), let cause = lossCause(of: record.gap) else { continue }
            share[cause, default: 0] += overlap.upperBound - overlap.lowerBound
        }
        let order = HistoryLossCause.allCases
        return share.keys.sorted {
            share[$0]! != share[$1]! ? share[$0]! > share[$1]! : order.firstIndex(of: $0)! < order.firstIndex(of: $1)!
        }
    }

    /// A follow-up said at a moment belongs to the card containing it; one said across a span,
    /// to the card holding at least `share` of it; otherwise to none (the day still counts it).
    static func attachingFollowUps(
        _ followUps: [HistoryFollowUpInput], to items: [HistoryItem], share: Double
    ) -> [HistoryItem] {
        guard !followUps.isEmpty else { return items }
        var attached: [Int: [(line: HistoryFollowUpLine, atMs: Int64)]] = [:]
        let cards = items.indices.compactMap { index -> (Int, HistoryChapterBlock)? in
            if case .chapter(let block) = items[index] { return (index, block) }
            return nil
        }
        for followUp in followUps {
            let line = HistoryFollowUpLine(
                id: followUp.id, text: followUp.text, done: followUp.done, isSnoozed: followUp.isSnoozed,
                isApproximate: followUp.isApproximate)
            let target: (index: Int, atMs: Int64)?
            switch followUp.placement {
            case .dayOnly:
                target = nil
            case .moment(let atMs):
                target = cards.first { $0.1.startMs <= atMs && atMs < $0.1.endMs }.map { ($0.0, atMs) }
            case .span(let startMs, let endMs) where endMs <= startMs:
                target = cards.first { $0.1.startMs <= startMs && startMs < $0.1.endMs }.map { ($0.0, startMs) }
            case .span(let startMs, let endMs):
                let length = Double(endMs - startMs)
                target = cards.first { card in
                    let overlap = min(card.1.endMs, endMs) - max(card.1.startMs, startMs)
                    return overlap > 0 && Double(overlap) >= share * length
                }.map { ($0.0, startMs) }
            }
            if let target { attached[target.index, default: []].append((line, target.atMs)) }
        }
        var result = items
        for (index, lines) in attached {
            guard case .chapter(var block) = result[index] else { continue }
            block.followUps = lines.sorted {
                if $0.line.done != $1.line.done { return !$0.line.done }
                if $0.atMs != $1.atMs { return $0.atMs < $1.atMs }
                return $0.line.id < $1.line.id
            }.map(\.line)
            result[index] = .chapter(block)
        }
        return result
    }
}

// MARK: - A labelled partition of time

/// Possibly-overlapping labelled ranges flattened into disjoint pieces (where two overlap,
/// `better` picks the label; otherwise the earlier-listed one keeps it), answering "which label
/// covers this moment" by binary search.
struct IntervalLine<Label: Equatable> {
    private(set) var starts: [Int64] = []
    private(set) var ends: [Int64] = []
    private(set) var labels: [Label] = []

    init(flattening ranges: [(Range<Int64>, Label)], better: (Label, Label) -> Bool) {
        let items = ranges.enumerated().filter { !$0.element.0.isEmpty }
            .sorted { $0.element.0.lowerBound != $1.element.0.lowerBound
                ? $0.element.0.lowerBound < $1.element.0.lowerBound : $0.offset < $1.offset }
        guard !items.isEmpty else { return }
        let cuts = Array(Set(items.flatMap { [$0.element.0.lowerBound, $0.element.0.upperBound] })).sorted()
        var active: [(order: Int, range: Range<Int64>, label: Label)] = []
        var next = 0
        for (a, b) in zip(cuts, cuts.dropFirst()) {
            while next < items.count, items[next].element.0.lowerBound <= a {
                active.append((items[next].offset, items[next].element.0, items[next].element.1))
                next += 1
            }
            active.removeAll { $0.range.upperBound <= a }
            guard var pick = active.first else { continue }
            for candidate in active.dropFirst() {
                if better(candidate.label, pick.label)
                    || (!better(pick.label, candidate.label) && candidate.order < pick.order)
                {
                    pick = candidate
                }
            }
            if let lastEnd = ends.last, lastEnd == a, labels.last == pick.label {
                ends[ends.count - 1] = b
            } else {
                starts.append(a)
                ends.append(b)
                labels.append(pick.label)
            }
        }
    }

    var bounds: [Int64] { starts + ends }

    func label(at ms: Int64) -> Label? {
        var low = 0
        var high = starts.count - 1
        var found = -1
        while low <= high {
            let mid = (low + high) >> 1
            if starts[mid] <= ms {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        guard found >= 0, ms < ends[found] else { return nil }
        return labels[found]
    }
}
