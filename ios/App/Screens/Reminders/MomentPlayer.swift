import Foundation
import Observation

/// "Play the moment" on a review card: the words that made the follow-up, played where the
/// card is, through the same conversation playback the player card uses and found the same way
/// the follow-up's own screen finds them (`FollowUpsDataSource.source(of:)`).
///
/// Where there is no stored audio to play (the demo world, audio still in iCloud), the moment
/// is opened in its conversation instead, which is what the follow-up's screen offers.
@MainActor
@Observable
final class MomentPlayer {
    private(set) var playingId: String?
    private var engine: (any ConversationPlayback)?
    private var stopTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?

    /// Plays `item`'s moment, or stops it if it is the one playing. Returns the conversation to
    /// open instead when there is nothing here to play.
    func toggle(_ item: FollowUpItem) async -> CitationTarget? {
        if playingId == item.id {
            stop()
            return nil
        }
        stop()
        guard let target = await AskLibraryDataSources.current.followUps.source(of: item.id)
        else { return nil }
        guard let start = target.mediaOffsetMs,
            let playback = try? await AskLibraryDataSources.current.conversations.playback(
                id: target.conversationId)
        else { return target }
        engine = playback
        playingId = item.id
        playback.play(fromMs: start)
        // A little past the quote's end, so the last word is not clipped; a whole sentence's
        // worth when the quote's length is unknown.
        let lengthMs = (item.momentLengthMs ?? 12_000) + 1_200
        stopTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(lengthMs))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
        progressTask = Task { [weak self] in
            for await progress in playback.progress() {
                // Ran off the end of the recording, or paused from the Lock Screen.
                if !progress.playing, progress.positionMs > start {
                    self?.stop()
                    return
                }
            }
        }
        return nil
    }

    func stop() {
        stopTask?.cancel()
        stopTask = nil
        progressTask?.cancel()
        progressTask = nil
        engine?.stop()
        engine = nil
        playingId = nil
    }
}
