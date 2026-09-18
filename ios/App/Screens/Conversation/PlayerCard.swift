import SwiftUI

/// The conversation player card (mockup 2.6): 44pt play, scrubber with the amber missing
/// ticks, timecodes, and the 1× speed pill cycling 1 → 1.5 → 2. Backed by `PlayerModel`,
/// which drives the real decoder-backed engine when the conversation has stored audio and
/// falls back to a simulated scrub only in the mock/demo world, which has none.
///
/// When the conversation screen pins this under the navigation bar during playback it pins
/// THIS view, unchanged — same controls, same size, same insets. Docking is a change of
/// surround (the screen puts a bar behind it), never a second, smaller player: a control that
/// rearranges itself as you scroll has to be re-found every time it moves.
struct PlayerCard: View {
    @Bindable var model: PlayerModel

    var body: some View {
        HStack(spacing: 12) {
            CirclePlayButton(isPlaying: model.playing) {
                model.togglePlay()
            }

            VStack(spacing: 6) {
                scrubber
                // Three values, and they are not the same KIND of value, so they are not drawn
                // the same. The ends are the recording's fixed bounds — set once, never moving,
                // so they recede. The middle is where the playhead actually is, in clock time:
                // it is the only one that changes, it is the one being read, and it carries the
                // label colour to say so.
                //
                // Wall clock rather than elapsed throughout. A recording is a thing that happened
                // at a time of day, "0:00 … 24:00" makes you do arithmetic against the header to
                // work out when you are, and the transcript beside it is already stamped in clock
                // time. Falls back to elapsed only when there is nothing to derive a mapping from.
                HStack(spacing: 8) {
                    Text(leadingLabel)
                        .foregroundStyle(Tokens.faint)
                    Spacer(minLength: 4)
                    Text(currentLabel)
                        .foregroundStyle(Tokens.label)
                        // The position ticks ten times a second; a proportional font would make
                        // the row breathe as digits change width.
                        .monospacedDigit()
                        .accessibilityHidden(true)
                    Spacer(minLength: 4)
                    Text(trailingLabel)
                        .foregroundStyle(Tokens.faint)
                }
                .font(AppFont.micro.monospacedDigit())
                .lineLimit(1)
            }

            Button {
                model.cycleSpeed()
            } label: {
                Text(model.speedLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tokens.tint)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Tokens.tintBorder))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Playback speed \(model.speedLabel)")
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(Tokens.surface)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.cardRadius))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.Playback.dockedPlayer)
    }

    /// When the recording started. Elapsed's "0:00" is the fallback, and it is honest: with no
    /// mapping there is no clock time to show.
    private var leadingLabel: String {
        guard let start = model.wallStart ?? model.wallDate(atMediaMs: 0) else {
            return TimeFmt.timecode(0)
        }
        return TranscriptStamp.text(start, in: model.wallTimeZone)
    }

    /// Where the playhead is, as a time of day.
    private var currentLabel: String {
        guard let now = model.wallDate(atMediaMs: model.positionMs) else {
            return TimeFmt.timecode(model.positionMs)
        }
        return TranscriptStamp.text(now, in: model.wallTimeZone)
    }

    /// When it ended. A live recording has no end yet and says so rather than naming the last
    /// moment audio happened to arrive, which would look like it had stopped.
    private var trailingLabel: String {
        guard let end = model.wallEnd ?? model.wallDate(atMediaMs: model.durationMs) else {
            return model.wallStart == nil ? TimeFmt.timecode(model.durationMs) : Copy.Playback.now
        }
        return TranscriptStamp.text(end, in: model.wallTimeZone)
    }

    private var scrubber: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let fraction = model.durationMs > 0
                ? CGFloat(model.positionMs) / CGFloat(model.durationMs) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Tokens.fieldFill).frame(height: 4)
                Capsule().fill(Tokens.tint)
                    .frame(width: max(4, width * min(fraction, 1)), height: 4)
                // Every gap, not just the first: loss is never summarized away.
                ForEach(Array(model.missingTicks.enumerated()), id: \.offset) { _, tick in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Tokens.missing)
                        .frame(width: 3, height: 6)
                        .offset(x: width * CGFloat(tick) - 1.5)
                        .accessibilityHidden(true)
                }
            }
            .frame(height: 8)
            .contentShape(Rectangle().inset(by: -12))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = min(max(value.location.x / max(width, 1), 0), 1)
                        model.seek(fraction: Double(fraction))
                    }
            )
        }
        .frame(height: 8)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(currentLabel), between \(leadingLabel) and \(trailingLabel)")
        .accessibilityAdjustableAction { direction in
            let step = model.durationMs / 20
            switch direction {
            case .increment: model.seek(positionMs: model.positionMs + step)
            case .decrement: model.seek(positionMs: model.positionMs - step)
            @unknown default: break
            }
        }
    }
}

