import Foundation
import GRDB
import Testing
@testable import AppDB

/// The one-time move of `companion.sqlite` out of the App Group (0xDEAD10CC — see the type
/// comment on `AppDatabase`). Exercised on real files in a temporary directory, with the old and
/// new locations standing in for the two containers.
@Suite struct DatabaseRelocationTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("db-relocation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func legacyURL(_ root: URL) -> URL {
        root.appendingPathComponent("group/db/companion.sqlite")
    }

    private func newURL(_ root: URL) -> URL {
        root.appendingPathComponent("app/audio-companion/db/companion.sqlite")
    }

    /// A database at the old location with a row committed to its WAL and the pool still open,
    /// which is how a live app leaves it: the row exists only in `-wal` until a checkpoint.
    private func seedLegacy(_ root: URL) throws {
        let url = legacyURL(root)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let db = try AppDatabase.open(at: url)
        try db.writer.write { db in
            try db.execute(sql: "INSERT INTO tags (id, name) VALUES ('t1', 'lisbon')")
        }
        #expect(FileManager.default.fileExists(atPath: url.path + "-wal"))
    }

    @Test func movesTheDatabaseAndItsWalContentsAcross() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedLegacy(root)

        let outcome = try AppDatabase.relocateLegacyDatabaseIfNeeded(
            from: legacyURL(root), to: newURL(root))
        guard case .moved = outcome else {
            Issue.record("expected .moved, got \(outcome)")
            return
        }

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: newURL(root).path))
        #expect(!fm.fileExists(atPath: legacyURL(root).path))
        #expect(!fm.fileExists(atPath: legacyURL(root).path + "-wal"))
        #expect(!fm.fileExists(atPath: legacyURL(root).path + "-shm"))

        // The row that lived only in the WAL made it: the move is not just of the main file.
        let db = try AppDatabase.open(at: newURL(root))
        let names = try db.reader.read { try String.fetchAll($0, sql: "SELECT name FROM tags") }
        #expect(names == ["lisbon"])
    }

    @Test func secondLaunchIsANoOp() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedLegacy(root)
        _ = try AppDatabase.relocateLegacyDatabaseIfNeeded(from: legacyURL(root), to: newURL(root))

        let again = try AppDatabase.relocateLegacyDatabaseIfNeeded(
            from: legacyURL(root), to: newURL(root))
        #expect(again == .notNeeded)
    }

    @Test func nothingToMoveIsANoOp() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let outcome = try AppDatabase.relocateLegacyDatabaseIfNeeded(
            from: legacyURL(root), to: newURL(root))
        #expect(outcome == .notNeeded)
        #expect(!FileManager.default.fileExists(atPath: newURL(root).path))
        // No App Group at all (macOS tests) is the same answer.
        #expect(try AppDatabase.relocateLegacyDatabaseIfNeeded(from: nil, to: newURL(root)) == .notNeeded)
    }

    /// A database already at the new location is never overwritten by whatever is left behind —
    /// the new one is the live one, the old one is at best a stale copy.
    @Test func neverOverwritesAnExistingDatabase() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedLegacy(root)
        try FileManager.default.createDirectory(
            at: newURL(root).deletingLastPathComponent(), withIntermediateDirectories: true)
        let live = try AppDatabase.open(at: newURL(root))
        try live.writer.write { db in
            try db.execute(sql: "INSERT INTO tags (id, name) VALUES ('t2', 'porto')")
        }

        let outcome = try AppDatabase.relocateLegacyDatabaseIfNeeded(
            from: legacyURL(root), to: newURL(root))
        #expect(outcome == .notNeeded)
        #expect(FileManager.default.fileExists(atPath: legacyURL(root).path))
        let names = try live.reader.read { try String.fetchAll($0, sql: "SELECT name FROM tags") }
        #expect(names == ["porto"])
    }

    /// Killed right after the rename: an empty `-wal`/`-shm` pair beside a main file that is
    /// gone. The next launch tidies it and carries on.
    @Test func removesOrphanedSidecarsAfterAnInterruptedMove() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedLegacy(root)
        _ = try AppDatabase.relocateLegacyDatabaseIfNeeded(from: legacyURL(root), to: newURL(root))
        let fm = FileManager.default
        fm.createFile(atPath: legacyURL(root).path + "-wal", contents: Data())
        fm.createFile(atPath: legacyURL(root).path + "-shm", contents: Data())

        let outcome = try AppDatabase.relocateLegacyDatabaseIfNeeded(
            from: legacyURL(root), to: newURL(root))
        #expect(outcome == .notNeeded)
        #expect(!fm.fileExists(atPath: legacyURL(root).path + "-wal"))
        #expect(!fm.fileExists(atPath: legacyURL(root).path + "-shm"))
    }
}
