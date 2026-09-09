import Foundation

// Port of `core/ai/.../PersonalContextStore.kt`.

/// Durable store for `PersonalContext` at `<root>/ai/personal_context.json`, written via temp
/// file + atomic rename like other stores in this app. The JSON shape matches the KMP file
/// exactly (see PersonalContext.swift) — this is user-authored data.
public final class FilePersonalContextStore: @unchecked Sendable {
    public static let fileName = "personal_context.json"

    private let aiDir: URL
    private let contextPath: URL
    /// Serializes the store's own read-modify-write (`mutate`). It cannot serialize a caller
    /// that does its own `load()` … `save()` around other work — see `mutate`'s note.
    private let lock = NSLock()

    public init(root: URL) {
        self.aiDir = root.appendingPathComponent("ai", isDirectory: true)
        self.contextPath = aiDir.appendingPathComponent(Self.fileName)
    }

    public func load() -> PersonalContext {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked()
    }

    @discardableResult
    public func save(_ context: PersonalContext) throws -> PersonalContext {
        lock.lock()
        defer { lock.unlock() }
        try write(context)
        return context
    }

    /// Read, change, write — with no window in between for another writer to read the old
    /// document and put it back (AY).
    ///
    /// This file has several independent writers: the About You editor, the Contacts and
    /// Calendar imports, and `PersonalContextTermRefresher`. Each of them was doing
    /// `load()` … `save()`, so two overlapping writes lost one of the two changes — the term
    /// refresher finishing mid-import would put the pre-import document back, silently
    /// discarding the names that had just been imported.
    ///
    /// Callers that go through `mutate` cannot do that to each other, and all three now do: the
    /// refresher is handed closures rather than the store, so it takes this as one
    /// (`PersonalContextTermRefresher.init(mutate:)`) and its write-back runs under this lock.
    @discardableResult
    public func mutate(_ body: (inout PersonalContext) -> Void) throws -> PersonalContext {
        lock.lock()
        defer { lock.unlock() }
        var context = loadLocked()
        body(&context)
        try write(context)
        return context
    }

    public func clear() throws {
        lock.lock()
        defer { lock.unlock() }
        try removeIfExists(contextPath)
        try removeIfExists(aiDir.appendingPathComponent("\(Self.fileName).tmp"))
    }

    private func loadLocked() -> PersonalContext {
        guard let data = try? Data(contentsOf: contextPath) else { return PersonalContext() }
        return (try? JSONDecoder().decode(PersonalContext.self, from: data)) ?? PersonalContext()
    }

    private func write(_ context: PersonalContext) throws {
        try FileManager.default.createDirectory(at: aiDir, withIntermediateDirectories: true)
        let tmp = aiDir.appendingPathComponent("\(Self.fileName).tmp")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(context).write(to: tmp)
        try atomicMove(from: tmp, to: contextPath)
    }

    private func removeIfExists(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// POSIX rename: atomically replaces `to` (Kotlin `FileSystem.atomicMove` semantics).
    private func atomicMove(from: URL, to: URL) throws {
        if rename(from.path, to.path) != 0 {
            throw NSError(
                domain: NSPOSIXErrorDomain, code: Int(errno),
                userInfo: [NSFilePathErrorKey: to.path])
        }
    }
}