// MARK: - Model

/// The transitions `PlayerModel.observeActivity` reports. `.ended` is the end of a listening
/// session — stopped, the screen left, or the audio ran out — as distinct from `.paused`, after
/// which the item stays on the Lock Screen and a resume is one press away.
enum PlaybackActivity: Equatable, Sendable {
    case playing
    case paused
    case ended
}

@MainActor
@Observable
final class PlayerModel {
    var playing = false
    var positionMs: Int64 = 0
    var durationMs: Int64 = 0
    var speed: Double = 1
    var missingTicks: [Double] = []

    /// Where the audio is in the transcript. Held here rather than in the screen because the
    /// position updates arrive here, ten times a second: routing them through the screen's own
    /// state would re-run its whole body at that rate. See `TranscriptPlayhead`.
    let playhead = TranscriptPlayhead()

    /// True from the moment playback starts until it is stopped or runs off the end.
    private(set) var hasStarted = false

    /// Whether this conversation is being LISTENED to, which is a longer thing than whether a
    /// sample is leaving the speaker right now. The docked player keys off this rather than off
    /// `playing`, because the pause button lives inside the docked player: un-docking the instant
    /// you press pause would take the control away at the exact moment it was used, and getting it
    /// back would mean scrolling to the top of the transcript.
    ///
    /// But it does not stay docked forever either. A pause you do not come back from is just
    /// reading, and the strip should get out of the way: `pauseGraceSeconds` after a pause,
    /// engagement lapses on its own and the player returns to its place in the page. Pressing play
    /// again — or scrubbing, or tapping a line — cancels that.
    ///
    /// Deliberately built out of two Bools and not out of `positionMs`, so reading it in a view
    /// body does not subscribe that view to the position ticker.
    var isEngaged: Bool { playing || hasStarted }

    /// How long a paused player stays docked. Long enough to press play again, or to read the
    /// line you paused on and decide; short enough that a player you have abandoned does not go
    /// on occupying the top of a transcript you are now reading.
    static let pauseGraceSeconds: Double = 15

    /// The decoder-backed engine over the conversation's stored frames. Nil in the mock and
    /// preview worlds, where `ticker` stands in for it.
    private var engine: (any ConversationPlayback)?
    private var configuredId: String?
    private var observation: Task<Void, Never>?
    /// True between `play()` and the engine's first `playing` update. The engine seeks before
    /// it starts and reports that seek as `playing: false` at the target — which is neither a
    /// pause nor the audio running out, and used to read as both: the docked player let go and
    /// the Lock Screen item was torn down and rebuilt a quarter of a second after every play.
    private var awaitingEngineStart = false
    private var ticker: Task<Void, Never>?
    /// Media position -> wall clock, as (mediaMs, wall) anchors in ascending media order.
    ///
    /// The scrubber counts MEDIA time (stored audio, gaps excluded), so it cannot be added to the
    /// conversation's start: on a recording with a 20-minute hole in it, every label after the
    /// hole would be 20 minutes early. The transcript's turns already carry both clocks, so they
    /// are the mapping — accurate at turn granularity, which is the granularity a person can see.
    /// Empty is the honest fallback (no transcript, or no timings): the card shows elapsed
    /// timecodes instead of inventing a wall time it cannot derive.
    var wallAnchors: [(mediaMs: Int64, wall: Date)] = []
    /// The zone the audio was RECORDED in (Q16) — the same one the transcript stamps use, so the
    /// scrubber and the turn beside it never name the same moment differently.
    var wallTimeZone: TimeZone = .current
    /// Wall clock at the two ends of the recording — the fixed bounds the scrubber spans.
    var wallStart: Date?
    var wallEnd: Date?

