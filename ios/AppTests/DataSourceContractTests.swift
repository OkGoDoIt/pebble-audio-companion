import AppDB
import Foundation
import Intelligence
import StatusUI
import Testing

/// The App-layer fixes that shipped today with no test behind them: note regenerate, the
/// export count, the watch's real name, and the queue line that never said why it was stalled.
///
/// The behaviours a mock CAN carry are asserted against the mock here; the live half is pinned
/// to the same shape by `LiveMockConformanceTests`, which is the only way to reach it from a
/// test bundle with no database.
@Suite("data source contracts") @MainActor
struct DataSourceContractTests {

    // MARK: - Note regenerate keeps the note the screen is looking at

    /// `SavedNotesScreen` addresses a note by its ROUTE id. Regeneration used to mint a new id
    /// and delete the old row, so the screen was left pointing at nothing: Edit → Save silently
    /// discarded the user's text and the note appeared to vanish, while the regenerated copy
    /// stayed in the library.
    @Test func regenerateRewritesTheSameNote() async throws {
        let world = MockWorld.shared
        let original = try #require(try await world.notes(conversationId: "planning-work").first)

        let regenerated = try await world.regenerate(noteId: original.id)

        #expect(regenerated.id == original.id, "the screen's route id has to survive")
        let stillThere = try await world.note(id: original.id)
        #expect(stillThere != nil, "the note the screen points at must still exist")
        #expect(stillThere?.conversationId == original.conversationId)
    }

    /// The consequence that actually bit: an edit saved after a regenerate has to land on a row
    /// that is still there.
    @Test func anEditAfterRegenerateIsNotDiscarded() async throws {
        let world = MockWorld.shared
        let original = try #require(try await world.notes(conversationId: "planning-work").first)

        _ = try await world.regenerate(noteId: original.id)
        try await world.saveEdit(
            noteId: original.id, title: "Edited title", body: "Edited body")

        let reloaded = try await world.note(id: original.id)
        #expect(reloaded?.title == "Edited title")
        #expect(reloaded?.body == "Edited body")
    }

    /// Regenerating something that is gone is an error, not a silently created second note.
    @Test func regeneratingAMissingNoteThrows() async {
        await #expect(throws: (any Error).self) {
            _ = try await MockWorld.shared.regenerate(noteId: "no-such-note")
        }
    }

    // MARK: - Export reports the real file count

    /// A conversation that survived reconnects is several segments, so it is several WAV files.
    /// The screen used to say "1 file exported" for all of them, and the user went to Files
    /// looking for one.
    @Test func exportReportsOneFilePerMemberSegment() async throws {
        let world = MockWorld.shared
        let display = try #require(try await world.display(id: "planning-work"))
        let members = Set(
            display.transcript.compactMap { item -> String? in
                guard case .turn(let turn) = item else { return nil }
                return turn.segmentId
            })

        let written = try await world.exportAudio(id: "planning-work")

        #expect(members.count > 1, "the fixture conversation spans more than one segment")
        #expect(written == members.count, "the count has to be counted, not assumed")
    }

    @Test func exportNeverReportsZeroForAConversationThatExists() async throws {
        #expect(try await MockWorld.shared.exportAudio(id: "coffee-dana") >= 1)
    }

    // MARK: - The watch's real name reaches the UI

    /// Someone with two Pebbles has to be able to tell from the Watch screen which one is bound,
    /// so the advertised name wins wherever there is one.
    @Test func theAdvertisedNameIsWhatTheRowShows() {
        #expect(
            LiveWatchStatusSource.label(advertisedName: "Pebble Time 2 4F21")
                == "Pebble Time 2 4F21")
    }

    /// The generic word stands for "no watch has ever been seen" — never for one that has.
    @Test func theGenericNameIsOnlyForAnUnknownWatch() {
        #expect(LiveWatchStatusSource.label(advertisedName: nil) == StatusCopy.genericDeviceName)
        #expect(LiveWatchStatusSource.label(advertisedName: "") == StatusCopy.genericDeviceName)
        #expect(LiveWatchStatusSource.label(advertisedName: "  ") == StatusCopy.genericDeviceName)
    }

    // MARK: - A queue held in the background says so

    /// `RuntimeDiagnostics.transcriptionDeferredInBackground` was computed on every refresh and
    /// read by nothing, so a queue that was simply waiting for the app to be opened looked
    /// exactly like one that was stuck.
    @Test func aHeldQueueExplainsItself() {
        let held = Copy.Settings.Diagnostics.queueValue(
            waiting: 3, failed: 0, heldInBackground: true)
        #expect(held.contains("3 waiting"))
        #expect(held.contains("held in the background"))
        #expect(held.contains("0 failed"))
    }

    @Test func aQueueThatIsSimplyWorkingSaysNothingExtra() {
        #expect(
            Copy.Settings.Diagnostics.queueValue(waiting: 3, failed: 1, heldInBackground: false)
                == "3 waiting · 1 failed")
    }

    /// Nothing waiting cannot be "held": an empty queue with a stale flag would be a lie.
    @Test func anEmptyQueueIsNeverDescribedAsHeld() {
        #expect(
            Copy.Settings.Diagnostics.queueValue(waiting: 0, failed: 0, heldInBackground: true)
                == "0 waiting · 0 failed")
    }

    /// The support report is what gets sent when something is wrong, so the reason travels
    /// with it rather than only living on screen.
    @Test func theSupportReportCarriesTheQueueLine() {
        let source = MockDiagnosticsSource()
        source.queueWaiting = 4
        source.transcriptionHeldInBackground = true
        #expect(source.supportReportText.contains("4 waiting · held in the background"))
    }

    // MARK: - Saved-note moments

    /// The footer under a saved note names the cited moments. The live path built it as `""`
    /// while `MockWorld` supplied the real line, so every real note had a blank footer.
    @Test func momentsNameTheCitedSegmentsInTimeOrder() {
        let base = Date(timeIntervalSince1970: 1_756_000_000)
        let label = LiveWorld.momentsLabel(
            [
                AskCitation(segmentId: "seg-late", number: 2),
                AskCitation(segmentId: "seg-early", number: 1),
            ],
            startedAt: { id in
                id == "seg-early" ? base : base.addingTimeInterval(900)
            })

        #expect(label.hasPrefix("2 moments · "))
        #expect(label.contains(TimeFmt.time(base)))
        #expect(label.contains(TimeFmt.time(base.addingTimeInterval(900))))
        // Time order, not citation order.
        let early = try? #require(label.range(of: TimeFmt.time(base)))
        let late = try? #require(label.range(of: TimeFmt.time(base.addingTimeInterval(900))))
        if let early, let late { #expect(early.lowerBound < late.lowerBound) }
    }

    /// Retention can take the segment a citation names. A moment we can no longer place is not
    /// one to invent a time for.
    @Test func momentsAreEmptyWhenNothingCanBePlaced() {
        #expect(LiveWorld.momentsLabel([], startedAt: { _ in nil }).isEmpty)
        #expect(
            LiveWorld.momentsLabel(
                [AskCitation(segmentId: "gone", number: 1)], startedAt: { _ in nil }
            ).isEmpty)
    }

    @Test func oneCitedMomentIsSingular() {
        let base = Date(timeIntervalSince1970: 1_756_000_000)
        let label = LiveWorld.momentsLabel(
            [
                AskCitation(segmentId: "seg", number: 1),
                AskCitation(segmentId: "seg", number: 2),
            ],
            startedAt: { _ in base })
        #expect(label.hasPrefix("1 moment · "), "the same segment cited twice is one moment")
    }
}
