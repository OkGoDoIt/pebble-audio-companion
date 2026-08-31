import Foundation
import Testing

@testable import Intelligence

// The producer half of the About You transcription bias. `PersonalContextTermExtractor` was
// tested only as a parser; nothing ever produced terms into a stored context, which is how the
// OpenAI STT prompt came to be nil for every paste-only user.

private final class ScriptedAiProvider: AiProvider, @unchecked Sendable {
    let id = "scripted"
    private let available: Bool
    private let text: String
    /// Runs inside the model call, so a test can change the world mid-extraction.
    private let duringRun: (@Sendable () -> Void)?
    private let lock = NSLock()
    private var _calls = 0

    var calls: Int { lock.withLock { _calls } }

    init(
        available: Bool = true,
        text: String = "Pebble, Speex, Sarah Chen",
        duringRun: (@Sendable () -> Void)? = nil
    ) {
        self.available = available
        self.text = text
        self.duringRun = duringRun
    }

    func isAvailable() async -> Bool { available }

    func run(_ request: AiRunRequest) async throws -> AiProviderResult {
        lock.withLock { _calls += 1 }
        duringRun?()
        return AiProviderResult(text: text, modelUsed: "scripted-model")
    }
}

/// In-memory stand-in for `FilePersonalContextStore`.
private final class ContextBox: @unchecked Sendable {
    private let lock = NSLock()
    private var context: PersonalContext
    private var _writes = 0

    init(_ context: PersonalContext) {
        self.context = context
    }

    var current: PersonalContext { lock.withLock { context } }
    var writes: Int { lock.withLock { _writes } }

    func load() -> PersonalContext { lock.withLock { context } }

    func save(_ value: PersonalContext) throws {
        lock.withLock {
            context = value
            _writes += 1
        }
    }

    func mutate(_ body: (inout PersonalContext) -> Void) {
        lock.withLock { body(&context) }
    }
}

@Suite struct PersonalContextTermRefresherTests {
    private func makeRefresher(
        box: ContextBox,
        provider: ScriptedAiProvider,
        clock: TestWallClock = TestWallClock(ms: 1_000)
    ) -> PersonalContextTermRefresher {
        PersonalContextTermRefresher(
            load: { box.load() },
            save: { try box.save($0) },
            extractor: PersonalContextTermExtractor(
                router: AiModeRouter(local: provider, remote: nil, mode: { .localOnly })
            ),
            nowMs: { clock.now },
            log: { _ in }
        )
    }

    @Test func pastedBioProducesTheKeywordListTheSttPromptIsBuiltFrom() async {
        let box = ContextBox(PersonalContext(profileText: "I work on Pebble with Sarah Chen."))
        let provider = ScriptedAiProvider()
        let refresher = makeRefresher(box: box, provider: provider)

        // The whole point: before the producer runs there is no prompt at all.
        #expect(PersonalContextFormatting.openAiSttPrompt(box.current) == nil)

        let terms = await refresher.refreshIfNeeded()

        #expect(terms == ["Pebble", "Speex", "Sarah Chen"])
        #expect(box.current.derivedTerms == ["Pebble", "Speex", "Sarah Chen"])
        #expect(box.current.derivedTermsSourceHash == box.current.profileTextHash())
        #expect(PersonalContextFormatting.openAiSttPrompt(box.current) == "Pebble, Speex, Sarah Chen")
    }

    @Test func unchangedProfileTextNeverAsksTheModelTwice() async {
        let box = ContextBox(PersonalContext(profileText: "I work on Pebble."))
        let provider = ScriptedAiProvider()
        let refresher = makeRefresher(box: box, provider: provider)

        await refresher.refreshIfNeeded()
        await refresher.refreshIfNeeded()
        await refresher.refreshIfNeeded()

        #expect(provider.calls == 1)
        #expect(box.writes == 1)
    }

