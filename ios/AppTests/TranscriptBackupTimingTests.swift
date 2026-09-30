import AppDB
import Foundation
import SegmentStore
import Testing
import Transcription

// What it costs to build the rows of the heaviest real conversation, stage by stage — the work
// that decides whether opening a day-long conversation in History can be quick at all.
//
// Runs only against a device backup, named by PEBBLE_TRANSCRIPT_BACKUP (through xcodebuild,
// TEST_RUNNER_PEBBLE_TRANSCRIPT_BACKUP=<backup root>). The backup is READ ONLY: its database is
// copied to a temporary directory before anything opens it (opening migrates), and the segment
// sidecars and transcripts are only ever read. Prints the timings; asserts only that the
// conversation was found and built.

private let backupRoot = ProcessInfo.processInfo.environment["PEBBLE_TRANSCRIPT_BACKUP"]

@Suite("real backup: building the heaviest conversation's transcript")
struct TranscriptBackupTimingTests {
    @Test(.enabled(if: backupRoot != nil)) @MainActor
    func timeTheHeaviestConversation() async throws {
        let root = URL(fileURLWithPath: try #require(backupRoot))
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "backup-timing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        for suffix in ["", "-wal", "-shm"] {
            let source = root.appending(path: "db/companion.sqlite\(suffix)")
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            try FileManager.default.copyItem(
                at: source, to: scratch.appending(path: "companion.sqlite\(suffix)"))
        }
        let queries = ConversationQueries(
            db: try AppDatabase.open(at: scratch.appending(path: "companion.sqlite")))

        func seconds(_ start: ContinuousClock.Instant) -> String {
            (ContinuousClock.now - start).formatted(.units(allowed: [.milliseconds]))
        }

        // The conversation with the most transcript on disk, which is the heaviest one to open.
        // Not simply the longest: retention and failed passes leave long conversations with
        // few transcripts (the backup's 24 h 52 min one has none), and building an empty
        // transcript measures nothing.
        let transcriptsDir = root.appending(path: "transcription/transcripts")
        func transcriptBytes(_ segmentId: String) -> Int {
            let file = transcriptsDir.appending(path: segmentId + FileTranscriptStore.suffix)
            return (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int)
                ?? 0
        }
        var bytes: [String: Int] = [:]
        for (segment, conversation) in try await queries.conversationIdsBySegment() {
            bytes[conversation, default: 0] += transcriptBytes(segment)
        }
        let heaviest = try #require(bytes.max { $0.value < $1.value }?.key)
        let rows = try await queries.rows(overlappingMs: Int64.min..<Int64.max)
        let longest = try #require(rows.first { $0.id == heaviest })
        var start = ContinuousClock.now
        let detail = try #require(try await queries.detail(id: longest.id))
        let detailTime = seconds(start)
        let pieces = detail.pieces
        let members = pieces.map(\.segmentId)

        let files = SegmentFileReader(root: root)
        let store = FileTranscriptStore(root: root, nowMs: { 0 })
        start = .now
        let metas = await LiveWorld.loadMetas(members, files: files)
        let metasTime = seconds(start)
        start = .now
        let transcripts = await LiveWorld.loadTranscripts(members, store: store)
        let transcriptsTime = seconds(start)
        start = .now
        let walked = await LiveWorld.walkMembers(
            pieces, metas: metas, transcripts: transcripts, assignments: [])
        let walkTime = seconds(start)

        // What the screen does with the result on the main actor.
        start = .now
        let layout = TranscriptLayout(
            transcript: walked.transcript, provenance: "p", focus: nil)
        let layoutTime = seconds(start)
        start = .now
        _ = TranscriptPlayheadIndex(walked.transcript)
        let indexTime = seconds(start)
        let words = transcripts.values.reduce(0) { $0 + ($1.words.count) }

        print(
            """
            BACKUP-TIMING \(longest.id): \(longest.durationMs / 60_000) min, \
            \(members.count) members, \(metas.count) sidecars, \(transcripts.count) transcripts \
            (\(bytes[heaviest] ?? 0) bytes), \(words) words, \
            \(walked.transcript.count) items, \(layout.rows.count) rows
            BACKUP-TIMING detail query \(detailTime) | load metas \(metasTime) | \
            load transcripts \(transcriptsTime) | walk members (off main) \(walkTime) | \
            layout (main) \(layoutTime) | playhead index (main) \(indexTime)
            """)
        #expect(!walked.transcript.isEmpty)
        #expect(layout.rows.count <= walked.transcript.count + 1)
    }
}
