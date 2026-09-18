import Foundation

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
            // SEAM: `entityIdentifiers` stays at its default (none) until the Siri workstream's
            // `ConversationEntity` exists on this branch; then it is one closure here:
            // `{ id in [EntityIdentifier(for: ConversationEntity.self, identifier: id)] }`.
            publisher = MediaSessionNowPlaying(log: log)
        } else {
            publisher = MediaPlayerNowPlaying(log: log)
        }
        NowPlayingInstallation.publisher = publisher

        // Playing a recording takes the shared audio session out of the residency recipe
        // (`.playback`/`.spokenAudio`, no `.mixWithOthers`) and nothing put it back until the
        // next `didEnterBackground`. Put it back the moment a listening session ends instead,
        // so a foreground playback followed by a lock is already in the right category — and
        // so the user's music, started from Control Center over our screen, is not silenced.
        // A no-op unless residency is wanted (the watch is streaming). Pause is deliberately
        // NOT an end: re-asserting a mixable session while paused would drop the Lock Screen
        // item the resume is about to come from.
        let receiver = self.receiver
        PlayerModel.onActivity = { activity in
            if activity == .ended { receiver.reassertResidencyAfterPlayback() }
        }
    }
}

/// Extensions cannot add stored properties, so the bridge is held here. One per process, like
/// `AppComposition.shared` itself.
@MainActor
private enum NowPlayingInstallation {
    static var publisher: (any NowPlayingPublishing)?
}
