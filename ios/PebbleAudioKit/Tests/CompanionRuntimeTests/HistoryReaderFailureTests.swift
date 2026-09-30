import Testing
import Transcription

@testable import CompanionRuntime

// B20: the queue's stored error is developer prose with the provider's response body in it —
// sometimes the request URL, sometimes the key. History carries only the classified kind.
@Suite struct HistoryReaderFailureTests {
    @Test("a failed recording's reason is its classified kind, never the stored text")
    func reasonIsAKind() {
        let stored = "Soniox transcription error: Organization balance exhausted. Please either add funds manually or enable autopay. key=sk-live-abc123"
        let reason = HistoryReader.failureKind(stored)
        #expect(reason == TranscriptionFailureKind.classify(stored).rawValue)
        #expect(reason.map { TranscriptionFailureKind(rawValue: $0) != nil } == true)
        #expect(reason?.contains("sk-live") != true)
        #expect(HistoryReader.failureKind("something nobody can name") == nil)
        #expect(HistoryReader.failureKind(nil) == nil)
    }
}
