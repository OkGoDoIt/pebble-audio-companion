import Foundation
import Intelligence

// Ask's recall experiment, app side: where the records live, and the replay that runs recent
// questions through both rankers so recall can be judged on real data.
//
// The kit measures (`AskRecallExperiment`) and the Ask flow records; this file is the reader.
// Nothing here calls a model — the replay is retrieval only, which is what makes it cheap
// enough to run over every recent question from a Diagnostics row.

/// The one ledger this process writes and reads: the App Group defaults, so the records
/// survive a relaunch and a side-by-side install reads its own.
enum AskRecallLedgerHolder {
    static let shared = AskRecallLedger(
        defaults: UserDefaults(suiteName: AppSettings.suiteName) ?? .standard)
}

/// What both index passes found for one replayed question, as the Diagnostics row shows it:
/// counts, and the conversations only one side found — named, so a person can judge whether
/// the semantic pass is finding things that matter or things that merely rhyme.
struct AskRecallReplayRow: Identifiable, Equatable {
    let id: String
    let question: String
    let keyword: Int
    let semantic: Int
    let both: Int
    let semanticRan: Bool
    /// Titles of conversations only the semantic pass found, best first (a handful).
    let semanticOnlyTitles: [String]
    /// Titles of conversations only the keyword pass found, best first (a handful).
    let keywordOnlyTitles: [String]

    var union: Int { keyword + semantic - both }
}

enum AskRecallReplay {
    /// How many of each side's exclusive finds are named on the row.
    static let namedTitles = 3

    /// Runs every question through both passes. `recall` is the retriever's `recall`;
    /// `title` resolves a conversation id to its title (nil when it no longer exists — a hit on
    /// a deleted conversation is simply not named).
    static func run(
        questions: [String],
        limit: Int,
        recall: (String, Int) async -> AskRetriever.RecallHits,
        title: (String) async -> String?
    ) async -> [AskRecallReplayRow] {
        var rows: [AskRecallReplayRow] = []
        for (index, question) in questions.enumerated() {
            let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let hits = await recall(trimmed, limit)
            let keyword = hits.keyword.map(\.id)
            let semantic = hits.semantic.map(\.id)
            let keywordSet = Set(keyword)
            let semanticSet = Set(semantic)
            // Best first: the hit order is the ranking.
            let semanticOnly = semantic.filter { !keywordSet.contains($0) }
            let keywordOnly = keyword.filter { !semanticSet.contains($0) }
            var semanticTitles: [String] = []
            for id in semanticOnly where semanticTitles.count < namedTitles {
                if let name = await title(id) { semanticTitles.append(name) }
            }
            var keywordTitles: [String] = []
            for id in keywordOnly where keywordTitles.count < namedTitles {
                if let name = await title(id) { keywordTitles.append(name) }
            }
            rows.append(
                AskRecallReplayRow(
                    id: "\(index)-\(trimmed.hashValue)",
                    question: trimmed,
                    keyword: keywordSet.count,
                    semantic: semanticSet.count,
                    both: keywordSet.intersection(semanticSet).count,
                    semanticRan: hits.semanticRan,
                    semanticOnlyTitles: semanticTitles,
                    keywordOnlyTitles: keywordTitles))
        }
        return rows
    }
}