    @Test func editingTheBioReExtracts() async {
        let box = ContextBox(PersonalContext(profileText: "I work on Pebble."))
        let provider = ScriptedAiProvider()
        let refresher = makeRefresher(box: box, provider: provider)

        await refresher.refreshIfNeeded()
        box.mutate { $0.profileText = "I work on Pebble and Obelix." }
        await refresher.refreshIfNeeded()

        #expect(provider.calls == 2)
        #expect(box.current.derivedTermsSourceHash == box.current.profileTextHash())
    }

    @Test func clearingTheBioDropsTermsThatNoLongerDescribeAnything() async {
        let box = ContextBox(
            PersonalContext(
                profileText: nil,
                derivedTerms: ["Pebble"],
                derivedTermsSourceHash: "stale"
            ))
        let provider = ScriptedAiProvider()
        let refresher = makeRefresher(box: box, provider: provider)

        let terms = await refresher.refreshIfNeeded()

        #expect(terms.isEmpty)
        #expect(box.current.derivedTerms.isEmpty)
        #expect(box.current.derivedTermsSourceHash == nil)
        #expect(provider.calls == 0)
    }

    @Test func anUnavailableModelLeavesTheCachedTermsAloneAndBacksOff() async {
        let box = ContextBox(
            PersonalContext(
                profileText: "I work on Pebble.",
                derivedTerms: ["Earlier", "Terms"],
                derivedTermsSourceHash: "older-text"
            ))
        let provider = ScriptedAiProvider(available: false)
        let clock = TestWallClock(ms: 1_000)
        let refresher = makeRefresher(box: box, provider: provider, clock: clock)

        let first = await refresher.refreshIfNeeded()
        #expect(first == ["Earlier", "Terms"])
        #expect(box.writes == 0)

        // Within the cooldown the extractor is not asked again...
        await refresher.refreshIfNeeded()
        #expect(provider.calls == 0)

        // ...and the terms that are still on disk keep biasing transcription meanwhile.
        #expect(PersonalContextFormatting.transcriptionTerms(box.current) == ["Earlier", "Terms"])

        clock.advance(byMs: 11 * 60 * 1000)
        await refresher.refreshIfNeeded()
        #expect(box.current.derivedTerms == ["Earlier", "Terms"])
    }

    @Test func biasTranscriptionOffSpendsNoModelCall() async {
        var context = PersonalContext(profileText: "I work on Pebble.")
        context.biasTranscription = false
        let box = ContextBox(context)
        let provider = ScriptedAiProvider()
        let refresher = makeRefresher(box: box, provider: provider)

        await refresher.refreshIfNeeded()

        #expect(provider.calls == 0)
        #expect(box.writes == 0)
    }

    @Test func aBioEditDuringExtractionIsNotStampedWithTheOldTerms() async {
        let box = ContextBox(PersonalContext(profileText: "I work on Pebble."))
        // The user keeps typing while the model is running: the terms coming back describe text
        // that is already gone, so they must not be written (nor stamped with the new hash).
        let provider = ScriptedAiProvider(duringRun: {
            box.mutate { $0.profileText = "Something else entirely." }
        })
        let refresher = makeRefresher(box: box, provider: provider)

        await refresher.refreshIfNeeded()

        #expect(provider.calls == 1)
        #expect(box.current.derivedTerms.isEmpty)
        #expect(box.current.derivedTermsSourceHash == nil)
        #expect(box.writes == 0)
    }

    @Test func termsAreCappedAtTheBudget() async {
        let many = (1...60).map { "Term\($0)" }.joined(separator: ", ")
        let box = ContextBox(PersonalContext(profileText: "A long bio."))
        let provider = ScriptedAiProvider(text: many)
        let refresher = makeRefresher(box: box, provider: provider)

        let terms = await refresher.refreshIfNeeded()

        #expect(terms.count == PersonalContextFormatting.maxDerivedTerms)
    }
}
