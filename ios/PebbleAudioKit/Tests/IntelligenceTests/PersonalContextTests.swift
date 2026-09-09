import Foundation
import Testing

@testable import Intelligence

// Port of `core/ai/src/jvmTest/.../PersonalContextTest.kt` — all 4 cases
// (PersonalContextStoreTest + PersonalContextFormattingTest), same names.

@Suite struct PersonalContextStoreTests {
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pc-store-test-\(UUID().uuidString)", isDirectory: true)

    @Test func roundTripAndClear() throws {
        let store = FilePersonalContextStore(root: root)
        let saved = try store.save(
            PersonalContext(
                profileText: "I work at Pebble. Sarah is my manager.",
                derivedTerms: ["Pebble", "Sarah"],
                derivedTermsSourceHash: "abc"
            ))
        #expect(saved.profileText == "I work at Pebble. Sarah is my manager.")
        let loaded = store.load()
        #expect(loaded == saved)
        try store.clear()
        #expect(store.load() == PersonalContext())
    }
}

@Suite struct PersonalContextFormattingTests {
    // Contract changed by stream PC: a clamp now ends on a word boundary rather than at an
    // exact character count, because a bias hint or a grounding fact cut mid-word is worse
    // than a slightly shorter one — a speech model will happily bias toward the fragment.
    // The ellipsis is the single-character "…" so it costs one character, not three.
    @Test func clampsLongProfileForSonioxAndGrounding() throws {
        let long = String(repeating: "word ", count: 5_000)
        let ctx = PersonalContext(profileText: long, biasTranscription: true, groundAi: true)
        let text = try #require(
            PersonalContextFormatting.transcriptionText(ctx, budgetChars: 100))
        #expect(text.count <= 100)
        #expect(text.count > 90)
        #expect(text.hasSuffix("…"))
        #expect(!text.hasSuffix("wor…"))
    }

    @Test func openAiSttPromptUsesDerivedTermsOnly() {
        let ctx = PersonalContext(
            profileText: "Long prose about my life",
            derivedTerms: ["Pebble", "Sarah"],
            biasTranscription: true
        )
        #expect(PersonalContextFormatting.openAiSttPrompt(ctx) == "Pebble, Sarah")
    }

    @Test func disabledBiasReturnsNull() {
        let ctx = PersonalContext(profileText: "hello", biasTranscription: false)
        #expect(PersonalContextFormatting.transcriptionText(ctx) == nil)
        #expect(PersonalContextFormatting.transcriptionTerms(ctx).isEmpty)
    }
}
