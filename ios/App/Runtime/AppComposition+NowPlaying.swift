import AppIntents
import Foundation
import UIKit

// Owned by the Now Playing workstream. Creates the system media-session bridge that conversation
// playback publishes through (NowPlaying framework on iOS 27, MediaPlayer on iOS 26).
extension AppComposition {
    /// The one bridge to the system's media surfaces. Nil in previews and before install; the
    /// conversation screen hands it to its `PlayerModel` on load.
    var nowPlaying: (any NowPlayingPublishing)? { NowPlayingInstallation.publisher }

    func installNowPlaying() {
        let log: @MainActor (String) -> Void = { AppRuntimeLog.shared.record($0) }
        let publisher: any NowPlayingPublishing
        if #available(iOS 27, *) {
            // The App Intents identity travels with the item, so "Siri, what is this?" over the
            // Lock Screen resolves to the conversation entity the Siri surfaces already know.
            publisher = MediaSessionNowPlaying(
                entityIdentifiers: { id in
                    [EntityIdentifier(for: ConversationEntity.self, identifier: id)]
                },
                log: log)
        } else {
            publisher = MediaPlayerNowPlaying(log: log)
        }
        NowPlayingInstallation.publisher = publisher

        // Playing a recording takes the shared audio session out of the residency recipe
        // (`.playback`/`.spokenAudio`, no `.mixWithOthers`) and nothing put it back until the
        // next `didEnterBackground`. Put it back the moment a listening session ends instead,
        // so a foreground playback followed by a lock is already in the right category — and
        // so the user's music, started from Control Center over our screen, is not silenced.
        // A no-op unless residency is wanted (the watch is streaming).
        //
        // The other direction matters too: `didEnterBackground` used to re-assert residency
        // unconditionally, which flipped the session to a mixable category UNDER a running
        // playback engine the moment the phone was locked mid-listen — exactly when the Lock
        // Screen controls are wanted. So the receiver is told while playback holds the session
        // (`playbackHold`) and skips that re-assert; this observer restores residency itself:
        // at once when the listening session ends, and after a short grace when it is merely
        // paused in the background (long enough to resume from the Lock Screen, short enough
        // that a forgotten pause cannot cost watch audio).
        let receiver = self.receiver
        PlayerModel.observeActivity { activity in
            TelemetryEvents.playback(active: activity == .playing)
            receiver.playbackHold.set(activity == .playing)
            NowPlayingInstallation.pauseGrace?.cancel()
            NowPlayingInstallation.pauseGrace = nil
            switch activity {
            case .playing:
                break
            case .ended:
                receiver.reassertResidencyAfterPlayback()
            case .paused:
                NowPlayingInstallation.pauseGrace = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(PlayerModel.pauseGraceSeconds))
                    guard !Task.isCancelled,
                        UIApplication.shared.applicationState == .background
                    else { return }
                    receiver.reassertResidencyAfterPlayback()
                }
            }
        }
    }
}

/// Extensions cannot add stored properties, so the bridge is held here. One per process, like
/// `AppComposition.shared` itself.
@MainActor
private enum NowPlayingInstallation {
    static var publisher: (any NowPlayingPublishing)?
    static var pauseGrace: Task<Void, Never>?
}
