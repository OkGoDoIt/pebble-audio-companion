import Foundation
import Testing

@testable import Intelligence

// `personal_context.json` has four independent writers: the About You editor, the Contacts
// import, the Calendar import, and the term refresher. `FilePersonalContextStore.mutate` exists
// so a read-change-write happens under the store's own lock; the refresher was the one writer
// still doing `load()` … `save()` through closures, so an import landing in the window between
// its read and its write was silently put back — every name that had just been imported, gone.
//
// The race itself cannot be pinned deterministically without a test hook inside `persist`, and a
// production hook for that would be worse than the bug. What CAN be pinned, and is what actually
// went wrong, is the WIRING: the refresher writes through the mutating closure when it is given
// one, so its read and its write are inside the same lock the other three writers hold.

private final class FixedAiProvider: AiProvider, @unchecked Sendable {
    let id = "fl-fixed"
    func isAvailable() async -> Bool { true }
    func run(_ request: AiRunRequest) async throws -> AiProviderResult {
        AiProviderResult(text: "Pebble, Obelix", modelUsed: "fl-model")
    }
}

/// Counts which door the refresher came through.
private final class WriteRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var context: PersonalContext
    private var _saves = 0
    private var _mutations = 0

    init(_ context: PersonalContext) { self.context = context }

    var current: PersonalContext { lock.withLock { context } }
    var saves: Int { lock.withLock { _saves } }
    var mutations: Int { lock.withLock { _mutations } }

    func load() -> PersonalContext { lock.withLock { context } }

    func save(_ value: PersonalContext) {
        lock.withLock {
            context = value
            _saves += 1
        }
    }

    /// What `FilePersonalContextStore.mutate` does: read, change and write without ever letting
    /// go, so no other writer can slip a whole document in between.
    func mutate(_ body: (inout PersonalContext) -> Void) {
        lock.withLock {
            body(&context)
            _mutations += 1
        }
    }
}

@Suite("term refresher write path") struct FLTermRefresherMutateTests {

    private func makeRefresher(
        recorder: WriteRecorder, routeThroughMutate: Bool
    ) -> PersonalContextTermRefresher {
        PersonalContextTermRefresher(
            load: { recorder.load() },
            save: { recorder.save($0) },
            extractor: PersonalContextTermExtractor(
                router: AiModeRouter(local: FixedAiProvider(), remote: nil, mode: { .localOnly })
            ),
            nowMs: { 1_000 },
            mutate: routeThroughMutate ? { recorder.mutate($0) } : nil,
            log: { _ in }
        )
    }

    @Test func theWriteBackGoesThroughTheStoresLockRatherThanAFreshLoadAndSave() async {
        let recorder = WriteRecorder(PersonalContext(profileText: "I work on Pebble."))
        let refresher = makeRefresher(recorder: recorder, routeThroughMutate: true)

        let terms = await refresher.refreshIfNeeded()

        #expect(terms == ["Pebble", "Obelix"])
        #expect(recorder.mutations == 1)
        #expect(recorder.saves == 0)
        // …and the fields it was supposed to write are the fields that landed.
        #expect(recorder.current.derivedTerms == ["Pebble", "Obelix"])
        #expect(recorder.current.derivedTermsSourceHash == recorder.current.profileTextHash())
        // Nothing else in the document was touched on the way past.
        #expect(recorder.current.profileText == "I work on Pebble.")
    }

    /// The fallback is still there and still correct, so a caller that hands over only `load`/
    /// `save` (every test double that predates this) behaves exactly as it did.
    @Test func withoutAMutatingClosureItStillWritesThroughSave() async {
        let recorder = WriteRecorder(PersonalContext(profileText: "I work on Pebble."))
        let refresher = makeRefresher(recorder: recorder, routeThroughMutate: false)

        _ = await refresher.refreshIfNeeded()

        #expect(recorder.mutations == 0)
        #expect(recorder.saves == 1)
        #expect(recorder.current.derivedTerms == ["Pebble", "Obelix"])
    }

    /// Whichever door it comes through, what is stored must describe the text that is actually
    /// there — the stale-hash guard moved inside the mutating closure and still holds.
    @Test func whatIsWrittenAlwaysDescribesTheTextThatIsThere() async {
        for routeThroughMutate in [true, false] {
            let recorder = WriteRecorder(PersonalContext(profileText: "I work on Pebble."))
            let refresher = makeRefresher(
                recorder: recorder, routeThroughMutate: routeThroughMutate)

            _ = await refresher.refreshIfNeeded()

            #expect(recorder.current.derivedTermsSourceHash == recorder.current.profileTextHash())
        }
    }
}
