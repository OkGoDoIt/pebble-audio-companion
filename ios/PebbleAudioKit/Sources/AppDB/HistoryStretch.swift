import Foundation

// One block between conversations (2026-10, Roger: "calm down all of the status updates — the
// focus on the timeline should be on the conversations and not on the status").
//
// A day's time that is not a card used to be drawn gap by gap, each with a two-line label; one
// real night drew THIRTEEN labelled blocks between two conversations, most of them seconds long.
// A `HistoryStretch` is the run of consecutive gaps between two things that are not gaps, drawn
// as one block with one quiet label. The detail is not dropped: the axis still draws every
// piece to scale, and a tap lists every piece with its cause.
//
// Pure, and computed once when a day page is made — never in a view body. `HistoryDayBuilder`
// and the honesty checks are unchanged: they run on the uncombined items.

/// A run of consecutive `.gap` items between two items that are not gaps (one gap is a run too).
public struct HistoryStretch: Equatable, Sendable, Identifiable {
    /// In time order; they tile `[startMs, endMs)` exactly, as the day's items do.
    public var parts: [HistoryGap]

    public init(parts: [HistoryGap]) {
        self.parts = parts
    }

    public var id: String { "stretch-" + (parts.first?.id ?? "") }
    public var startMs: Int64 { parts.first?.startMs ?? 0 }
    public var endMs: Int64 { parts.last?.endMs ?? 0 }
    public var zoneID: String { parts.first?.zoneID ?? TimeZone.current.identifier }
    public var durationMs: Int64 { endMs - startMs }

    /// What a stretch's time is, for its label. Loss is a class of its own.
    public enum Class: String, Sendable, CaseIterable {
        /// `quiet`, and `noConversation` without a descriptor.
        case quiet
        /// `noConversation` with a descriptor ("music").
        case described
        case paused
        case notRecording
        case deleted
        /// `audioMissing` pieces and every carried `missingMs`.
        case loss
    }

    /// Every loss in the stretch: the `audioMissing` pieces' time plus the loss carried by the
    /// others (`missingMs`). Nothing is dropped.
    public var lossMs: Int64 {
        parts.reduce(0) { total, part in
            total + (part.kind == .audioMissing ? part.endMs - part.startMs : part.missingMs)
        }
    }

    public var hasLoss: Bool { lossMs > 0 }

    /// Each class's own total inside the stretch.
    public var totals: [Class: Int64] {
        var totals: [Class: Int64] = [:]
        for part in parts {
            let length = part.endMs - part.startMs
            let cls: Class?
            switch part.kind {
            case .quiet: cls = .quiet
            case .noConversation: cls = part.descriptor == nil ? .quiet : .described
            case .paused: cls = .paused
            case .notRecording: cls = .notRecording
            case .deleted: cls = .deleted
            case .audioMissing, .notTranscribedYet, .transcriptionFailed: cls = nil
            }
            if let cls { totals[cls, default: 0] += length }
        }
        let loss = lossMs
        if loss > 0 { totals[.loss] = loss }
        return totals
    }

    /// Whether the quiet class is mostly sound with no conversation rather than quiet.
    public var quietIsMostlyNoConversation: Bool {
        var quiet: Int64 = 0
        var noConversation: Int64 = 0
        for part in parts where part.descriptor == nil {
            if part.kind == .quiet { quiet += part.endMs - part.startMs }
            if part.kind == .noConversation { noConversation += part.endMs - part.startMs }
        }
        return noConversation > quiet
    }

    /// The descriptor holding the most time, for a described-primary label.
    public var dominantDescriptor: String? {
        var byDescriptor: [String: Int64] = [:]
        for part in parts where part.kind == .noConversation {
            if let descriptor = part.descriptor { byDescriptor[descriptor, default: 0] += part.endMs - part.startMs }
        }
        return byDescriptor.max { $0.value < $1.value }?.key
    }

    /// The single piece that opens its own audio, when the stretch is exactly that: it keeps
    /// the old behaviour (chevron on the timeline, tap opens the audio).
    public var singleOpenablePiece: HistoryGap? {
        guard parts.count == 1, let only = parts.first, only.kind == .noConversation, only.isOpenable
        else { return nil }
        return only
    }

    // MARK: The label, as facts

