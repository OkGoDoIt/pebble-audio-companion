import Foundation
import Testing

// What conversation playback tells the Lock Screen, and when. The "when" is the point: the
// engine reports its position ten times a second, each publish is an XPC round trip to the
// media server, and the surfaces extrapolate the playhead from rate + elapsed + timestamp on
// their own. So a publish is a STATE CHANGE — play, pause, seek, rate, content — and a tick
// publishes nothing. Pinned here with a fake publisher that records every call, and a fake
// engine so nothing ticks on its own.

/// Records what `PlayerModel` publishes, in order.
@MainActor
final class FakeNowPlaying: NowPlayingPublishing {
    var onCommand: (@MainActor (NowPlayingCommand) -> Void)?
    var published: [(item: NowPlayingItem, playback: NowPlayingPlayback)] = []
    var clears = 0

    func publish(_ item: NowPlayingItem, _ playback: NowPlayingPlayback) {
        published.append((item, playback))
    }

    func clear() { clears += 1 }

    var last: NowPlayingPlayback? { published.last?.playback }
}

/// An engine that never reports on its own: the tests drive `apply(progress:)` directly, which
/// is exactly what the real observation loop does with each engine update.
@MainActor
private final class FakeEngine: ConversationPlayback {
    let durationMs: Int64
    var calls: [String] = []

    init(durationMs: Int64) { self.durationMs = durationMs }

    func progress() -> AsyncStream<PlaybackProgress> { AsyncStream { _ in } }
    func play(fromMs: Int64) { calls.append("play \(fromMs)") }
    func pause() { calls.append("pause") }
    func seek(toMs: Int64) { calls.append("seek \(toMs)") }
    func setSpeed(_ speed: Double) { calls.append("speed \(speed)") }
    func stop() { calls.append("stop") }
}

@MainActor
@Suite("now playing publishing", .serialized)
struct NowPlayingPublishingTests {

    private func makeModel(
        durationMs: Int64 = 120_000, atMs: Int64? = nil
    ) -> (PlayerModel, FakeNowPlaying, FakeEngine) {
        let model = PlayerModel()
        let publisher = FakeNowPlaying()
        let engine = FakeEngine(durationMs: durationMs)
        model.configure(
            PlayerDisplay(durationMs: durationMs), atMs: atMs, id: "conv-1", engine: engine)
        model.nowPlaying = publisher
        model.describe(title: "Coffee with Dana", subtitle: "Yesterday · 9:35 – 9:53 PM · 18 min")
        return (model, publisher, engine)
    }

    private func tick(_ model: PlayerModel, toMs: Int64, playing: Bool = true) {
        model.apply(progress: PlaybackProgress(playing: playing, positionMs: toMs, durationMs: 0))
    }

    // MARK: - When

    @Test("nothing is published before play: configuring and a deep-link seek are silent")
    func silentBeforePlay() {
        let (model, publisher, _) = makeModel(atMs: 30_000)
        model.seek(positionMs: 45_000)
        #expect(publisher.published.isEmpty)
        #expect(publisher.clears == 0)
    }

    @Test("play publishes once, with the item and where it started")
    func playPublishesOnce() throws {
        let (model, publisher, _) = makeModel(atMs: 30_000)
        model.play()
        #expect(publisher.published.count == 1)
        let entry = try #require(publisher.published.first)
        #expect(entry.item.id == "conv-1")
        #expect(entry.item.title == "Coffee with Dana")
        #expect(entry.item.subtitle == "Yesterday · 9:35 – 9:53 PM · 18 min")
        #expect(entry.item.duration == 120)
        #expect(entry.playback == NowPlayingPlayback(playing: true, rate: 1, elapsed: 30))
    }

    @Test("position ticks publish nothing — the surfaces extrapolate")
    func ticksPublishNothing() {
        let (model, publisher, _) = makeModel()
        model.play()
        for ms in stride(from: Int64(80), through: 4_000, by: 80) { tick(model, toMs: ms) }
        #expect(model.positionMs == 4_000)
        #expect(publisher.published.count == 1)
    }

    @Test("the engine's first update with a real duration republishes once")
    func durationCorrectionPublishes() {
        let (model, publisher, _) = makeModel()
        model.play()
        model.apply(progress: PlaybackProgress(playing: true, positionMs: 0, durationMs: 121_000))
        #expect(publisher.published.count == 2)
        #expect(publisher.published.last?.item.duration == 121)
        tick(model, toMs: 80)
        #expect(publisher.published.count == 2)
    }

