import Foundation
import MediaPlayer

/// The iOS 26 bridge: `MPNowPlayingInfoCenter` for what is playing and `MPRemoteCommandCenter`
/// for what the person does about it. Unchanged behaviour is the requirement on 26, so this is
/// the plainest possible use of the two — no artwork pipeline, no queue, one item at a time.
///
/// Command targets are registered on the first publish and kept for the life of the object:
/// registering per publish would leak a target per play, and removing them on `clear()` would
/// drop the headphone button between a pause and the resume it is about to trigger.
@MainActor
final class MediaPlayerNowPlaying: NowPlayingPublishing {
    var onCommand: (@MainActor (NowPlayingCommand) -> Void)?

    private let log: @MainActor (String) -> Void
    private var targets: [(MPRemoteCommand, Any)] = []
    private var published: NowPlayingItem?

    init(log: @escaping @MainActor (String) -> Void = { _ in }) {
        self.log = log
    }

    isolated deinit {
        for (command, target) in targets { command.removeTarget(target) }
    }

    func publish(_ item: NowPlayingItem, _ playback: NowPlayingPlayback) {
        registerCommandsIfNeeded()
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = [
            MPMediaItemPropertyTitle: item.title,
            MPMediaItemPropertyArtist: item.subtitle,
            MPMediaItemPropertyPlaybackDuration: item.duration,
            MPNowPlayingInfoPropertyExternalContentIdentifier: item.id,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: playback.elapsed,
            // Rate 0 while paused is how the surfaces know to hold the playhead still.
            MPNowPlayingInfoPropertyPlaybackRate: playback.playing ? playback.rate : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: playback.rate,
        ]
        center.playbackState = playback.playing ? .playing : .paused
        if published?.id != item.id {
            log("now playing: session id=\(item.id) api=mediaplayer")
        }
        published = item
    }

    func clear() {
        guard published != nil else { return }
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
        log("now playing: cleared api=mediaplayer")
        published = nil
    }

    // MARK: - Remote commands

    private func registerCommandsIfNeeded() {
        guard targets.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: NowPlayingSkip.interval)]
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: NowPlayingSkip.interval)]
        center.changePlaybackRateCommand.supportedPlaybackRates = NowPlayingSkip.rates.map {
            NSNumber(value: $0)
        }
        // The event is read on the delivering thread and only the value crosses to the main
        // actor: `MPRemoteCommandEvent` is not Sendable, and the handler's status is returned
        // before the model acts — every command here is one the player can always take.
        add(center.playCommand) { _ in .play }
        add(center.pauseCommand) { _ in .pause }
        add(center.togglePlayPauseCommand) { _ in .togglePlayPause }
        add(center.skipForwardCommand) { event in
            .skipForward((event as? MPSkipIntervalCommandEvent)?.interval ?? NowPlayingSkip.interval)
        }
        add(center.skipBackwardCommand) { event in
            .skipBackward(
                (event as? MPSkipIntervalCommandEvent)?.interval ?? NowPlayingSkip.interval)
        }
        add(center.changePlaybackPositionCommand) { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return nil }
            return .seek(event.positionTime)
        }
        add(center.changePlaybackRateCommand) { event in
            guard let event = event as? MPChangePlaybackRateCommandEvent else { return nil }
            return .changeRate(Double(event.playbackRate))
        }
        // Nothing to go to: a conversation is one item, and next/previous on the Lock Screen
        // would only ever do nothing.
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
    }

    private func add(
        _ command: MPRemoteCommand,
        _ translate: @escaping @Sendable (MPRemoteCommandEvent) -> NowPlayingCommand?
    ) {
        command.isEnabled = true
        let target = command.addTarget { [weak self] event in
            guard let translated = translate(event) else { return .commandFailed }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.log("now playing: command=\(translated) api=mediaplayer")
                self.onCommand?(translated)
            }
            return .success
        }
        targets.append((command, target))
    }
}
