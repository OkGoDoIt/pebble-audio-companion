import Foundation
import Intelligence
import Testing

// AF · the sentence a person actually reads when an AI note does not finish.
//
// The reported case, end to end: Remote first, a four-hour conversation, and the dock said
// "Extended summary didn't finish — On-device AI generation failed" while remote AI was on. Two
// separate faults produced that one sentence — the router surfaced the fallback instead of the
// primary, and the dock printed the provider's own developer prose — so the sentence is pinned
// here from the error shape the router now throws.

/// `@MainActor` because `NoteJobCenter` is: `reason(for:)` is a static on a main-actor type.
@Suite("AF · AI failure copy") @MainActor
struct AFAiFailureCopyTests {
    /// The reported sentence, rebuilt from the error the router now produces. The headline is
    /// the cloud cause; the on-device fallback is one trailing clause.
    @Test func theCloudCauseLeadsAndTheFallbackTrails() {
        let error = AiError.providerFailed(
            "OpenAI responses request failed (401): incorrect api key provided",
            underlying: AiFallbackFailure(
                origin: .onDevice,
                providerId: "apple-foundation-models",
                error: AiError.providerFailed(
                    "This recording is too long for on-device AI. It would fit about 4875 of its "
                        + "157703 characters.")
            ))

        let reason = NoteJobCenter.reason(for: error)

        #expect(reason.hasPrefix(Copy.AiFailure.keyRejected))
        #expect(reason.contains(Copy.AiFailure.alsoTriedOnDevice))
        // The thing the user actually complained about: not a word about the on-device model
        // until after the cause they can act on, and no raw API body anywhere (B20 — a 401 body
        // carries the request and a partly-redacted key).
        #expect(!reason.contains("incorrect api key provided"))
        #expect(!reason.contains("401"))
    }

    /// The mirror image: On-device first, so the on-device cause leads.
    @Test func theOnDeviceCauseLeadsWhenThatIsWhatWasChosen() {
        let error = AiError.providerFailed(
            "This recording is too long for on-device AI. It would fit about 4875 characters.",
            underlying: AiFallbackFailure(
                origin: .cloud,
                providerId: "openai-chat",
                error: AiError.providerFailed("OpenAI responses request failed (429): slow down")
            ))

        let reason = NoteJobCenter.reason(for: error)

        #expect(reason.hasPrefix(Copy.AiFailure.tooLongForDevice))
        #expect(reason.contains(Copy.AiFailure.alsoTriedCloud))
    }

    /// One provider, one sentence. No trailing clause invented where nothing else was tried.
    @Test func aSingleProviderFailureHasNoFallbackClause() {
        let reason = NoteJobCenter.reason(
            for: AiError.providerFailed("OpenAI responses request failed (429): slow down"))
        #expect(reason == Copy.AiFailure.rateLimited)
    }

    /// Every kind has words, and no two say the same thing — a taxonomy that collapses to one
    /// sentence is the generic message with extra steps.
    @Test func everyKindHasItsOwnSentence() {
        let sentences = AiFailureKind.allCases.map(\.reason)
        #expect(sentences.allSatisfy { !$0.isEmpty })
        #expect(Set(sentences).count == AiFailureKind.allCases.count)
    }

    /// Apple Private Cloud Compute's allowance: named as Apple's, never as OpenAI's, and it says
    /// the on-device model is unaffected — the two things a person would otherwise wonder.
    @Test func aUsedUpAllowanceIsToldAsApples() {
        let reason = NoteJobCenter.reason(
            for: AiError.providerFailed(
                "Apple Private Cloud Compute has reached its daily usage limit."))
        #expect(reason == Copy.AiFailure.usageLimit)
        #expect(reason.contains("Apple Private Cloud Compute"))
        #expect(!reason.contains("OpenAI"))
        #expect(!reason.contains("funds"))
    }

    /// A cloud refusal does not borrow the on-device sentence.
    @Test func aCloudRefusalIsNotToldAsTheOnDeviceOne() {
        let reason = NoteJobCenter.reason(
            for: AiError.providerFailed(
                "Apple Private Cloud Compute declined to work on this request."))
        #expect(reason == Copy.AiFailure.cloudContentRefused)
        #expect(!reason.lowercased().contains("on-device"))
    }

    /// The one a person is most likely to hit on a long recording has to name both ways out.
    @Test func theTooLongSentenceNamesWhatToDo() {
        #expect(Copy.AiFailure.tooLongForDevice.contains("cloud AI"))
        #expect(Copy.AiFailure.tooLongForDevice.contains("shorter note"))
    }

    /// A failure that is genuinely not an AI failure keeps its own words. Notes on a
    /// conversation with nothing transcribed yet reach here, and telling that person to check
    /// their AI settings would send them somewhere nothing is wrong.
    @Test func aMissingTranscriptIsNotAnAiFailure() {
        #expect(
            NoteJobCenter.reason(for: CocoaError(.fileNoSuchFile))
                == Copy.NoteJobs.nothingToWorkFrom)
    }
}