    /// A second class is named only when it holds at least this much time…
    public static let secondClassMinimumMs: Int64 = 30 * 60_000
    /// …and at least this share of the stretch.
    public static let secondClassMinimumShare: Double = 1.0 / 3.0
    /// A quiet-primary stretch shorter than this is drawn bare (the axis only).
    public static let quietBareUnderMs: Int64 = 30 * 60_000
    /// Any stretch shorter than this is drawn bare…
    public static let bareUnderMs: Int64 = 10 * 60_000
    /// …unless it carries at least this much loss, which is always said in words.
    public static let lossWordsFromMs: Int64 = 60_000

    /// What the one label says, before it is put into words.
    public struct Share: Equatable, Sendable {
        public var cls: Class
        public var ms: Int64
        public init(_ cls: Class, _ ms: Int64) {
            self.cls = cls
            self.ms = ms
        }
    }

    public struct Summary: Equatable, Sendable {
        public var primary: Class
        public var primaryMs: Int64
        /// Named only past both thresholds; never loss.
        public var secondary: Share?
        /// The loss to say in words after the label (≥ 1 min, and loss is not the primary).
        public var lossWordsMs: Int64?
        /// No words at all: the axis alone (and the amber tick, if any loss).
        public var isBare: Bool
    }

    public var summary: Summary {
        let totals = self.totals
        // Ties go to the calmer class, in declaration order (quiet first).
        let ordered = Class.allCases.compactMap { cls in totals[cls].map { (cls, $0) } }
        let primary = ordered.max { a, b in
            a.1 != b.1 ? a.1 < b.1 : Class.allCases.firstIndex(of: a.0)! > Class.allCases.firstIndex(of: b.0)!
        } ?? (.quiet, durationMs)
        let secondary = ordered
            .filter { $0.0 != primary.0 && $0.0 != .loss }
            .filter { $0.1 >= Self.secondClassMinimumMs && Double($0.1) >= Double(durationMs) * Self.secondClassMinimumShare }
            .max { $0.1 < $1.1 }
        let loss = lossMs
        let lossWords = primary.0 != .loss && loss >= Self.lossWordsFromMs ? loss : nil
        let bare = loss < Self.lossWordsFromMs
            && (durationMs < Self.bareUnderMs || (primary.0 == .quiet && durationMs < Self.quietBareUnderMs))
        return Summary(
            primary: primary.0, primaryMs: primary.1, secondary: secondary.map { Share($0.0, $0.1) },
            lossWordsMs: lossWords,
            isBare: bare)
    }
}

/// What a day's timeline draws, in order: its items, with every run of gaps as one stretch.
public enum HistoryDayEntry: Equatable, Sendable, Identifiable {
    case item(HistoryItem)
    case stretch(HistoryStretch)

    public var id: String {
        switch self {
        case .item(let item): return item.id
        case .stretch(let stretch): return stretch.id
        }
    }

    public var startMs: Int64 {
        switch self {
        case .item(let item): return item.startMs
        case .stretch(let stretch): return stretch.startMs
        }
    }

    public var endMs: Int64 {
        switch self {
        case .item(let item): return item.endMs
        case .stretch(let stretch): return stretch.endMs
        }
    }
}

public enum HistoryStretches {
    /// The day's items with every run of consecutive gaps folded into one stretch. A run ends at
    /// anything that is not such a gap: a card, the live block, a zone change, and the pending
    /// cards (`notTranscribedYet` / `transcriptionFailed`, drawn as cards). An open-ended gap at
    /// the end of today ("Paused since 2:30 PM") stays its own item.
    public static func combine(_ day: HistoryDay) -> [HistoryDayEntry] {
        var entries: [HistoryDayEntry] = []
        var run: [HistoryGap] = []
        func flush() {
            if !run.isEmpty { entries.append(.stretch(HistoryStretch(parts: run))) }
            run = []
        }
        for (index, item) in day.items.enumerated() {
            let isOpenEnded = day.isToday && index == day.items.count - 1
            if case .gap(let gap) = item, !isPending(gap), !isOpenEnded {
                run.append(gap)
            } else {
                flush()
                entries.append(.item(item))
            }
        }
        flush()
        return entries
    }

    static func isPending(_ gap: HistoryGap) -> Bool {
        gap.kind == .notTranscribedYet || gap.kind == .transcriptionFailed
    }
}
