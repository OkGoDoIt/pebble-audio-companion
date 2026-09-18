import AppIntents
import Foundation

#if canImport(NowPlaying)
    import NowPlaying

    /// The iOS 27 bridge: one `MediaSession` over an `@Observable` model the framework watches.
    /// A publish is an assignment to the model — the framework reads `content`,
    /// `playbackSnapshot` and `commands` itself whenever what they are built from changes — so
    /// there is no dictionary to rebuild and no target to register.
    ///
    /// The session lives for one listening session: created on the first publish, dropped on
    /// `clear()`. Play → pause → play keeps it (the Lock Screen must not lose the item while it
    /// is paused); leaving the screen or running off the end ends it.
    ///
    /// ## No NowPlaying type in a stored property — on purpose
    ///
    /// NowPlaying is weak-linked (deployment target 26, framework from 27). Every Swift class is
    /// an Objective-C class at runtime, and anything that walks the class list — XCTest does at
    /// bootstrap, `objc_copyClassList` — realizes them ALL, availability or not. Completing a
    /// class whose stored property is a `MediaPlaybackSnapshot?` or a `MediaSession<…>?` asks
    /// the absent framework for type metadata: a null call, and the test bundle died on the
    /// iOS 26.5 simulator before a single test ran. So the two classes here store only the
    /// app's own types (and `AnyObject` for the session) and build the framework's values on
    /// read. `#available` guards calls, not class layout.
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
        /// The `MediaSession<ConversationMediaModel>`, type-erased in storage (see above).
        private var session: AnyObject?

        init(
            entityIdentifiers: @escaping EntityIdentifiers = { _ in [] },
            log: @escaping @MainActor (String) -> Void = { _ in }
        ) {
            self.entityIdentifiers = entityIdentifiers
            self.log = log
        }

        func publish(_ item: NowPlayingItem, _ playback: NowPlayingPlayback) {
            if session == nil {
                model.deliver = { [weak self] command in self?.deliver(command) }
                session = MediaSession(model)
                log("now playing: session id=\(item.id) api=nowplaying")
            }
            if model.item != item {
                model.identifiers = entityIdentifiers(item.id)
                model.item = item
            }
            model.playback = playback
            model.publishedAt = Date()
        }

        func clear() {
            guard session != nil else { return }
            model.item = nil
            model.playback = nil
            model.identifiers = []
            session = nil
            log("now playing: cleared api=nowplaying")
        }

        /// Whether the system is showing this session, for the diagnostics line. Nil before
        /// the first publish.
        var isSystemPrimary: Bool? {
            (session as? MediaSession<ConversationMediaModel>)?.isSystemPrimary
        }

        private func deliver(_ command: NowPlayingCommand) {
            log("now playing: command=\(command) api=nowplaying")
            onCommand?(command)
        }
    }

    /// What the framework observes. The stored properties are the app's own types; the three
    /// protocol requirements are computed from them, which is what the framework's observation
    /// tracks (see the note on `MediaSessionNowPlaying`).
    @available(iOS 27, *)
    @MainActor
    @Observable
    private final class ConversationMediaModel: MediaSessionRepresentable {
        let id = "conversation-playback"
        var item: NowPlayingItem?
        var playback: NowPlayingPlayback?
        var identifiers: [EntityIdentifier] = []
        /// When `playback` was taken: the surfaces extrapolate the playhead from here.
        var publishedAt = Date()
        var deliver: (@MainActor (NowPlayingCommand) -> Void)?

        var content: (any MediaContentRepresentable)? {
            guard let item else { return nil }
            var content = GenericContent(
                id: item.id,
                title: item.title,
                subtitle: item.subtitle,
                type: .audio,
                duration: .finite(item.duration),
                artwork: nil)
            if !identifiers.isEmpty { content.appEntityIdentifiers = identifiers }
            return content
        }

        var playbackSnapshot: MediaPlaybackSnapshot? {
            guard let playback else { return MediaPlaybackSnapshot(state: .stopped) }
            return MediaPlaybackSnapshot(
                state: playback.playing ? .playing(rate: Float(playback.rate)) : .paused,
                defaultPlaybackRate: Float(playback.rate),
                elapsedTime: playback.elapsed,
                timestamp: publishedAt)
        }

        var commands: [MediaCommand] {
            [
                .play { [weak self] in self?.deliver?(.play) },
                .pause { [weak self] in self?.deliver?(.pause) },
                .togglePlayPause { [weak self] in self?.deliver?(.togglePlayPause) },
                .skipForward(preferredIntervals: [NowPlayingSkip.interval]) { [weak self] interval in
                    self?.deliver?(.skipForward(interval))
                },
                .skipBackward(preferredIntervals: [NowPlayingSkip.interval]) { [weak self] interval in
                    self?.deliver?(.skipBackward(interval))
                },
                .seekToPosition { [weak self] position in self?.deliver?(.seek(position)) },
                .changePlaybackRate(supported: NowPlayingSkip.rates.map { Float($0) }) {
                    [weak self] rate in self?.deliver?(.changeRate(Double(rate)))
                },
            ]
        }
    }
#endif
