import CompanionRuntime
import Foundation
import Receiver

/// The Muse gadget, built from the running composition. Pairing and typed questions are things a
/// person starts on the Muse screen; push-to-talk listens from launch, because a question can
/// come from the watch at any time. Listening costs nothing: nothing reaches Meta until a button
/// is held (docs/privacy-model.md, D7).
@MainActor
enum MuseComposition {
    private static var made: MuseGadgetService?
    private static var pushToTalk: MusePushToTalk?

    /// The person's Muse choices: watch actions, where questions go, the voice level.
    static let preferences = MusePreferencesStore()

    static var service: MuseGadgetService? {
        if let made { return made }
        guard let composition = AppComposition.shared else { return nil }
        let service = MuseGadgetService(
            link: composition.receiver,
            log: { AppRuntimeLog.shared.record("muse  \($0)") }
        )
        made = service
        return service
    }

    /// What the last question from the watch was heard as, for the Muse screen.
    static var lastQuestion: StateSubject<MusePushToTalk.QuestionReport?>? { pushToTalk?.lastQuestion }

    /// The voice level check (Diagnostics), and starting or cancelling one.
    static var levelCheck: StateSubject<MusePushToTalk.LevelCheck?>? { pushToTalk?.levelCheck }
    static func armLevelCheck() {
        guard let pushToTalk else { return }
        Task { await pushToTalk.armLevelCheck() }
    }
    static func cancelLevelCheck() {
        guard let pushToTalk else { return }
        Task { await pushToTalk.cancelLevelCheck() }
    }

    /// Starts answering questions asked on the watch. Called once the composition is installed.
    static func startPushToTalk() {
        guard pushToTalk == nil, let composition = AppComposition.shared, let service else { return }
        // A question can wake a suspended app; this keeps it running until the answer is out.
        let awake = BackgroundActivityAssertion(log: AppRuntimeLog.runtimeLog)
        let pushToTalk = MusePushToTalk(
            link: composition.receiver,
            connector: service,
            preferences: preferences,
            keepAwake: { awake.renew() },
            log: { AppRuntimeLog.shared.record("muse  \($0)") }
        )
        self.pushToTalk = pushToTalk
        Task { await pushToTalk.start(paired: service.pairedName) }
    }
}
