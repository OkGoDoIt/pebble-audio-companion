import AppDB
import Foundation
import GRDB
import SegmentStore
import Testing
import Transcription

@testable import Migration

// Phase 6: `ai/outputs` — the only part of the legacy `ai/` tree that is imported rather than
// regenerated, because a PERSON asked for each of these. Annotations, action items and digests
// all regenerate by design (Q19); nothing regenerates a question someone typed.

/// Row views over the two authoritative tables. The stores' own row mappers are internal to
/// AppDB, so the tests read the columns they assert on directly.
struct ImportedAsk {
    var id: String
    var question: String
    var answerText: String
    var citations: [AskCitation]
    var scopeDescription: String
    var createdAtMs: Int64

    init(row: Row) {
        id = row["id"]
        question = row["question"]
        answerText = row["answerText"]
        let json: String = row["citations"]
        citations = (try? JSONDecoder().decode([AskCitation].self, from: Data(json.utf8))) ?? []
        scopeDescription = row["scopeDescription"]
        createdAtMs = row["createdAtMs"]
    }
}

struct ImportedNote {
    var id: String
    var conversationId: String
    var templateId: String
    var title: String
    var body: String
    var provider: String?
    var model: String?
    var createdAtMs: Int64

    init(row: Row) {
        id = row["id"]
        conversationId = row["conversationId"]
        templateId = row["templateId"]
        title = row["title"]
        body = row["body"]
        provider = row["provider"]
        model = row["model"]
        createdAtMs = row["createdAtMs"]
    }
}

@Suite struct LegacyAiOutputsImportTests {

    /// Seeds a closed, transcribed segment so an output's scope resolves to a conversation.
    @discardableResult
    private func segment(_ env: MigrationTestEnv, _ id: String, at ms: UInt64) throws -> String {
        try writeLegacySegment(
            root: env.root, id: id, startTimeMs: ms, receivedAtMs: Int64(ms),
            transcriptionState: .complete)
        try writeLegacyTranscript(root: env.root, segmentId: id)
        return id
    }

