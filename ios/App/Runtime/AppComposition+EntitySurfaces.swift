import Foundation
import os
import SearchKit

// Owned by the App Intents / Siri entity workstream. Wires the entity model to the composition:
//
//   • the visibility setting (Settings → Storage & Privacy → "Siri & Spotlight can see") into
//     the Core Spotlight indexer, read on every pass, and into the synchronous provider the
//     entities' `hideInSpotlight` reads;
//   • on iOS 27, the entity association hook, so each donated item carries its entity;
//   • a re-donation of the whole index whenever the setting CHANGES — the same rebuild
//     Diagnostics offers — so turning it down removes what was there and turning it up
//     restores it, rather than either waiting for content to happen to change.
//
// Below iOS 27 the association is absent and everything else is the pre-existing behaviour
// with a setting in front of it (default `.full`, the historical donation).
extension AppComposition {
    func installEntitySurfaces() {
        let box = settings.runtimeSettings
        let readVisibility: @Sendable () -> SystemSearchVisibility = { box.systemSearchVisibility }
        EntityVisibility.install(readVisibility)

        if let indexer = donator.systemIndex as? CoreSpotlightIndexer {
            var associate: CoreSpotlightIndexer.AssociationHook?
            var purge: (@Sendable () async -> Void)?
            if #available(iOS 27, *) {
                associate = { item, donation in
                    EntityAssociation.associate(item, donation: donation)
                }
                purge = { await EntityAssociation.purgeAll() }
            }
            indexer.configure(visibility: readVisibility, associate: associate, purgeEntities: purge)
        }

        // The rebuild on change. `onRuntimeSettingsChanged` fires for every runtime setting;
        // only a change in THIS one triggers the pass, and the last value seen is kept under a
        // lock because the callback is `@Sendable` and may arrive off the main actor.
        let lastSeen = OSAllocatedUnfairLock(initialState: box.systemSearchVisibility)
        let previous = settings.onRuntimeSettingsChanged
        settings.onRuntimeSettingsChanged = {
            previous?()
            let now = box.systemSearchVisibility
            let changed = lastSeen.withLock { last -> Bool in
                defer { last = now }
                return last != now
            }
            guard changed else { return }
            Task { @MainActor in
                await Self.rebuildIndexForVisibilityChange(to: now)
            }
        }

        #if DEBUG
            if #available(iOS 27, *), EntitySurfacesCheck.isRequested {
                let donator = self.donator
                Task { @MainActor in await EntitySurfacesCheck.run(donator: donator) }
            }
        #endif
    }

    /// The Diagnostics rebuild, run for a visibility change. Logged either way: an index that
    /// silently failed to empty after "off" would be exactly the kind of quiet lie this
    /// setting exists to prevent.
    @MainActor
    private static func rebuildIndexForVisibilityChange(to visibility: SystemSearchVisibility) async {
        guard let composition = AppComposition.shared else { return }
        do {
            let count = try await SearchIndexRebuilder(composition: composition).run()
            AppRuntimeLog.shared.record(
                "entities  visibility=\(visibility.rawValue) · index rebuilt · conversations=\(count)"
            )
        } catch {
            AppRuntimeLog.shared.record(
                "entities  visibility=\(visibility.rawValue) · index rebuild failed: \(error)"
            )
        }
    }
}
