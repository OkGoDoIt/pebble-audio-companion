import Foundation
import Testing

@testable import Intelligence

// Port of `core/ai/src/commonTest/.../AiModelsTest.kt` — all 5 cases, same names.

@Suite struct AiModelsTests {
    @Test func defaultIsGpt56Luna() {
        #expect(AiModels.defaultModelId == "gpt-5.6-luna")
        #expect(AiModels.default.id == AiModels.defaultModelId)
        #expect(AiModels.default.recommended)
    }

    @Test func catalogContainsRequestedModels() {
        let ids = AiModels.all.map { $0.id }
        #expect(ids.contains("gpt-5.6-luna"))
        #expect(ids.contains("gpt-5.6-terra"))
        #expect(ids.contains("gpt-5.6-sol"))
        #expect(Set(ids).count == ids.count, "model ids must be unique")
        #expect(
            AiModels.all.filter { $0.recommended }.count == 1,
            "exactly one recommended default")
    }

    @Test func byIdResolvesKnownAndFallsBackForUnknown() {
        #expect(AiModels.byId("gpt-5.6-sol").id == "gpt-5.6-sol")
        #expect(AiModels.byId("nonexistent-model").id == AiModels.defaultModelId)
        #expect(AiModels.byId(nil).id == AiModels.defaultModelId)
    }

    @Test func legacyIdsMigrateToTheEquivalentTier() {
        // Budget picks stay budget, frontier picks stay frontier.
        #expect(AiModels.byId("gpt-5.4-nano").id == "gpt-5.6-luna")
        #expect(AiModels.byId("gpt-5.4-mini").id == "gpt-5.6-luna")
        #expect(AiModels.byId("gpt-5.4").id == "gpt-5.6-terra")
        #expect(AiModels.byId("gpt-5.5").id == "gpt-5.6-sol")
        // An id that was never in the catalog still falls back to the default.
        #expect(AiModels.byId("gpt-5.5-mini").id == AiModels.defaultModelId)
    }

    @Test func everyLegacyReplacementResolvesToACatalogEntry() {
        let ids = Set(AiModels.all.map { $0.id })
        for legacy in ["gpt-5.4-nano", "gpt-5.4-mini", "gpt-5.4", "gpt-5.5"] {
            #expect(ids.contains(AiModels.byId(legacy).id), "\(legacy) must map into the catalog")
        }
    }
}
