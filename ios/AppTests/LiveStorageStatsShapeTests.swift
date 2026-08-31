import Foundation
import Testing

/// Settings → Storage claimed "0 recordings · 0 KB" for a whole session: the numbers were read
/// once during bootstrap, before the store had finished recovering, and `refresh()` is not on
/// `StorageStatsSource` so no screen could ask for another read. Free space had the same shape
/// for a different reason — it was a computed property with no observable state behind it, so
/// SwiftUI never re-read it after the first draw.
///
/// `LiveStorageStatsSource` is built from `AppComposition` (App Group database, segment spool),
/// so it cannot be constructed in a test bundle — see the note at the top of
/// `LiveMockConformanceTests`. What CAN be checked without a device is that the two structural
/// properties the fix consists of are still there, which is what silently regressed before.
@Suite("live storage stats shape")
struct LiveStorageStatsShapeTests {
    private static let file = "App/Runtime/LiveSettingsDataSources.swift"

    private func members() throws -> [SourceMember] {
        try SwiftSource.members(inFile: Self.file)
            .filter { $0.typeName == "LiveStorageStatsSource" }
    }

    @Test func theSourceIsFound() throws {
        #expect(try members().count > 3, "the reader found no LiveStorageStatsSource members")
    }

    /// Stored, not computed. A computed `freeSpace` has nothing observable behind it, so the
    /// line froze at whatever it said when the screen first drew.
    @Test func freeSpaceIsObservableState() throws {
        let freeSpace = try #require(try members().first { $0.name == "freeSpace" })
        #expect(
            freeSpace.isStored,
            "freeSpace is computed again; it must be stored state or SwiftUI never re-reads it")
        #expect(freeSpace.declaration.contains("var"))
    }

    /// The numbers move on a library write (a segment closed, a conversation deleted, recovery
    /// finishing) and on returning to the app after recording in the background. Losing either
    /// observation puts the freeze back.
    @Test func theNumbersRefreshThemselves() throws {
        let observe = try #require(try members().first { $0.name == "observe" })
        #expect(
            observe.body.contains("observeLibrary"),
            "storage stats no longer refresh on a library write")
        #expect(
            observe.body.contains("didBecomeActiveNotification"),
            "storage stats no longer refresh on returning to the foreground")
        #expect(SwiftSource.mentions("refresh", in: observe.body))
    }

    /// Export and delete both change what is on disk, so both re-read rather than leaving the
    /// screen showing the numbers from before the action the user just took.
    @Test func actionsOnThisScreenReReadAfterThemselves() throws {
        for name in ["exportAllAudio", "deleteAllRecordings"] {
            let member = try #require(try members().first { $0.name == name })
            #expect(
                SwiftSource.mentions("refresh", in: member.body),
                "\(name) leaves the screen showing stale numbers")
        }
    }

    /// `@Observable` invalidates on every set, and `refresh()` runs on every library tick — so
    /// re-rendering the Settings tree for numbers that did not move would be a lot of work to
    /// display the same string.
    @Test func onlyRealChangesInvalidateTheView() throws {
        let set = try #require(try members().first { $0.name == "set" })
        #expect(set.body.contains("if recordingCount != count"))
        #expect(set.body.contains("if recordingsSize != size"))
        #expect(set.body.contains("if freeSpace != free"))
    }
}