    @Test("the engine's seek-before-start is neither a pause nor an end")
    func preStartSeekIsIgnored() {
        var seen: [PlaybackActivity] = []
        PlayerModel.observeActivity { seen.append($0) }
        defer { PlayerModel.removeAllActivityObservers() }

        let (model, publisher, _) = makeModel(atMs: 30_000)
        model.play()
        // What `SegmentPlaybackController.seekTo` reports before `play` has started the loop.
        model.apply(progress: PlaybackProgress(playing: false, positionMs: 30_000, durationMs: 0))
        #expect(model.playing, "the play the person pressed stands")
        #expect(model.isEngaged)
        #expect(publisher.published.count == 1)
        #expect(publisher.clears == 0)
        // Then the loop starts: still the same state, still nothing new to publish.
        model.apply(progress: PlaybackProgress(playing: true, positionMs: 30_000, durationMs: 0))
        #expect(publisher.published.count == 1)
        #expect(seen == [.playing])
    }

    @Test("a pause at the very start is a pause, not the end")
    func pauseAtZeroIsAPause() {
        let (model, publisher, _) = makeModel()
        model.play()
        tick(model, toMs: 0)
        tick(model, toMs: 0, playing: false)
        #expect(model.isEngaged)
        #expect(publisher.clears == 0)
        #expect(publisher.last?.playing == false)
    }

    @Test("a seek publishes once, at the new position")
    func seekPublishesOnce() {
        let (model, publisher, _) = makeModel()
        model.play()
        tick(model, toMs: 10_000)
        model.seek(positionMs: 60_000)
        #expect(publisher.published.count == 2)
        #expect(publisher.last == NowPlayingPlayback(playing: true, rate: 1, elapsed: 60))
    }

    @Test("a scrubber drag is one leading and one trailing publish, not one per frame")
    func seekBurstIsCoalesced() async {
        let (model, publisher, _) = makeModel()
        model.play()
        for ms in stride(from: Int64(1_000), through: 30_000, by: 1_000) {
            model.seek(positionMs: ms)
        }
        #expect(publisher.published.count == 2, "play + the leading edge")
        #expect(publisher.last?.elapsed == 1)
        try? await Task.sleep(for: .milliseconds(PlayerModel.seekPublishCoalesceMs * 3))
        #expect(publisher.published.count == 3, "one trailing publish for the whole burst")
        #expect(publisher.last?.elapsed == 30)
    }

    @Test("pause publishes paused at the heard position — the item stays for the resume")
    func pausePublishesPaused() {
        let (model, publisher, _) = makeModel()
        model.play()
        tick(model, toMs: 12_500)
        model.pause()
        #expect(publisher.published.count == 2)
        #expect(publisher.last == NowPlayingPlayback(playing: false, rate: 1, elapsed: 12.5))
        #expect(publisher.clears == 0)
    }

    @Test("a rate change publishes the new rate; an unknown rate is ignored")
    func rateChangePublishes() {
        let (model, publisher, engine) = makeModel()
        model.play()
        model.cycleSpeed()
        #expect(publisher.published.count == 2)
        #expect(publisher.last?.rate == 1.5)
        model.setSpeed(3)
        #expect(model.speed == 1.5)
        #expect(publisher.published.count == 2)
        #expect(engine.calls.contains("speed 1.5"))
        #expect(!engine.calls.contains("speed 3.0"))
    }

    @Test("a rename while playing reaches the surfaces; before play it does not")
    func renameRepublishes() {
        let (model, publisher, _) = makeModel()
        model.describe(title: "Renamed early", subtitle: "meta")
        #expect(publisher.published.isEmpty)
        model.play()
        model.describe(title: "Coffee with Dana and Sam", subtitle: "meta")
        #expect(publisher.published.count == 2)
        #expect(publisher.published.last?.item.title == "Coffee with Dana and Sam")
        model.describe(title: "Coffee with Dana and Sam", subtitle: "meta")
        #expect(publisher.published.count == 2, "an unchanged description is not a change")
    }

    @Test("stop clears the item")
    func stopClears() {
        let (model, publisher, engine) = makeModel()
        model.play()
        model.stop()
        #expect(publisher.clears == 1)
        #expect(engine.calls.contains("stop"))
    }

    @Test("running off the end clears the item — that is the session ending, not a pause")
    func endOfAudioClears() {
        let (model, publisher, _) = makeModel()
        model.play()
        tick(model, toMs: 119_920)
        tick(model, toMs: 0, playing: false)
        #expect(!model.isEngaged)
        #expect(publisher.clears == 1)
        #expect(publisher.published.count == 1)
    }

