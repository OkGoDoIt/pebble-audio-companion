import CompanionRuntime
import Foundation

// Strings for following a recording through its transcript: the docked player, the
// return-to-the-playhead control, and the accessibility wording for tapping into the audio.
//
// Vocabulary rules that apply here:
// - Never claim precision. The transcript follows the words when the provider gave word
//   timings and follows the paragraph when it did not, and nothing on screen announces which:
//   a label reading "word-accurate" would be a lie on exactly the recordings where it matters.
// - "playing" is the audio, not the recording. The watch "records"; this screen "plays".
// - The return control names its destination ("the words being spoken"), not its mechanism.

extension Copy {
    enum Playback {
        /// Right-hand scrubber label on a recording that has not ended yet. Naming the last
        /// moment audio arrived would read as an end time it does not have.
        static let now = "now"

        /// Floating control offered once the reader has scrolled away from the playhead.
        static let backToPlaying = "Back to playing"
        static let backToPlayingHint = "Scrolls back to the words being spoken"

        // The VoiceOver action on a transcript paragraph reuses `Copy.Conversation
        // .playFromHere` — it is the same offer the citation band makes, and one wording for
        // one action is the point of the catalog.

        /// The player once it has docked under the navigation bar.
        static let dockedPlayer = "Playback controls"
    }
}


// MARK: - Audio in iCloud

extension Copy.Conversation {
    /// The cold-audio card, where the player would be. The first line says where the audio
    /// is; the second says what the tap does. Never "no audio": the recording is real and the
    /// words beside it prove it.
    static let audioInCloud = "Audio is in iCloud"
    static let audioInCloudLine = "Fetch it to listen. Transcript and notes are already here."
    static let fetchAudio = "Fetch"
    static let fetchingAudio = "Fetching from iCloud…"
    static let audioInCloudUnreachable = "iCloud Drive isn’t available on this phone right now"
    static let audioInCloudUnreachableLine =
        "The audio is safe in iCloud. Turn on iCloud Drive for Pebble Audio in iOS Settings to fetch it."
    /// One calm line for a fetch that did not finish; the raw error stays in the log.
    static func fetchFailed(describing error: Error) -> String {
        if let fetch = error as? ColdAudioTier.FetchError {
            switch fetch {
            case .unreachable: return audioInCloudUnreachableLine
            case .missing: return "iCloud has no copy of this audio. It may have been removed from iCloud Drive."
            case .timedOut: return "iCloud is taking too long. Check the connection and try again."
            case .failed(_, let reason): return "iCloud couldn’t fetch the audio: \(reason)"
            }
        }
        return "The audio couldn’t be fetched. Try again."
    }
}
