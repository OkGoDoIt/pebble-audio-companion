import Foundation
import Intelligence
import Testing


// The default cloud model became GPT-6 Luna. A phone with the old default written down moves
// to it once; a choice made afterwards — GPT-5.6 Luna included — is never moved again.

@Suite("Settings — the old default cloud model moves to the new one, once")
@MainActor
struct AiModelDefaultMoveTests {
    private func freshDefaults() -> UserDefaults {
        let name = "ai-model-move-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func nothingStoredUsesTheNewDefault() {
        let defaults = freshDefaults()
        #expect(AppSettings.storedAiModel(defaults) == "gpt-6-luna")
        #expect(defaults.string(forKey: "ai_model") == nil)
    }

    @Test func theOldDefaultMovesOnce() {
        let defaults = freshDefaults()
        defaults.set("gpt-5.6-luna", forKey: "ai_model")
        #expect(AppSettings.storedAiModel(defaults) == AiModels.defaultModelId)
        #expect(defaults.string(forKey: "ai_model") == "gpt-6-luna")

        // Picked again afterwards: it is a choice now, and it stays.
        defaults.set("gpt-5.6-luna", forKey: "ai_model")
        #expect(AppSettings.storedAiModel(defaults) == "gpt-5.6-luna")
    }

    @Test(arguments: ["gpt-5.6-terra", "gpt-5.6-sol", "gpt-6-astra", "some-other-model"])
    func anyOtherStoredModelIsAChoice(_ id: String) {
        let defaults = freshDefaults()
        defaults.set(id, forKey: "ai_model")
        #expect(AppSettings.storedAiModel(defaults) == id)
        #expect(defaults.string(forKey: "ai_model") == id)
    }
}