    /// Wall clock at a media position, interpolated between the two anchors around it.
    func wallDate(atMediaMs mediaMs: Int64) -> Date? {
        guard let first = wallAnchors.first else { return nil }
        if mediaMs <= first.mediaMs { return first.wall }
        var previous = first
        for anchor in wallAnchors.dropFirst() {
            if mediaMs <= anchor.mediaMs {
                let span = anchor.mediaMs - previous.mediaMs
                guard span > 0 else { return anchor.wall }
                let fraction = Double(mediaMs - previous.mediaMs) / Double(span)
                let seconds = anchor.wall.timeIntervalSince(previous.wall) * fraction
                return previous.wall.addingTimeInterval(seconds)
            }
            previous = anchor
        }
        // Past the last turn: carry on at real time, which is right for the tail of a recording
        // whose last words are not its last audio.
        return previous.wall.addingTimeInterval(Double(mediaMs - previous.mediaMs) / 1000)
    }

    /// Pending un-dock of a paused player. See `isEngaged`.
    private var engagementLapse: Task<Void, Never>?

    // MARK: Now Playing

    /// The system media surfaces (Lock Screen, Control Center, CarPlay, headphone buttons).
    /// Set by the screen from the composition; nil in previews, tests and the demo world's
    /// previews. Everything published through it is a STATE CHANGE — play, pause, seek, rate,
    /// content — never the position tick: the surfaces extrapolate the playhead themselves.
    var nowPlaying: (any NowPlayingPublishing)?
    /// What the surfaces call this conversation. Set by `describe(title:subtitle:)` on every
    /// load, because a rename lands while the audio may still be playing.
    private(set) var nowPlayingTitle = ""
    private(set) var nowPlayingSubtitle = ""
    /// Open while a burst of seeks is being coalesced. A scrubber drag seeks on every gesture
    /// frame; the first seek publishes at once and the rest fold into one trailing publish.
    private var seekPublishWindow: Task<Void, Never>?
    private var seekPublishPending = false
    /// How long a seek burst is coalesced for. Long enough to cover a drag's frame cadence,
    /// short enough that the Lock Screen catches up before the finger has fully lifted.
    static let seekPublishCoalesceMs = 250

    /// Whether a conversation is being played, for the parts of the app that live outside this
    /// screen: the residency re-assert (`AppComposition+NowPlaying.swift`) and the telemetry
    /// state reporter. Fires on transitions only. A list, not a slot: two subscribers must not
    /// have to know about each other.
    static func observeActivity(_ observer: @escaping @MainActor (PlaybackActivity) -> Void) {
        activityObservers.append(observer)
    }
    /// Tests only: the observers are process-wide.
    static func removeAllActivityObservers() { activityObservers.removeAll() }
    private static var activityObservers: [@MainActor (PlaybackActivity) -> Void] = []
    /// True from the first play of a listening session until it ends — through pauses. What
    /// the lifecycle coordinator should consult before re-asserting the residency session on
    /// `didEnterBackground`: while this is true the shared audio session belongs to playback.
    private(set) static var isListening = false

    private static func report(_ activity: PlaybackActivity) {
        isListening = activity != .ended
        for observer in activityObservers { observer(activity) }
    }

    var speedLabel: String {
        switch speed {
        case 1.5: return "1.5×"
        case 2: return "2×"
        default: return "1×"
        }
    }

    /// False once this conversation's engine is attached — the screen reloads its display
    /// after every rename, tag edit and retranscribe, and building a second engine each time
    /// would be pure waste.
    func needsEngine(for id: String) -> Bool { configuredId != id }

    /// Idempotent per conversation: the screen reloads its display after every rename, tag
    /// edit and retranscribe, and playback must not restart under the user each time.
    func configure(
        _ display: PlayerDisplay, atMs: Int64?, id: String,
        engine: (any ConversationPlayback)? = nil
    ) {
        missingTicks = display.missingTickFractions
        guard configuredId != id else {
            if durationMs == 0 { durationMs = display.durationMs }
            return
        }
        stop()
        configuredId = id
        self.engine = engine
        durationMs = engine.map { $0.durationMs > 0 ? $0.durationMs : display.durationMs }
            ?? display.durationMs
        positionMs = min(atMs ?? display.initialPositionMs, durationMs)
        if let engine {
            engine.setSpeed(speed)
            // Seed the engine BEFORE subscribing: its first update carries the engine's own
            // position, which would otherwise immediately overwrite the deep link's `?t=`
            // (or the display's initial position) with zero.
            engine.seek(toMs: positionMs)
            observe(engine)
        }
        playhead.update(mediaMs: positionMs, playing: playing)
    }

    /// The transcript the playhead runs along. Re-loaded on every display refresh because a
    /// re-transcribe replaces the words underneath a playing conversation.
    func loadTranscript(_ transcript: [TranscriptItem]) {
        playhead.load(transcript: transcript)
        playhead.update(mediaMs: positionMs, playing: playing)
    }