    private func askRows(_ db: AppDatabase) async throws -> [ImportedAsk] {
        try await db.reader.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM ask_history ORDER BY createdAtMs")
                .map(ImportedAsk.init(row:))
        }
    }

    private func noteRows(_ db: AppDatabase) async throws -> [ImportedNote] {
        try await db.reader.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM notes ORDER BY createdAtMs")
                .map(ImportedNote.init(row:))
        }
    }

    // MARK: - Ask history (Q18)

    @Test func askOutputBecomesAskHistoryWithItsAnswerAndTime() async throws {
        let env = try MigrationTestEnv()
        defer { env.cleanup() }
        let a = try segment(env, "seg-1781303238897-5dd250fc-1", at: 1_781_303_238_897)
        try writeLegacyAiOutput(
            root: env.root, outputId: "ask-1782550908866-1", promptTemplateId: "ask",
            promptTitle: "Ask", segmentIds: [a],
            text: "You concluded that the raise was overdue [1].",
            createdAtMs: 1_782_550_913_273)

        let outcome = try await env.importer().run()

        #expect(outcome.stats.askEntriesImported == 1)
        let entries = try await askRows(env.db)
        let entry = try #require(entries.first)
        #expect(entry.answerText == "You concluded that the raise was overdue [1].")
        #expect(entry.createdAtMs == 1_782_550_913_273)
        // The old store recorded the prompt TEMPLATE, never the text the user typed — the
        // question was appended at runtime and thrown away. Say so instead of inventing one.
        #expect(entry.question == LegacyAiOutputImport.missingQuestionText)
        #expect(entry.scopeDescription == LegacyAiOutputImport.importedScopeDescription)
        #expect(entry.citations == [AskCitation(segmentId: a, number: 1)])
    }

    @Test func citationsToVanishedSegmentsAreDroppedNotLeftDangling() async throws {
        let env = try MigrationTestEnv()
        defer { env.cleanup() }
        let survivor = try segment(env, "seg-1781303238897-5dd250fc-1", at: 1_781_303_238_897)
        let gone = "seg-1781309068556-375637ed-1"  // pruned by retention, never imported
        try writeLegacyAiOutput(
            root: env.root, outputId: "ask-1", promptTemplateId: "ask",
            segmentIds: [gone, survivor],
            text: "First point [1]. Second point [2].")

        let outcome = try await env.importer().run()

        #expect(outcome.stats.aiOutputCitationsDropped == 1)
        let entry = try #require(try await askRows(env.db).first)
        // A citation whose segment no longer exists would navigate nowhere.
        #expect(entry.citations == [AskCitation(segmentId: survivor, number: 1)])
    }

    @Test func askHistoryStaysAtItsFiveEntryCap() async throws {
        let env = try MigrationTestEnv()
        defer { env.cleanup() }
        let a = try segment(env, "seg-1781303238897-5dd250fc-1", at: 1_781_303_238_897)
        for index in 0..<8 {
            try writeLegacyAiOutput(
                root: env.root, outputId: "ask-\(index)", promptTemplateId: "ask",
                segmentIds: [a], text: "Answer \(index)",
                createdAtMs: 1_782_000_000_000 + Int64(index))
        }

        _ = try await env.importer().run()

        let entries = try await askRows(env.db)
        #expect(entries.count == AskHistoryStore.maxEntries)
        // Newest kept, matching what `AskHistoryStore.save` would have left behind.
        #expect(entries.map(\.answerText).contains("Answer 7"))
        #expect(!entries.map(\.answerText).contains("Answer 0"))
    }

    // MARK: - Notes

    @Test func templateOutputBecomesANoteOnItsConversation() async throws {
        let env = try MigrationTestEnv()
        defer { env.cleanup() }
        let a = try segment(env, "seg-1787157319627-cfa6ca6e-6", at: 1_787_157_319_627)
        try writeLegacyAiOutput(
            root: env.root, outputId: "ai-1787158082402-0", promptTemplateId: "meeting-notes",
            promptTitle: "Meeting notes", segmentIds: [a],
            text: "## Topic\nMobile tablet fitting room UI behavior.",
            providerId: "openai-chat", modelUsed: "gpt-5.6-luna",
            createdAtMs: 1_787_158_086_566)

        let outcome = try await env.importer().run()

        #expect(outcome.stats.notesImported == 1)
        let note = try #require(try await noteRows(env.db).first)
        #expect(note.templateId == "meeting-notes")
        #expect(note.title == "Meeting notes")
        // The body is preserved verbatim: the app's own meeting-notes template still produces
        // Markdown headings, so normalising here would rewrite the user's result, not fix it.
        #expect(note.body == "## Topic\nMobile tablet fitting room UI behavior.")
        #expect(note.provider == "openai-chat")
        #expect(note.model == "gpt-5.6-luna")
        #expect(note.createdAtMs == 1_787_158_086_566)

        let members = try await env.db.reader.read { db in
            try String.fetchAll(
                db, sql: "SELECT segmentId FROM conversation_segments WHERE conversationId = ?",
                arguments: [note.conversationId])
        }
        #expect(members.contains(a))
    }

    @Test func wideScopeNoteLandsOnItsDominantConversationAndSaysSo() async throws {
        let env = try MigrationTestEnv()
        defer { env.cleanup() }
        // Two conversations, hours apart, with the scope weighted to the first.
        let one = try segment(env, "seg-1781303238897-5dd250fc-1", at: 1_781_303_238_897)
        let two = try segment(env, "seg-1781303358897-5dd250fc-2", at: 1_781_303_358_897)
        let far = try segment(env, "seg-1781400000000-aaaaaaaa-1", at: 1_781_400_000_000)
        try writeLegacyAiOutput(
            root: env.root, outputId: "ai-daily", promptTemplateId: "daily-summary",
            promptTitle: "Daily summary", segmentIds: [one, two, far],
            text: "A recap of the whole day.")

        _ = try await env.importer().run()

        let note = try #require(try await noteRows(env.db).first)
        let members = try await env.db.reader.read { db in
            try String.fetchAll(
                db, sql: "SELECT segmentId FROM conversation_segments WHERE conversationId = ?",
                arguments: [note.conversationId])
        }
        #expect(Set(members) == [one, two])
        // `notes.conversationId` is NOT NULL and a library-wide summary has no single home. It
        // lands where most of its sources are, and the title carries the true breadth so the
        // placement never overstates what the note is about.
        #expect(note.title == "Daily summary · 2 conversations")
    }

    @Test func outputWhoseSourcesAllVanishedIsDroppedNotRehomed() async throws {
        let env = try MigrationTestEnv()
        defer { env.cleanup() }
        try segment(env, "seg-1781303238897-5dd250fc-1", at: 1_781_303_238_897)
        try writeLegacyAiOutput(
            root: env.root, outputId: "ai-orphan", promptTemplateId: "decisions",
            promptTitle: "Decisions", segmentIds: ["seg-1770000000000-deadbeef-1"],
            text: "Decisions from audio that retention removed.")

        let outcome = try await env.importer().run()

        #expect(outcome.stats.notesImported == 0)
        #expect(outcome.stats.aiOutputsUnplaceable == 1)
        #expect(try await noteRows(env.db).isEmpty)
    }

    // MARK: - Tolerance + idempotence

    @Test func missingOptionalFieldsAreTolerated() async throws {
        let env = try MigrationTestEnv()
        defer { env.cleanup() }
        let a = try segment(env, "seg-1781303238897-5dd250fc-1", at: 1_781_303_238_897)
        // No promptTitle, no provider, no model, no createdAtMs.
        try writeLegacyAiOutput(
            root: env.root, outputId: "ai-bare", promptTemplateId: "decisions",
            promptTitle: nil, segmentIds: [a], text: "One decision.",
            providerId: nil, modelUsed: nil, createdAtMs: nil)
        // Not even a template id.
        try writeLegacyAiOutput(
            root: env.root, outputId: "ai-untemplated", promptTemplateId: nil,
            segmentIds: [a], text: "Something a template produced.",
            providerId: nil, modelUsed: nil, createdAtMs: nil)

        let outcome = try await env.importer().run()

        #expect(outcome.stats.notesImported == 2)
        let notes = try await noteRows(env.db)
        // With no promptTitle recorded there is nothing to title the note with, so it says so
        // rather than dressing up the template id; the template id itself is still preserved.
        #expect(notes.allSatisfy { $0.title == "Imported note" })
        #expect(Set(notes.map(\.templateId)) == ["decisions", "imported"])
        #expect(notes.allSatisfy { $0.provider == nil && $0.model == nil })
        // A missing createdAtMs falls back to the import clock rather than to zero (1970).
        #expect(notes.allSatisfy { $0.createdAtMs == env.now })
    }

    @Test func blankAndUnreadableOutputsAreSkipped() async throws {
        let env = try MigrationTestEnv()
        defer { env.cleanup() }
        let a = try segment(env, "seg-1781303238897-5dd250fc-1", at: 1_781_303_238_897)
        try writeLegacyAiOutput(
            root: env.root, outputId: "ai-blank", promptTemplateId: "decisions",
            segmentIds: [a], text: "   \n  ")
        let dir =
            env.root
            .appendingPathComponent("ai", isDirectory: true)
            .appendingPathComponent("outputs", isDirectory: true)
        try Data("{ not json".utf8).write(to: dir.appendingPathComponent("ai-broken.ai.json"))

        let outcome = try await env.importer().run()

        #expect(outcome.stats.notesImported == 0)
        #expect(outcome.stats.askEntriesImported == 0)
        #expect(try await noteRows(env.db).isEmpty)
    }

    @Test func rerunningTheImportAddsNothingTwice() async throws {
        let env = try MigrationTestEnv()
        defer { env.cleanup() }
        let a = try segment(env, "seg-1781303238897-5dd250fc-1", at: 1_781_303_238_897)
        try writeLegacyAiOutput(
            root: env.root, outputId: "ask-1", promptTemplateId: "ask", segmentIds: [a],
            text: "An answer [1].")
        try writeLegacyAiOutput(
            root: env.root, outputId: "ai-1", promptTemplateId: "decisions", segmentIds: [a],
            text: "A decision.")

        _ = try await env.importer().run()
        // Second pass through the SAME phase, marker deleted — the deterministic
        // `legacy-<outputId>` keys carry idempotence on their own, not just the phase flag.
        try FileManager.default.removeItem(
            at: env.root.appendingPathComponent(LegacyImporter.markerFileName))
        _ = try await env.importer().run()

        #expect(try await askRows(env.db).count == 1)
        #expect(try await noteRows(env.db).count == 1)
    }
}

