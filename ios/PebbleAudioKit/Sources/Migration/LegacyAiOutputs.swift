import AppDB
import Foundation
import GRDB
import Intelligence

// Import of the legacy `ai/outputs/*.ai.json` tree (migration phase 6, marker version 2).
//
// Q19 deliberately regenerates the rest of `ai/`: annotations were PER-SEGMENT and the new model
// annotates per CONVERSATION, and the old digests carry raw Markdown headings the rebuild treats
// as a defect (anti-goal B4). `ai/outputs` is the one exception, because nothing regenerates it:
// these are results a PERSON asked for — past Ask questions and template-generated notes — and
// the app only ever produces them when someone taps a button.
//
// What the old `AiOutput` record holds (`core/ai/AiOutputStore.kt`): `outputId`, `requestId`,
// `promptTemplateId`, `promptTitle`, `segmentIds` (the scope it ran over), `text` (the answer),
// `modeUsed`, `providerId`, `modelUsed`, token counts, `createdAtMs`, `userConsentedToRemote`,
// and an optional `editedAtMs`. Everything is optional here so a field the old app omitted (or a
// newer field it never had) cannot fail the import.
//
// The one thing that CANNOT be imported: the question. `AiOutputStore.save` recorded the prompt
// TEMPLATE ("ask" / "Ask"), never the text the user typed — the question was appended to the
// prompt at runtime and thrown away. The answers survive; the questions do not, and the imported
// history says so in plain words rather than inventing something plausible.

struct LegacyAiOutput: Decodable {
    var outputId: String
    var promptTemplateId: String?
    var promptTitle: String?
    var segmentIds: [String]?
    var text: String?
    var providerId: String?
    var modelUsed: String?
    var createdAtMs: Int64?
    var editedAtMs: Int64?

    var isAsk: Bool { (promptTemplateId ?? "").lowercased() == "ask" }

    var trimmedText: String {
        (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var scope: [String] { segmentIds ?? [] }
}

enum LegacyAiOutputImport {
    /// Deterministic primary keys so a re-run (or a run whose marker was lost) inserts nothing
    /// twice, independently of the phase flag.
    static func rowId(_ outputId: String) -> String { "legacy-\(outputId)" }

    /// Stand-in for the question the old store never recorded. Honest, and short enough for the
    /// one-line Recent row in the Ask sheet.
    static let missingQuestionText = "Question not recorded (asked in the previous app)"

    /// Scope label for an imported answer. `AskScope.displayName` values describe a picker
    /// choice the user made; an imported answer had no such choice recorded, so it says what it
    /// actually is.
    static let importedScopeDescription = "Imported from the previous app"

    /// Citation set for an imported answer: the answer's own references resolved against the
    /// scope it ran over (`parseGroundedAnswer` handles `[n]` footnotes, `[seg-…](#)` links and
    /// bare/truncated ids alike), then filtered to segments that still exist. A citation whose
    /// segment is gone would navigate nowhere, so it is dropped rather than written dangling.
    static func citations(
        answerText: String, scopeSegmentIds: [String], resolvable: Set<String>
    ) -> [AskCitation] {
        let cited = parseGroundedAnswer(answerText, sourceIds: scopeSegmentIds).citedSegmentIds
        return askCitations(citedSegmentIds: cited.filter { resolvable.contains($0) })
    }

    /// The conversation an imported NOTE attaches to: the one holding the most of the output's
    /// scope. `notes.conversationId` is NOT NULL, and a wide-scope output (a "Daily summary" run
    /// over 155 segments) has no single home — the plurality conversation is where it is most
    /// findable, and the title records the true breadth so the placement never overstates
    /// itself. Ties break on the conversation id so the choice is deterministic.
    static func dominantConversation(
        scopeSegmentIds: [String], conversationBySegment: [String: String]
    ) -> (conversationId: String, conversationCount: Int)? {
        var counts: [String: Int] = [:]
        for segmentId in scopeSegmentIds {
            guard let conversationId = conversationBySegment[segmentId] else { continue }
            counts[conversationId, default: 0] += 1
        }
        guard
            let best = counts.max(by: { a, b in
                a.value != b.value ? a.value < b.value : a.key > b.key
            })
        else { return nil }
        return (best.key, counts.count)
    }

    /// Note headline. A single-conversation output keeps the template's own title; a wider one
    /// says how far it actually reached.
    static func noteTitle(_ output: LegacyAiOutput, conversationCount: Int) -> String {
        let base = (output.promptTitle?.trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { $0.isEmpty ? nil : $0 } ?? "Imported note"
        return conversationCount > 1 ? "\(base) · \(conversationCount) conversations" : base
    }

    static func citationsJson(_ citations: [AskCitation]) -> String {
        guard let data = try? JSONEncoder().encode(citations) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Per-run counters for the outputs phase.
struct LegacyAiOutputStats: Equatable {
    var filesSeen = 0
    var filesUnreadable = 0
    var askImported = 0
    var notesImported = 0
    /// Outputs whose whole scope resolves to no surviving conversation, so a note would have had
    /// nowhere truthful to live.
    var notesUnplaceable = 0
    /// Citations parsed out of the answers whose segment no longer exists.
    var citationsDropped = 0
    var alreadyPresent = 0
}
