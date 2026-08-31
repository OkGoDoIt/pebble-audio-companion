import Foundation
import Testing

@testable import Transcription

// Every literal below is a message the kit ACTUALLY throws and the queue actually stores, so
// this suite is the contract between the failure paths and the sentence Diagnostics shows. If a
// provider gains a new failure message, it belongs here with the kind it should read as.

@Suite struct TranscriptionFailureKindTests {
    @Test func sonioxFailurePathsEachGetTheirOwnKind() {
        #expect(
            TranscriptionFailureKind.classify("Soniox upload returned no file id")
                == .providerRefusedAudio
        )
        #expect(
            TranscriptionFailureKind.classify("Soniox create returned no id")
                == .providerRefusedAudio
        )
        #expect(TranscriptionFailureKind.classify("Soniox transcription timed out") == .timedOut)
        #expect(
            TranscriptionFailureKind.classify(
                "segment audio exceeds 104857600 byte Soniox upload limit"
            ) == .recordingTooLong
        )
        #expect(
            TranscriptionFailureKind.classify("Soniox transcription error: internal")
                == .providerTrouble
        )
    }

    /// The HTTP-status forms, which carry the provider's own body — the copy for these must come
    /// from the status, never from the body.
    @Test func httpStatusesMapOntoTheSameAdviceAsAKeyCheck() {
        #expect(
            TranscriptionFailureKind.classify("Soniox upload failed (401): {\"error\":\"bad key\"}")
                == .keyRejected
        )
        #expect(
            TranscriptionFailureKind.classify("Soniox poll failed (403): nope") == .keyNotPermitted
        )
        #expect(
            TranscriptionFailureKind.classify("OpenAI transcription failed (429): slow down")
                == .rateLimited
        )
        #expect(
            TranscriptionFailureKind.classify("Soniox create failed (503): unavailable")
                == .providerTrouble
        )
        #expect(
            TranscriptionFailureKind.classify("OpenAI transcription failed (413): too big")
                == .recordingTooLong
        )
    }

    /// A byte count in the message is not a status, and neither is a number the provider's own
    /// body happens to contain first.
    @Test func onlyABareParenthesisedStatusCounts() {
        #expect(TranscriptionFailureKind.httpStatus(in: "WAV upload chunk 999 exceeds 5 byte") == nil)
        #expect(TranscriptionFailureKind.httpStatus(in: "failed (4011): x") == nil)
        #expect(TranscriptionFailureKind.httpStatus(in: "failed (abc): x") == nil)
        #expect(TranscriptionFailureKind.httpStatus(in: "failed (500): x") == 500)
        // Not a status: outside the HTTP range.
        #expect(TranscriptionFailureKind.httpStatus(in: "took (900) ms") == nil)
    }

    @Test func localEngineFailuresAreSeparableFromCloudOnes() {
        #expect(
            TranscriptionFailureKind.classify("failed to initialize local model: no such file")
                == .modelMissing
        )
        #expect(
            TranscriptionFailureKind.classify("local transcription failed: cactus_stop")
                == .localEngineFailed
        )
        #expect(
            TranscriptionFailureKind.classify("On-device transcription failed")
                == .localEngineFailed
        )
        #expect(TranscriptionFailureKind.classify("failed to stage local audio") == .audioUnreadable)
        #expect(
            TranscriptionFailureKind.classify("missing metadata for segment seg-1")
                == .audioUnreadable
        )
    }

    @Test func nothingUsableAtAllReadsAsUnconfigured() {
        #expect(TranscriptionFailureKind.classify("provider unavailable: soniox") == .notConfigured)
        // Even when the line also carries a status, "nothing was usable" is the truer answer.
        #expect(
            TranscriptionFailureKind.classify("provider unavailable: soniox (401)") == .notConfigured
        )
    }

    /// `storedFailureMessage` keeps the numeric URLError code precisely so classification does
    /// not depend on the phone's language.
    @Test func networkErrorsCarryTheirCodeIntoTheStoredMessage() {
        let offline = storedFailureMessage(URLError(.notConnectedToInternet))
        #expect(offline.hasPrefix("network request failed (-1009)"))
        #expect(TranscriptionFailureKind.classify(offline) == .noConnection)

        let slow = storedFailureMessage(URLError(.timedOut))
        #expect(TranscriptionFailureKind.classify(slow) == .timedOut)

        // Rows written before the marker existed still classify off the English wording.
        #expect(
            TranscriptionFailureKind.classify("The Internet connection appears to be offline.")
                == .noConnection
        )
    }

    @Test func anythingUnrecognisedIsUnknownRatherThanAGuess() {
        #expect(TranscriptionFailureKind.classify(nil) == .unknown)
        #expect(TranscriptionFailureKind.classify("") == .unknown)
        #expect(TranscriptionFailureKind.classify("   ") == .unknown)
        #expect(TranscriptionFailureKind.classify("AssertionError") == .unknown)
    }

    @Test func aTaskClassifiesItsOwnStoredError() {
        let task = TranscriptionTask(
            segmentId: "seg-1",
            state: .failed,
            lastError: "Soniox poll failed (401): {\"key\":\"sk-live-abcd\"}",
            createdAtMs: 0,
            updatedAtMs: 0
        )
        #expect(task.failureKind == .keyRejected)
    }

    /// A non-`TranscriptionError` still stores something, and it is never nothing.
    @Test func storedMessagesAreNeverEmpty() {
        struct Boom: Error {}
        #expect(storedFailureMessage(Boom()) == "Boom")
        #expect(
            storedFailureMessage(TranscriptionError.transcriptionFailed("Soniox create returned no id"))
                == "Soniox create returned no id"
        )
    }
}