    private func observe(_ engine: any ConversationPlayback) {
        observation?.cancel()
        observation = Task { [weak self] in
            for await update in engine.progress() {
                guard let self, !Task.isCancelled else { return }
                self.apply(progress: update)
            }
        }
    }

    /// One engine update. Ten a second while playing, so what it publishes onward is gated: a
    /// position-only tick moves the scrubber and the transcript highlight and nothing else.
    func apply(progress update: PlaybackProgress) {
        let wasPlaying = playing
        let hadPosition = positionMs
        let hadDuration = durationMs
        if update.durationMs > 0 { durationMs = update.durationMs }
        if awaitingEngineStart, !update.playing {
            // The engine's seek-before-start: take the position, keep the play the person
            // just pressed.
            positionMs = update.positionMs
            playhead.update(mediaMs: update.positionMs, playing: playing)
            if hadDuration != durationMs { publishNowPlaying() }
            return
        }
        awaitingEngineStart = false
        playing = update.playing
        positionMs = update.positionMs
        // Running off the end rewinds to zero and stops: that is the session ending, not a
        // pause, so the docked player lets go too — and so does the Lock Screen. A pause is
        // told apart from it by where the audio was: the end comes after it has moved.
        let ended = wasPlaying && !update.playing && update.positionMs == 0 && hadPosition > 0
        if ended { hasStarted = false }
        playhead.update(mediaMs: update.positionMs, playing: update.playing)
        if ended {
            clearNowPlaying()
            Self.report(.ended)
        } else if wasPlaying != update.playing {
            publishNowPlaying()
            Self.report(update.playing ? .playing : .paused)
        } else if hadDuration != durationMs {
            // The engine's first update carries the duration the display only estimated.
            publishNowPlaying()
        }
    }

    func togglePlay() {
        playing ? pause() : play()
    }

    func play() {
        guard durationMs > 0 else { return }
        if positionMs >= durationMs { positionMs = 0 }
        let wasPlaying = playing
        playing = true
        hasStarted = true
        cancelEngagementLapse()
        if let engine {
            awaitingEngineStart = true
            engine.play(fromMs: positionMs)
        } else {
            simulate()
        }
        playhead.update(mediaMs: positionMs, playing: true)
        publishNowPlaying()
        if !wasPlaying { Self.report(.playing) }
    }

    /// Seek there and make sure it is running — the one move behind "play from here", whether
    /// it came from a citation band, a double tap on the transcript, or a VoiceOver action.
    func play(fromMs mediaMs: Int64) {
        seek(positionMs: mediaMs)
        if !playing { play() }
    }

    func pause() {
        let wasPlaying = playing
        playing = false
        awaitingEngineStart = false
        ticker?.cancel()
        ticker = nil
        engine?.pause()
        playhead.update(mediaMs: positionMs, playing: false)
        startEngagementLapse()
        // Paused, not gone: the Lock Screen keeps the item so the resume can come from there.
        publishNowPlaying()
        if wasPlaying { Self.report(.paused) }
    }

