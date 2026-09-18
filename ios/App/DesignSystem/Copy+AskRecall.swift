import Foundation

// Settings · Diagnostics → "Ask recall check".
//
// When a question's range is too large to read in full, Ask has to choose what to leave out.
// It has always chosen by keyword match; it now also asks the on-device semantic index, and
// the semantic answer may only ever ADD a conversation, never remove one keyword evidence
// would have kept. This card is where that claim is checked against real questions: what each
// pass found, what only one of them found, and whether the extra findings were read. The
// vocabulary is "keyword" and "meaning" — the reader is judging recall, not learning the
// name of an index.
extension Copy.Settings.Diagnostics {
    enum AskRecall {
        static let header = "Ask recall"
        static let row = "Ask recall check"
        /// Nothing recorded yet: the ordinary library is read whole, so this stays empty until
        /// a question's range overflowed what one answer can read.
        static let noRecords = "No question has needed it yet"
        /// The semantic pass is not wired in this build (never the case in production; the
        /// row says so rather than reporting zero as if it had looked).
        static let semanticUnavailable = "Meaning search not available"

        /// "Sep 18 · 3:12 PM"
        static func when(day: String, time: String) -> String { "\(day) · \(time)" }

        /// The outcome line under a recorded question.
        static func recordDetail(
            keptBatches: Int, packedBatches: Int, keyword: Int, semantic: Int, both: Int,
            rescued: Int, lost: Int, semanticRan: Bool
        ) -> String {
            var parts = ["read \(keptBatches) of \(packedBatches) parts"]
            parts.append("keyword \(keyword)")
            parts.append(semanticRan ? "meaning \(semantic)" : "meaning off")
            if semanticRan { parts.append("both \(both)") }
            if rescued > 0 { parts.append(rescued == 1 ? "1 rescued" : "\(rescued) rescued") }
            if lost > 0 {
                parts.append(lost == 1 ? "1 keyword match lost" : "\(lost) keyword matches lost")
            }
            return parts.joined(separator: " · ")
        }

        // ── DEBUG replay ─────────────────────────────────────────────────────────────
        static let replay = "Replay recent questions"
        static let replayBusy = "Replaying…"
        static let replaySubtitle =
            "Runs each recent question through the keyword and meaning searches over the "
            + "whole library. No AI calls; nothing is answered or saved."
        static let replayNothing = "No recent questions to replay"
        static let replayFailed = "Could not replay — see the detailed log"

        /// "keyword 9 · meaning 7 · both 4 · together 12"
        static func replayDetail(keyword: Int, semantic: Int, both: Int, semanticRan: Bool) -> String {
            guard semanticRan else { return "keyword \(keyword) · meaning off" }
            return "keyword \(keyword) · meaning \(semantic) · both \(both) "
                + "· together \(keyword + semantic - both)"
        }
        static let onlyMeaningFound = "Only meaning found:"
        static let onlyKeywordFound = "Only keyword found:"

        static let probe = "Check meaning search"
        static let probeBusy = "Checking…"
        static let probeSubtitle =
            "Adds two test conversations to the on-device index, asks about one of them in "
            + "different words, then removes both."

        static let footer =
            "When a question's range is too large to read in full, Ask keeps the parts that "
            + "match by keyword first, then by meaning. Meaning can only add a conversation, "
            + "never remove one. \"Rescued\" counts conversations only meaning found that were "
            + "read; \"lost\" counts keyword matches there was no room for either way."
    }
}