// MARK: - Real backup gate

// Runs the outputs import against COPIES of the real `ai/outputs` files (the originals are never
// opened for writing). Skips cleanly where the backup is absent so CI elsewhere stays green.
private let realOutputsPath =
    ProcessInfo.processInfo.environment["PEBBLE_LEGACY_AI_OUTPUTS"]
    ?? "/Users/roger/Desktop/PebbleAudioBackup/audio-companion-20260831-110954/ai/outputs"

private var realOutputsAvailable: Bool {
    FileManager.default.fileExists(atPath: realOutputsPath, isDirectory: nil)
}

@Suite struct RealAiOutputsImportTests {

    @Test(.enabled(if: realOutputsAvailable))
    func importsTheRealOutputsTree() async throws {
        let env = try MigrationTestEnv()
        defer { env.cleanup() }
        let aiDir = env.root.appendingPathComponent("ai", isDirectory: true)
        try FileManager.default.createDirectory(at: aiDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: realOutputsPath),
            to: aiDir.appendingPathComponent("outputs", isDirectory: true))

        // Seed one real segment per output so its scope resolves to a conversation, using the
        // ids the outputs actually name.
        struct Scope: Decodable {
            var outputId: String
            var promptTemplateId: String?
            var segmentIds: [String]?
        }
        let files = try FileManager.default.contentsOfDirectory(
            at: aiDir.appendingPathComponent("outputs", isDirectory: true),
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasSuffix(".ai.json") }.sorted {
            $0.lastPathComponent < $1.lastPathComponent
        }
        var asks = 0
        var templates = 0
        var seeded = Set<String>()
        for url in files {
            let scope = try JSONDecoder().decode(Scope.self, from: Data(contentsOf: url))
            if (scope.promptTemplateId ?? "") == "ask" { asks += 1 } else { templates += 1 }
            guard let first = scope.segmentIds?.first,
                let parsed = ParsedSegmentId.parse(first), seeded.insert(first).inserted
            else { continue }
            try writeLegacySegment(
                root: env.root, id: first, startTimeMs: UInt64(parsed.receivedAtMs),
                receivedAtMs: parsed.receivedAtMs, transcriptionState: .complete)
            try writeLegacyTranscript(root: env.root, segmentId: first)
        }
        #expect(files.count == 11, "the real tree holds 11 outputs")
        #expect(asks == 4)
        #expect(templates == 7)

