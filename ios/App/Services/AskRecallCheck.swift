import CoreSpotlight
import Foundation
import Intelligence
import SearchKit

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
    ///
    /// Main-actor because its callers are (the Diagnostics sources) and the closures they hand
    /// in capture main-actor state; the passes themselves await off it.
    @MainActor
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

#if DEBUG
/// Does the OS actually rank this app's donations by MEANING here, or only by words?
///
/// Semantic ranking is an OS capability the app cannot switch on, and whether it is present on
/// a given device or runtime is not something to assume — the whole experiment above is only
/// interesting if it is. So this donates two conversations under our own domain, asks a
/// question that shares no word with either but is plainly about one of them, and reports
/// which came back; then a plain word query as the control that the index and domain filter
/// work at all; then removes both. DEBUG only; it writes to the real index for a second.
enum AskRecallSemanticProbe {
    enum Verdict: Equatable, Sendable {
        /// `CSSearchableIndex.isIndexingAvailable()` is false in this process.
        case indexUnavailable
        /// Not even the word query found its item, with or without the domain filter: the
        /// index took the donation but no query in this process can see it (protection class,
        /// indexing lag, or a process the index does not serve).
        case lexicalMissing
        /// The word query finds its item only WITHOUT the domain filter: the production query
        /// path would see nothing. A bug in `SpotlightSemanticQuery.filterQuery`.
        case filterHidesDonations
        /// Words work; the paraphrase found nothing. Ranking here is lexical only.
        case lexicalOnly
        /// The paraphrase found the right conversation and not the other: semantic ranking
        /// is live on this device.
        case semantic
        /// The paraphrase found the WRONG conversation first.
        case semanticMisranked

        var line: String {
            switch self {
            case .indexUnavailable: return "Index not available in this process"
            case .lexicalMissing: return "Index reachable, query path cannot see donations"
            case .filterHidesDonations: return "Index works; the domain filter hides donations"
            case .lexicalOnly: return "Words match; meaning does not rank here"
            case .semantic: return "Meaning ranking is working"
            case .semanticMisranked: return "Meaning ranked the wrong conversation first"
            }
        }
    }

    static let boilerId = "conv-probe-boiler"
    static let ferryId = "conv-probe-ferry"
    /// Shares no word with either donation; about the boiler one.
    static let paraphrase = "tradesman quote for fixing the hot water system"
    /// A plain word query for the ferry one — the control.
    static let lexical = "ferry island"

    static func run(
        domainIdentifier: String = CoreSpotlightIndexer.domainIdentifier,
        log: @escaping @Sendable (String) -> Void = { AppRuntimeLog.shared.record($0) }
    ) async -> Verdict {
        guard CSSearchableIndex.isIndexingAvailable() else {
            log("ask recall probe: verdict=index-unavailable")
            return .indexUnavailable
        }
        let indexer = CoreSpotlightIndexer()
        let recall = CoreSpotlightSemanticRecall(
            domainIdentifier: domainIdentifier, timeout: .seconds(4), log: log)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let donations = [
            SpotlightDonation(
                entityId: boilerId, kind: .conversation, title: "Plumber visit",
                contentDescription: "The boiler was looked at.",
                textContent: "The plumber came to look at the boiler. He said the heat "
                    + "exchanger is cracked and the repair will cost about four hundred.",
                deepLinkURL: "companion://conversation/\(boilerId)",
                contentCreationDateMs: nowMs),
            SpotlightDonation(
                entityId: ferryId, kind: .conversation, title: "Weekend plans",
                contentDescription: "Ferry and museum.",
                textContent: "We booked the ferry to the island for Saturday morning and "
                    + "the studio walkthrough on Tuesday afternoon.",
                deepLinkURL: "companion://conversation/\(ferryId)",
                contentCreationDateMs: nowMs),
        ]
        let ids = donations.map(\.uniqueIdentifier)
        do {
            try await indexer.donate(donations)
        } catch {
            log("ask recall probe: donate failed \(error)")
            return .lexicalMissing
        }
        let unfiltered = CoreSpotlightSemanticRecall(
            domainIdentifier: nil, timeout: .seconds(4), log: log)
        let verdict = await judge(recall: recall, unfiltered: unfiltered, log: log)
        // Removed before returning, not fire-and-forget: a test process may end at once.
        try? await indexer.remove(uniqueIdentifiers: ids)
        return verdict
    }

    private static func judge(
        recall: CoreSpotlightSemanticRecall, unfiltered: CoreSpotlightSemanticRecall,
        log: @escaping @Sendable (String) -> Void
    ) async -> Verdict {
        // Only the two probe items are judged: on a real device the user's own recordings
        // may outrank both, and that says nothing about whether meaning ranks.
        let probeIds: Set<String> = [boilerId, ferryId]
        func probeHits(
            _ query: String, via recall: CoreSpotlightSemanticRecall
        ) async -> [String] {
            await recall.rank(query: query, limit: 50).map(\.id).filter(probeIds.contains)
        }

        // The donation completes before the query path can see it; give it a moment.
        var control: [String] = []
        for _ in 0..<12 where !control.contains(ferryId) {
            control = await probeHits(lexical, via: recall)
            if control.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
        }
        guard control.contains(ferryId) else {
            // Tell a filter that hides everything from an index no query here can read.
            let bare = await probeHits(lexical, via: unfiltered)
            let verdict: Verdict = bare.contains(ferryId) ? .filterHidesDonations : .lexicalMissing
            log("ask recall probe: verdict=\(verdict) control=\(control) unfiltered=\(bare)")
            return verdict
        }

        let hits = await probeHits(paraphrase, via: recall)
        let verdict: Verdict
        if hits.first == boilerId {
            verdict = .semantic
        } else if hits.isEmpty {
            verdict = .lexicalOnly
        } else {
            verdict = .semanticMisranked
        }
        log("ask recall probe: verdict=\(verdict) control=\(control) paraphrase=\(hits)")
        return verdict
    }
}
#endif
