import CompanionRuntime
import Foundation

/// The Muse gadget, built on first use from the running composition. Nothing about Muse runs
/// until its screen is opened: pairing and asking are both things a person starts.
@MainActor
enum MuseComposition {
    private static var made: MuseGadgetService?

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
}
