import Foundation
import Intelligence
import Testing
import Transcription

// The sentence Storage & Privacy shows when a "first" mode is being carried by its fallback.
//
// The stance card's whole contract is that it never states a promise the pipeline is not
// keeping (`Copy+PrivacyStance.swift`). Its Local-first qualifier is a conditional — a recording
// is uploaded "only when the on-device engine cannot finish it" — and this is the present-tense
// line that completes it. That makes the derivation load-bearing in both directions: a missing
// line is a silent upload, and a spurious one is a false alarm on a privacy screen.
//
// Every case is pinned from plain values: two `ProcessingFallback`s and two destination names.

@Suite("CU · processing fallback disclosure")
struct CUProcessingFallbackDisclosureTests {

    private func notices(
        transcription: ProcessingFallback? = nil,
        ai: ProcessingFallback? = nil,
        stt: String? = "Soniox",
        remoteAi: String? = "OpenAI"
    ) -> [Copy.Privacy.FallbackNotice] {
        Copy.Privacy.fallbackNotices(
            transcription: transcription, ai: ai,
            cloudTranscriptionDestination: stt, remoteAiDestination: remoteAi)
    }

    // MARK: - Silence is the normal case

    /// Nothing falling back means nothing said. This is the state the app is in almost always,
    /// and a card that carried a line here would be the nagging banner this deliberately is not.
    @Test func nothingIsSaidWhenBothPathsAreWorking() {
        #expect(notices().isEmpty)
    }

    // MARK: - Both axes are covered

    @Test func bothAxesCanSpeakAtOnce() {
        let both = notices(
            transcription: ProcessingFallback(direction: .localToCloud, cause: .notAvailable),
            ai: ProcessingFallback(direction: .localToCloud, cause: .notAvailable))
        #expect(both.count == 2)
        #expect(both.map(\.id) == ["transcription", "ai"])
    }

    // MARK: - Local first → the cloud: the privacy statement

    /// The measured real case. The line has to name the destination, say it is happening NOW,
    /// and give the reason — all in one sentence.
    @Test func localToCloudNamesTheDestinationAndTheReason() throws {
        let notice = try #require(
            notices(
                transcription: ProcessingFallback(
                    direction: .localToCloud, cause: .notAvailable)
            ).first)
        #expect(notice.text.contains("Soniox"))
        #expect(notice.text.contains("right now"))
        #expect(notice.text.contains("not available on this iPhone"))
    }

    /// "Not available" and "could not finish it" are different facts about the phone and lead to
    /// different actions (install the model vs. look at Diagnostics), so they must not collapse.
    @Test func theTwoLocalCausesReadDifferently() throws {
        let unavailable = try #require(
            notices(
                transcription: ProcessingFallback(
                    direction: .localToCloud, cause: .notAvailable)
            ).first)
        let failed = try #require(
            notices(
                transcription: ProcessingFallback(direction: .localToCloud, cause: .failed)
            ).first)
        #expect(unavailable.text != failed.text)
        #expect(failed.text.contains("could not finish"))
    }

    /// Transcription sends recordings; AI sends text. The stance card is precise about that
    /// distinction everywhere else, and this line must not blur it.
    @Test func audioAndTextAreNamedSeparately() throws {
        let stt = try #require(
            notices(
                transcription: ProcessingFallback(direction: .localToCloud, cause: .failed)
            ).first)
        let ai = try #require(
            notices(ai: ProcessingFallback(direction: .localToCloud, cause: .failed)).first)
        #expect(stt.text.hasPrefix("Recordings are going to"))
        #expect(ai.text.hasPrefix("Text is going to"))
    }

    // MARK: - Remote first → this phone: the quality statement

    @Test func cloudToLocalSaysWhereTheWorkMovedAndWhy() throws {
        let notice = try #require(
            notices(
                transcription: ProcessingFallback(
                    direction: .cloudToLocal, cause: .noConnection)
            ).first)
        #expect(notice.text.contains("on this iPhone"))
        #expect(notice.text.contains("could not reach"))
    }

    /// A rejected key is the one cloud cause with something to do about it, so the sentence says
    /// what to do — the only place in this copy that asks anything of the reader.
    @Test func aRejectedKeyIsActionable() throws {
        let notice = try #require(
            notices(
                transcription: ProcessingFallback(
                    direction: .cloudToLocal, cause: .notAccepted)
            ).first)
        #expect(notice.text.contains("turned the last request down"))
        #expect(notice.text.contains("key"))
    }

    // MARK: - The stale-record rule

    /// A fallback recorded before the mode was changed to Local only must not print. The
    /// destination is nil in that configuration, and a sentence naming a provider that this
    /// configuration cannot reach would be a new false statement on the privacy screen — worse
    /// than the silence it replaced.
    @Test func aFallbackWithNoDestinationSaysNothing() {
        #expect(
            notices(
                transcription: ProcessingFallback(
                    direction: .localToCloud, cause: .notAvailable),
                stt: nil
            ).isEmpty)
        #expect(
            notices(
                transcription: ProcessingFallback(
                    direction: .cloudToLocal, cause: .failed),
                stt: nil
            ).isEmpty)
        #expect(
            notices(
                ai: ProcessingFallback(direction: .localToCloud, cause: .failed),
                remoteAi: nil
            ).isEmpty)
    }

    /// One axis falling back never silences the other's destination check.
    @Test func theTwoAxesAreDerivedIndependently() throws {
        let only = notices(
            transcription: ProcessingFallback(direction: .localToCloud, cause: .failed),
            ai: ProcessingFallback(direction: .localToCloud, cause: .failed),
            remoteAi: nil)
        #expect(only.map(\.id) == ["transcription"])
    }

    // MARK: - Apple Private Cloud Compute's allowance

    /// A used-up allowance is a quality event told plainly: no key to check, and it says the
    /// limit resets rather than sending the person to an account page.
    @Test func aUsedUpAllowanceSaysItComesBack() throws {
        let only = notices(
            ai: ProcessingFallback(direction: .cloudToLocal, cause: .usageLimit),
            remoteAi: Copy.Privacy.applePrivateCloud)
        let text = try #require(only.first?.text)
        #expect(text.hasPrefix("AI is running on this iPhone right now"))
        #expect(text.contains("allowance"))
        #expect(!text.contains("key"))
    }

    // MARK: - Every combination produces a sentence, not an empty string

    @Test func everyReachableCombinationHasWords() {
        for direction in ProcessingFallbackDirection.allCases {
            for cause in ProcessingFallbackCause.allCases {
                let fallback = ProcessingFallback(direction: direction, cause: cause)
                for notice in notices(transcription: fallback, ai: fallback) {
                    #expect(notice.text.count > 20, "\(direction)/\(cause): \(notice.text)")
                    #expect(notice.text.hasSuffix("."), "\(direction)/\(cause): \(notice.text)")
                }
            }
        }
    }
}
