import Foundation
import WireProtocol

#if canImport(AVFoundation) && os(iOS)
    import AVFoundation
#endif

/// What the phone's own audio system says about playback, for the watch's PHONE_MEDIA_QUERY.
///
/// The watch's now-playing peek reads Apple Media Service, which reports what a player publishes.
/// BookPlayer publishes "playing at 1x" when it pauses (its time update overwrites the 0 rate the
/// pause just set), so AMS kept telling the watch a paused book was playing, for hours, while
/// Control Center showed it paused. The audio session cannot be fooled that way: it knows whether
/// another app is actually producing audio. Reading it is a property access, no session needed;
/// while the watch streams, `BackgroundResidency` keeps this process running to answer promptly.
public enum PhoneMediaProbe {
    public static func read() -> UInt8 {
        #if canImport(AVFoundation) && os(iOS)
            let session = AVAudioSession.sharedInstance()
            var flags = PhoneMediaState.flagChecked
            if session.isOtherAudioPlaying {
                flags |= PhoneMediaState.flagOtherAudio
            }
            if session.secondaryAudioShouldBeSilencedHint {
                flags |= PhoneMediaState.flagPrimaryAudio
            }
            return flags
        #else
            return 0
        #endif
    }
}
