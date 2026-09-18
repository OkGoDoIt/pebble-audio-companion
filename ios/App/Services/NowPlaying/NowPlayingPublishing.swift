import Foundation

// The bridge between conversation playback and the system's media surfaces — Lock Screen,
// Control Center, the Dynamic Island, CarPlay, headphone buttons and Siri. `PlayerModel` is
// the one owner of playback state and publishes through this; the two implementations are
// the NowPlaying framework on iOS 27 (`MediaSessionNowPlaying`) and MediaPlayer's
// `MPNowPlayingInfoCenter` on iOS 26 (`MediaPlayerNowPlaying`). Chosen at runtime in
// `AppComposition+NowPlaying.swift`.
//
// The contract that keeps this cheap: a publish is a STATE CHANGE — play, pause, a seek, a
// rate change, new content — never the 80 ms position tick. Both system APIs interpolate the
// playhead from rate + elapsed + timestamp, so the tick has nothing to add and each publish is
// an XPC round trip the phone would otherwise make ten times a second for the whole recording.

/// The thing being played, as the system surfaces name it.
struct NowPlayingItem: Equatable, Sendable {
    /// The conversation id (`conv-…`) — also what the iOS 27 entity seam keys off.
    var id: String
    var title: String
    /// The meta line ("Yesterday · 9:35 – 9:53 PM · 18 min"): where and when, under the title.
    var subtitle: String
    /// MEDIA duration in seconds — the audio stored, gaps excluded — matching the scrubber.
    var duration: TimeInterval
}

/// Where playback is, at the instant it was published. The surfaces extrapolate from here.
struct NowPlayingPlayback: Equatable, Sendable {
    var playing: Bool
    /// The speed pill: 1, 1.5 or 2. Published as the rate so the extrapolation is right.
    var rate: Double
    var elapsed: TimeInterval
}

/// A command the person gave through a system surface rather than through the player card.
enum NowPlayingCommand: Equatable, Sendable {
    case play
    case pause
    case togglePlayPause
    case skipForward(TimeInterval)
    case skipBackward(TimeInterval)
    /// Scrubbing on the Lock Screen: an absolute position in seconds.
    case seek(TimeInterval)
    case changeRate(Double)
}

/// The skip step the surfaces offer. Fifteen seconds is the spoken-word convention (Podcasts),
/// and the transcript beside the player is at paragraph granularity, so a smaller step buys
/// nothing.
enum NowPlayingSkip {
    static let interval: TimeInterval = 15
    /// The speeds the player offers, for surfaces that show a rate control.
    static let rates: [Double] = [1, 1.5, 2]
}

@MainActor
protocol NowPlayingPublishing: AnyObject {
    /// Commands from the system surfaces. Set by whichever `PlayerModel` published last, on
    /// every publish, so a stacked conversation screen that resumes after another was popped
    /// takes the commands back with it.
    var onCommand: (@MainActor (NowPlayingCommand) -> Void)? { get set }

    /// Shows or updates the item. Idempotent; the implementations diff nothing, so the caller
    /// owns the "only on a state change" rule above.
    func publish(_ item: NowPlayingItem, _ playback: NowPlayingPlayback)

    /// Takes the item down: playback stopped, or the screen was left. A no-op when nothing is
    /// published.
    func clear()
}
