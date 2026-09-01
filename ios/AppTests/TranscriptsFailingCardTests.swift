import Foundation
import StatusUI
import Testing

/// The precedence rule for "Transcripts are behind": it may replace the calm card, and nothing
/// else.
///
/// The failure mode this guards against is the one that would make the status card worthless —
/// a transcription problem hiding a capture problem. Recording is what this product promises;
/// transcripts are what it does with the result. If both are wrong, the card says the one the
/// person can act on.
@Suite("transcripts-failing precedence") @MainActor
struct TranscriptsFailingCardTests {

    private func card(_ family: StatusFamily) -> StatusModel {
        StatusModel(family: family, headline: "h", detail: "d", dot: .neutral, action: nil)
    }

    private func applied(_ family: StatusFamily, failing: Bool) -> StatusModel {
        LiveTodayDataSource.applyingTranscriptionHealth(
            to: card(family), transcriptionFailing: failing
        )
    }

    @Test func healthyTranscriptionChangesNothing() {
        for family in Self.allFamilies {
            #expect(applied(family, failing: false).family == family)
        }
    }

    @Test func aCalmRecordingCardGivesWayToIt() {
        #expect(applied(.recording, failing: true).family == .transcriptsFailing)
        #expect(applied(.recording, failing: true) == .transcriptsFailing)
    }

    /// Every other family is about capture itself and is both more urgent and more actionable.
    @Test func everyCaptureStateWins() {
        for family in Self.allFamilies where family != .recording {
            #expect(
                applied(family, failing: true).family == family,
                "\(family) must not be replaced by the transcripts-failing card"
            )
        }
    }

    /// The card's words live twice — in the kit, which renders the card, and in `Copy`, which
    /// the widget extension compiles and which cannot link the kit. Two copies of a sentence
    /// drift; this is the only place that can notice.
    @Test func theTwoCopiesOfTheCopyAgree() {
        #expect(Copy.Status.transcriptsFailing == StatusCopy.transcriptsFailing)
        #expect(Copy.Status.transcriptsFailingLine == StatusCopy.transcriptsFailingLine)
        #expect(Copy.Status.seeDetails == StatusCopy.seeDetails)
    }

    private static let allFamilies: [StatusFamily] = [
        .recording, .paused, .reconnecting, .connecting, .bluetoothOff,
        .notRecording, .confirmOnWatch, .transcriptsOff, .needsAttention,
    ]
}
