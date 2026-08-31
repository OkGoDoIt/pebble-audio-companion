import Foundation

// Port of `core/ai/.../PersonalContextStore.kt`.

/// Durable store for `PersonalContext` at `<root>/ai/personal_context.json`, written via temp
/// file + atomic rename like other stores in this app. The JSON shape matches the KMP file
/// exactly (see PersonalContext.swift) — this is user-authored data.
public final class FilePersonalContextStore: @unchecked Sendable {
    public static let fileName = "personal_context.json"

    private let aiDir: URL
    private let contextPath: URL

    public init(root: URL) {
        self.aiDir = root.appendingPathComponent("ai", isDirectory: true)
        self.contextPath = aiDir.appendingPathComponent(Self.fileName)
    }

    public func load() -> PersonalContext {
        guard let data = try? Data(contentsOf: contextPath) else { return PersonalContext() }
        return (try? JSONDecoder().decode(PersonalContext.self, from: data)) ?? PersonalContext()
    }

    @discardableResult
    public func save(_ context: PersonalContext) throws -> PersonalContext {
        try write(context)
        return context
    }

    public func clear() throws {
        try removeIfExists(contextPath)
        try removeIfExists(aiDir.appendingPathComponent("\(Self.fileName).tmp"))
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