        let outcome = try await env.importer().run()

        print(
            "real ai/outputs import: \(outcome.stats.askEntriesImported) ask answers, "
                + "\(outcome.stats.notesImported) notes, "
                + "\(outcome.stats.aiOutputsUnplaceable) unplaceable, "
                + "\(outcome.stats.aiOutputCitationsDropped) citations dropped")

        // 4 asks, capped at 5, so all of them land.
        #expect(outcome.stats.askEntriesImported == 4)
        #expect(outcome.stats.notesImported == 7)
        #expect(outcome.stats.aiOutputsUnplaceable == 0)

        let entries = try await env.db.reader.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM ask_history").map(ImportedAsk.init(row:))
        }
        #expect(entries.count == 4)
        // Real answers, non-trivial, and every stored citation resolves to a real segment.
        #expect(entries.allSatisfy { $0.answerText.count > 200 })
        let known = try await env.db.reader.read { db in
            Set(try String.fetchAll(db, sql: "SELECT segmentId FROM conversation_segments"))
        }
        for entry in entries {
            #expect(entry.citations.allSatisfy { known.contains($0.segmentId) })
        }

        let notes = try await env.db.reader.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM notes").map(ImportedNote.init(row:))
        }
        #expect(Set(notes.map(\.templateId))
            == ["daily-summary", "action-items", "decisions", "meeting-notes"])
        #expect(notes.allSatisfy { !$0.body.isEmpty && !$0.conversationId.isEmpty })

        // Re-runnable against the same real files.
        try FileManager.default.removeItem(
            at: env.root.appendingPathComponent(LegacyImporter.markerFileName))
        _ = try await env.importer().run()
        #expect(try await env.db.reader.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM notes") } == 7)
    }
}