    /// Let engagement lapse if play is not pressed again. Re-armed from scratch on every pause,
    /// so pausing, resuming and pausing again gives the full grace each time.
    private func startEngagementLapse() {
        cancelEngagementLapse()
        engagementLapse = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.pauseGraceSeconds))
            guard !Task.isCancelled else { return }
            guard let self, !self.playing else { return }
            self.hasStarted = false
        }
    }

    private func cancelEngagementLapse() {
        engagementLapse?.cancel()
        engagementLapse = nil
    }

    /// Leaving the screen has to end the audio — a conversation that keeps playing from a
    /// screen the user popped is the kind of thing this app can never do.
    func stop() {
        let wasEngaged = hasStarted
        playing = false
        hasStarted = false
        awaitingEngineStart = false
        cancelEngagementLapse()
        ticker?.cancel()
        ticker = nil
        observation?.cancel()
        observation = nil
        engine?.stop()
        playhead.clear()
        clearNowPlaying()
        if wasEngaged { Self.report(.ended) }
    }

    /// 1× → 1.5× → 2× → 1× (mockup 2.6).
    func cycleSpeed() {
        switch speed {
        case 1: setSpeed(1.5)
        case 1.5: setSpeed(2)
        default: setSpeed(1)
        }
    }

    /// A speed the player offers (`NowPlayingSkip.rates`); anything else is ignored rather than
    /// handed to a rate unit that would honour it.
    func setSpeed(_ value: Double) {
        guard NowPlayingSkip.rates.contains(value), value != speed else { return }
        speed = value
        engine?.setSpeed(speed)
        // A rate change is exactly what the surfaces cannot extrapolate through.
        if hasStarted { publishNowPlaying() }
    }

    func seek(fraction: Double) {
        seek(positionMs: Int64(fraction * Double(durationMs)))
    }

    func seek(positionMs: Int64) {
        let clamped = min(max(positionMs, 0), durationMs)
        self.positionMs = clamped
        engine?.seek(toMs: clamped)
        // Move the highlight with the scrubber, paused or not: dragging to a moment and reading
        // what was said there is half of why the transcript follows the audio at all.
        playhead.update(mediaMs: clamped, playing: playing)
        // Scrubbing a paused player is still using it, so it earns its grace again — otherwise
        // the strip could vanish mid-drag, taking the scrubber out from under the finger.
        if !playing, hasStarted { startEngagementLapse() }
        // A seek is a discontinuity the surfaces cannot extrapolate through — but only once
        // there is something published; the deep link's `?t=` lands before play is pressed.
        if hasStarted { publishNowPlayingAfterSeek() }
    }

    // MARK: - Now Playing

    /// What the surfaces show above the controls. Called on every load, so a rename reaches
    /// the Lock Screen while the audio is still playing.
    func describe(title: String, subtitle: String) {
        guard title != nowPlayingTitle || subtitle != nowPlayingSubtitle else { return }
        nowPlayingTitle = title
        nowPlayingSubtitle = subtitle
        if hasStarted { publishNowPlaying() }
    }

    /// A command from a system surface. Each one is the same move the card would make.
    func handle(_ command: NowPlayingCommand) {
        switch command {
        case .play: play()
        case .pause: pause()
        case .togglePlayPause: togglePlay()
        case .skipForward(let seconds): seek(positionMs: positionMs + Int64(seconds * 1000))
        case .skipBackward(let seconds): seek(positionMs: positionMs - Int64(seconds * 1000))
        case .seek(let seconds): seek(positionMs: Int64(seconds * 1000))
        case .changeRate(let rate): setSpeed(rate)
        }
    }

    private func publishNowPlaying() {
        guard let nowPlaying, let configuredId, durationMs > 0 else { return }
        // Re-bound on every publish: the publisher is shared by every conversation screen on
        // the stack, and commands belong to whichever one is actually playing.
        nowPlaying.onCommand = { [weak self] command in self?.handle(command) }
        nowPlaying.publish(
            NowPlayingItem(
                id: configuredId, title: nowPlayingTitle, subtitle: nowPlayingSubtitle,
                duration: Double(durationMs) / 1000),
            NowPlayingPlayback(
                playing: playing, rate: speed, elapsed: Double(positionMs) / 1000))
    }

    /// Leading edge at once, trailing edge once: a drag seeks on every gesture frame, and each
    /// publish is an XPC round trip to the media server.
    private func publishNowPlayingAfterSeek() {
        guard seekPublishWindow == nil else {
            seekPublishPending = true
            return
        }
        publishNowPlaying()
        seekPublishWindow = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.seekPublishCoalesceMs))
            guard let self, !Task.isCancelled else { return }
            self.seekPublishWindow = nil
            if self.seekPublishPending {
                self.seekPublishPending = false
                if self.hasStarted { self.publishNowPlaying() }
            }
        }
    }

    private func clearNowPlaying() {
        seekPublishWindow?.cancel()
        seekPublishWindow = nil
        seekPublishPending = false
        nowPlaying?.clear()
    }

    /// The demo/preview stand-in: no audio exists in the mock world, so the scrubber moves on
    /// its own to show the card working. Never used against real recordings.
    private func simulate() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while let self, self.playing, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, self.playing else { return }
                self.positionMs += Int64(250 * self.speed)
                self.playhead.update(mediaMs: self.positionMs, playing: true)
                if self.positionMs >= self.durationMs {
                    self.positionMs = self.durationMs
                    self.pause()
                }
            }
        }
    }
}

#Preview("Player") {
    PlayerCard(model: {
        let model = PlayerModel()
        model.configure(
            PlayerDisplay(
                durationMs: 18 * 60_000 + 12_000,
                initialPositionMs: 4 * 60_000 + 1_000,
                missingTickFractions: [0.61]),
            atMs: nil, id: "preview")
        return model
    }())
    .padding(Tokens.screenMargin)
    .background(Tokens.ground)
}