    @Test("switching conversations clears before the next one can publish")
    func reconfigureClears() {
        let (model, publisher, _) = makeModel()
        model.play()
        model.configure(
            PlayerDisplay(durationMs: 5_000), atMs: nil, id: "conv-2",
            engine: FakeEngine(durationMs: 5_000))
        #expect(publisher.clears == 1)
        model.play()
        #expect(publisher.published.last?.item.id == "conv-2")
    }

    // MARK: - Remote commands

    @Test("the publisher's commands are bound to the model that published")
    func commandsRoundTrip() throws {
        let (model, publisher, engine) = makeModel()
        model.play()
        let send = try #require(publisher.onCommand)

        send(.pause)
        #expect(!model.playing)
        #expect(publisher.last?.playing == false)

        send(.play)
        #expect(model.playing)

        send(.togglePlayPause)
        #expect(!model.playing)
        send(.togglePlayPause)
        #expect(model.playing)

        tick(model, toMs: 20_000)
        send(.skipForward(15))
        #expect(model.positionMs == 35_000)
        #expect(engine.calls.contains("seek 35000"))
        #expect(publisher.last?.elapsed == 35)

        send(.skipBackward(15))
        #expect(model.positionMs == 20_000)

        send(.seek(90.5))
        #expect(model.positionMs == 90_500)

        send(.changeRate(2))
        #expect(model.speed == 2)
        #expect(publisher.last?.rate == 2)
    }

    @Test("a skip is clamped to the recording")
    func skipsClamp() {
        let (model, _, _) = makeModel(durationMs: 20_000)
        model.play()
        model.handle(.skipBackward(15))
        #expect(model.positionMs == 0)
        model.handle(.skipForward(15))
        model.handle(.skipForward(15))
        #expect(model.positionMs == 20_000)
    }

    @Test("commands follow the last publisher: a popped screen's model no longer receives them")
    func commandsFollowTheLastPublish() {
        let publisher = FakeNowPlaying()
        let first = PlayerModel()
        first.configure(
            PlayerDisplay(durationMs: 10_000), atMs: nil, id: "conv-1",
            engine: FakeEngine(durationMs: 10_000))
        first.nowPlaying = publisher
        first.play()
        first.stop()
        let second = PlayerModel()
        second.configure(
            PlayerDisplay(durationMs: 10_000), atMs: nil, id: "conv-2",
            engine: FakeEngine(durationMs: 10_000))
        second.nowPlaying = publisher
        second.play()
        publisher.onCommand?(.pause)
        #expect(!second.playing)
        #expect(!first.playing)
    }

    // MARK: - Activity hook

    @Test("the activity hook reports transitions only")
    func activityTransitions() {
        var seen: [PlaybackActivity] = []
        PlayerModel.observeActivity { seen.append($0) }
        defer { PlayerModel.removeAllActivityObservers() }

        let (model, _, _) = makeModel()
        #expect(seen.isEmpty, "configuring a fresh model is not a transition")
        // `isListening` is process-wide and an earlier test may have left a model playing, so
        // it is asserted after transitions rather than before them.
        model.play()
        model.play()
        #expect(PlayerModel.isListening)
        model.pause()
        model.pause()
        #expect(PlayerModel.isListening, "a pause is still a listening session")
        model.play()
        model.stop()
        model.stop()
        #expect(seen == [.playing, .paused, .playing, .ended])
        #expect(!PlayerModel.isListening)
    }

    @Test("two observers both hear every transition")
    func observersAreAList() {
        var first: [PlaybackActivity] = []
        var second: [PlaybackActivity] = []
        PlayerModel.observeActivity { first.append($0) }
        PlayerModel.observeActivity { second.append($0) }
        defer { PlayerModel.removeAllActivityObservers() }

        let (model, _, _) = makeModel()
        model.play()
        model.stop()
        #expect(first == [.playing, .ended])
        #expect(second == [.playing, .ended])
    }

    @Test("the end of the audio is an end, and a pause is not")
    func endOfAudioIsAnEnd() {
        var seen: [PlaybackActivity] = []
        PlayerModel.observeActivity { seen.append($0) }
        defer { PlayerModel.removeAllActivityObservers() }

        let (model, _, _) = makeModel()
        model.play()
        tick(model, toMs: 5_000)
        tick(model, toMs: 5_000, playing: false)
        #expect(seen == [.playing, .paused])
        tick(model, toMs: 5_000, playing: true)
        tick(model, toMs: 0, playing: false)
        #expect(seen == [.playing, .paused, .playing, .ended])
    }
}
