import AppIntents
import Foundation

#if canImport(NowPlaying)
    import NowPlaying

    /// The iOS 27 bridge: one `MediaSession` over an `@Observable` model the framework watches.
    /// A publish is an assignment to the model — the framework reads `content`,
    /// `playbackSnapshot` and `commands` itself whenever they change — so there is no
    /// dictionary to rebuild and no target to register.
    ///
    /// The session lives for one listening session: created on the first publish, dropped on
    /// `clear()`. Play → pause → play keeps it (the Lock Screen must not lose the item while it
    /// is paused); leaving the screen or running off the end ends it.
    @available(iOS 27, *)
    @MainActor
    final class MediaSessionNowPlaying: NowPlayingPublishing {
        var onCommand: (@MainActor (NowPlayingCommand) -> Void)?

        /// The App Intents identities of the conversation, for "Siri, save this" and friends.
        /// SEAM: the entity type is built by the Siri workstream; until it lands on this branch
        /// the default publishes none, and the content is exactly as useful as on iOS 26.
        typealias EntityIdentifiers = @MainActor (_ conversationId: String) -> [EntityIdentifier]

        private let entityIdentifiers: EntityIdentifiers
        private let log: @MainActor (String) -> Void
        private let model = ConversationMediaModel()
        private var session: MediaSession<ConversationMediaModel>?
        private var published: NowPlayingItem?

        init(
            entityIdentifiers: @escaping EntityIdentifiers = { _ in [] },
            log: @escaping @MainActor (String) -> Void = { _ in }
        ) {
            self.entityIdentifiers = entityIdentifiers
            self.log = log
        }

        func publish(_ item: NowPlayingItem, _ playback: NowPlayingPlayback) {
            if session == nil {
                model.commands = makeCommands()
                let session = MediaSession(model)
                self.session = session
                log("now playing: session id=\(item.id) api=nowplaying")
            }
            if published != item {
                var content = GenericContent(
                    id: item.id,
                    title: item.title,
                    subtitle: item.subtitle,
                    type: .audio,
                    duration: .finite(item.duration),
                    artwork: nil)
                let identifiers = entityIdentifiers(item.id)
                if !identifiers.isEmpty { content.appEntityIdentifiers = identifiers }
                model.content = content
                published = item
            }
            model.playbackSnapshot = MediaPlaybackSnapshot(
                state: playback.playing ? .playing(rate: Float(playback.rate)) : .paused,
                defaultPlaybackRate: Float(playback.rate),
                elapsedTime: playback.elapsed,
                timestamp: Date())
        }

        func clear() {
            guard session != nil else { return }
            model.playbackSnapshot = MediaPlaybackSnapshot(state: .stopped)
            model.content = nil
            session = nil
            published = nil
            log("now playing: cleared api=nowplaying")
        }

        /// Whether the system is showing this session, for the diagnostics line. Nil before
        /// the first publish.
        var isSystemPrimary: Bool? { session?.isSystemPrimary }

        // MARK: - Commands

        private func makeCommands() -> [MediaCommand] {
            [
                .play { [weak self] in self?.deliver(.play) },
                .pause { [weak self] in self?.deliver(.pause) },
                .togglePlayPause { [weak self] in self?.deliver(.togglePlayPause) },
                .skipForward(preferredIntervals: [NowPlayingSkip.interval]) { [weak self] interval in
                    self?.deliver(.skipForward(interval))
                },
                .skipBackward(preferredIntervals: [NowPlayingSkip.interval]) { [weak self] interval in
                    self?.deliver(.skipBackward(interval))
                },
                .seekToPosition { [weak self] position in self?.deliver(.seek(position)) },
                .changePlaybackRate(supported: NowPlayingSkip.rates.map { Float($0) }) {
                    [weak self] rate in self?.deliver(.changeRate(Double(rate)))
                },
            ]
        }

        private func deliver(_ command: NowPlayingCommand) {
            log("now playing: command=\(command) api=nowplaying")
            onCommand?(command)
        }
    }

    /// What the framework observes. Plain stored properties: the framework re-reads them on
    /// change, which is the whole publishing mechanism.
    @available(iOS 27, *)
    @MainActor
    @Observable
    private final class ConversationMediaModel: MediaSessionRepresentable {
        let id = "conversation-playback"
        var content: (any MediaContentRepresentable)?
        var playbackSnapshot: MediaPlaybackSnapshot?
        var commands: [MediaCommand] = []
    }
#endif
