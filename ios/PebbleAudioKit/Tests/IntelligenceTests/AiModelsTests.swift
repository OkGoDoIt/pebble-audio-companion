import Foundation
import Testing

@testable import Intelligence

// Port of `core/ai/src/commonTest/.../AiModelsTest.kt` — all 5 cases, same names.

@Suite struct AiModelsTests {
    @Test func defaultIsGpt6Luna() {
        #expect(AiModels.defaultModelId == "gpt-6-luna")
        #expect(AiModels.default.id == AiModels.defaultModelId)
        #expect(AiModels.default.recommended)
    }

    @Test func catalogContainsRequestedModels() {
        let ids = AiModels.all.map { $0.id }
        #expect(ids.contains("gpt-5.6-luna"))
        #expect(ids.contains("gpt-5.6-terra"))
        #expect(ids.contains("gpt-5.6-sol"))
        // The GPT-6 family sits beside 5.6, which stays as an option.
        #expect(ids.contains("gpt-6-luna"))
        #expect(ids.contains("gpt-6.1-sol"))
        #expect(ids.contains("gpt-6-astra"))
        #expect(Set(ids).count == ids.count, "model ids must be unique")
        #expect(
            AiModels.all.filter { $0.recommended }.count == 1,
            "exactly one recommended default")
    }

    /// A GPT-6 request may carry 922,000 input tokens (the 1,050,000 window less the 128,000
    /// reserved for output). Ask sizes its read from this number, so it must not exceed it.
    @Test func gpt6WindowsNeverExceedTheInputLimit() {
        for id in ["gpt-6-luna", "gpt-6.1-sol", "gpt-6-astra"] {
            let spec = AiModels.byId(id)
            #expect(spec.id == id, "\(id) resolves to itself, not to the default")
            #expect(spec.contextTokens <= 922_000)
            #expect(AiModels.resolvedModelId(id) == id)
        }
        // A dated snapshot is named by its family, dots in the version included.
        #expect(AiModels.displayName(modelUsed: "gpt-6.1-sol-2026-09-15") == "GPT-6.1 Sol")
        #expect(AiModels.displayName(modelUsed: "gpt-6-luna") == "GPT-6 Luna")
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

    // MARK: Naming the model that wrote something

    /// `byId` is for the setting and falls back to the default; used on a RECORD it named the
    /// phone's recaps, Private Cloud Compute's, and every dated OpenAI id "GPT-5.6 Luna".
    @Test func aRecordIsNamedByTheModelThatWroteItNeverTheDefault() {
        #expect(
            AiModels.displayName(modelUsed: "apple-foundation-models", providerId: nil)
                == "On-device Apple model")
        #expect(
            AiModels.displayName(modelUsed: "apple-private-cloud-compute", providerId: "apple-pcc")
                == "Apple Private Cloud Compute")
        #expect(AiModels.displayName(modelUsed: nil, providerId: "apple-pcc")
            == "Apple Private Cloud Compute")
        // A dated snapshot of a catalog model is that model.
        #expect(AiModels.displayName(modelUsed: "gpt-5.6-luna-2026-09-01") == "GPT-5.6 Luna")
        #expect(AiModels.displayName(modelUsed: "gpt-5.6-terra") == "GPT-5.6 Terra")
        // One we do not know is shown as recorded — not as Luna.
        #expect(
            AiModels.displayName(modelUsed: "gpt-5.4-mini-2026-03-17")
                == "gpt-5.4-mini-2026-03-17")
        #expect(AiModels.displayName(modelUsed: nil) == nil)
        #expect(AiModels.displayName(modelUsed: "  ") == nil)
        for id in ["apple-foundation-models", "apple-private-cloud-compute", "gpt-5.4-mini-2026-03-17"] {
            #expect(AiModels.displayName(modelUsed: id) != AiModels.default.displayName)
        }
    }

    /// What is SENT for a stored setting: a legacy id becomes the model Settings maps it to, and
    /// a model somebody chose that the catalog does not list is sent as chosen.
    @Test func aStoredModelIdIsResolvedBeforeItIsSent() {
        #expect(AiModels.resolvedModelId("gpt-5.4-mini") == "gpt-5.6-luna")
        #expect(AiModels.resolvedModelId("gpt-5.5") == "gpt-5.6-sol")
        #expect(AiModels.resolvedModelId("gpt-5.6-terra") == "gpt-5.6-terra")
        #expect(AiModels.resolvedModelId("") == AiModels.defaultModelId)
        #expect(AiModels.resolvedModelId(nil) == AiModels.defaultModelId)
        #expect(AiModels.resolvedModelId("gpt-6-preview") == "gpt-6-preview")
    }
}
