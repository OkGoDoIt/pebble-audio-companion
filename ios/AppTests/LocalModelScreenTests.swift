import Foundation
import Testing
import Transcription

// On this iPhone: which engines are listed, and when a chosen one takes over.

@Suite("on this iPhone")
@MainActor
struct LocalModelScreenTests {
    private let pebble = ParakeetModelCatalog.watchModelId
    private let apple = LocalModelCatalog.appleSpeechId

    private func settings() -> AppSettings {
        AppSettings(defaults: UserDefaults(suiteName: "local-model-\(UUID())")!)
    }

    private final class Models: LocalModelManaging {
        let models: [LocalModelOption]
        var states: [String: LocalModelState]
        init(_ models: [LocalModelOption], _ states: [String: LocalModelState]) {
            self.models = models
            self.states = states
        }
        func state(for modelId: String) -> LocalModelState { states[modelId] ?? .notInstalled }
        func refresh() {}
        func download(_ modelId: String) {}
        func downloadOverCellular(_ modelId: String) {}
        func cancelDownload(_ modelId: String) {}
        func delete(_ modelId: String) {}
        func debugFailDownload(_ modelId: String) {}
    }

    @Test("the mock shows the two choices and nothing else")
    func twoRows() {
        #expect(MockLocalModelManager().listed.map(\.id) == [pebble, apple])
    }

    @Test("each of the two says how it compares with the other")
    func accuracy() {
        #expect(MockLocalModelManager().listed.map(\.accuracy) == [.most, .less])
    }

    @Test("a model with no way to get it is not listed; one that is here, or on its way, is")
    func nothingThatCannotFinish() {
        let models = Models(LocalModelCatalog.installable, [apple: .installed])
        #expect(models.listed.map(\.id) == [apple])
        for state: LocalModelState in [.installing, .preparing, .installed, .failed] {
            models.states[pebble] = state
            #expect(models.listed.map(\.id) == [pebble, apple], "\(state)")
        }
        models.states[pebble] = .unavailable
        #expect(models.listed.map(\.id) == [apple])
    }

    @Test("an older model stays listed only while this phone holds it")
    func retiredModels() {
        let old = ParakeetModelCatalog.defaultModelId
        let models = Models(
            LocalModelCatalog.installable, [apple: .installed, pebble: .installed, old: .installed])
        #expect(models.listed.map(\.id) == [pebble, apple, old])
        models.states[old] = .notInstalled
        #expect(models.listed.map(\.id) == [pebble, apple])
    }

    @Test("the engine in use keeps transcribing until the chosen one is ready")
    func switchWaits() {
        let settings = settings()
        #expect(settings.localTranscriptionModelId == apple)
        settings.pendingLocalTranscriptionModelId = pebble
        for state: LocalModelState in [
            .downloading(progress: 0.5), .installing, .preparing, .failed, .waitingForWiFi,
            .needsSpace(freeBytes: 1),
        ] {
            settings.adoptPendingLocalModel { $0 == pebble ? state : .installed }
            #expect(settings.localTranscriptionModelId == apple, "\(state)")
            #expect(settings.shownLocalTranscriptionModelId == pebble)
        }
        settings.adoptPendingLocalModel { _ in .installed }
        #expect(settings.localTranscriptionModelId == pebble)
        #expect(settings.pendingLocalTranscriptionModelId == nil)
    }

    @Test("a chosen model survives a relaunch, and a missing one gives way to Apple Speech")
    func relaunchAndMissing() {
        let defaults = UserDefaults(suiteName: "local-model-\(UUID())")!
        let first = AppSettings(defaults: defaults)
        first.pendingLocalTranscriptionModelId = pebble
        #expect(AppSettings(defaults: defaults).pendingLocalTranscriptionModelId == pebble)

        first.localTranscriptionModelId = ParakeetModelCatalog.defaultModelId
        first.dropMissingLocalModel { _ in .preparing }
        #expect(first.localTranscriptionModelId == ParakeetModelCatalog.defaultModelId)
        first.dropMissingLocalModel { _ in .notInstalled }
        #expect(first.localTranscriptionModelId == apple)
        // A language tag picks the language Apple Speech runs in, not a model.
        first.localTranscriptionModelId = "ko-KR"
        first.dropMissingLocalModel { _ in .notInstalled }
        #expect(first.localTranscriptionModelId == "ko-KR")
    }

    @Test("copy")
    func copy() {
        #expect(Copy.OnThisIPhone.downloaded(0.42, of: 631_823_041) == "265 of 632 MB")
        #expect(
            Copy.OnThisIPhone.needsSpace(1_463_646_082, free: 210_000_000)
                == "Needs 1.5 GB, 210 MB free")
    }
}
