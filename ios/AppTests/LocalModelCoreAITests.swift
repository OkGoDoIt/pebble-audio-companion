import Foundation
import Testing
import Transcription

// The Core AI local-model entry as the Settings picker sees it. On a simulator (and on iOS 26)
// there is no Core AI engine, so the row must read as unavailable — never as a download the
// phone could start — while the Cactus rows and Apple Speech are untouched.

@Suite("local model catalog · Core AI entry")
@MainActor
struct LocalModelCoreAITests {
    private let coreAIId = ParakeetModelCatalog.coreAIModelId

    @Test("the catalog lists the Core AI model after the Cactus ones, not recommended")
    func catalogEntry() throws {
        let options = LocalModelCatalog.installable
        let coreAI = try #require(options.first { $0.id == coreAIId })
        #expect(coreAI.runtime == .coreAI)
        #expect(coreAI.isDownloadable)
        #expect(coreAI.isRecommended == false)
        #expect(coreAI.sizeText == "1.26 GB")
        #expect(coreAI.compactName == "Parakeet TDT 0.6B · Core AI")
        #expect(options.last?.id == coreAIId)
        #expect(options.first?.id == LocalModelCatalog.appleSpeechId)
        // Every other entry keeps the default runtime, Apple Speech included.
        for option in options where option.id != coreAIId {
            #expect(option.runtime == .cactus, "\(option.id)")
        }
    }

    @Test("whether the model can run here follows the engine factory")
    func canRunHere() throws {
        let options = LocalModelCatalog.installable
        let coreAI = try #require(options.first { $0.id == coreAIId })
        #expect(coreAI.canRunHere == ParakeetEngineFactory.isSupported(.coreAI))
        #if targetEnvironment(simulator)
            #expect(coreAI.canRunHere == false, "no Core AI in the simulator SDK")
        #endif
        // Apple Speech ships with iOS; the Cactus models have a slice for every iOS target.
        #expect(LocalModelCatalog.appleSpeech.canRunHere)
        #expect(options.first { $0.id == ParakeetModelCatalog.defaultModelId }?.canRunHere == true)
    }

    @Test("the mock reports a model this build cannot run as unavailable, whatever it was told")
    func mockStateForUnrunnableModel() {
        let mock = MockLocalModelManager()
        guard !ParakeetEngineFactory.isSupported(.coreAI) else { return }
        #expect(mock.state(for: coreAIId) == .unavailable)
        mock.download(coreAIId)
        #expect(mock.state(for: coreAIId) == .unavailable)
        // ... and the kit falls back to Apple Speech for that selection, which the notice above
        // the list has to explain without inviting a download.
        #expect(mock.fallsBackToAppleSpeech(coreAIId))
        #expect(mock.state(for: ParakeetModelCatalog.defaultModelId) == .notInstalled)
    }

    @Test("the copy names the real reason, in the rows' lowercase register")
    func copy() {
        #expect(Copy.CoreAI.needsIOS27 == "needs iOS 27")
        let notice = Copy.CoreAI.unavailableNotice("Parakeet TDT 0.6B · Core AI")
        #expect(notice.hasPrefix("Parakeet TDT 0.6B · Core AI needs iOS 27 on an iPhone"))
        #expect(notice.contains("Apple Speech is transcribing"))
        #expect(!notice.lowercased().contains("download"))
    }
}
