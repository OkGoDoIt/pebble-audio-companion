import Foundation
import Testing

@testable import AppDB

@Suite("audio content store")
struct AudioContentStoreTests {
    private func span(
        _ segmentId: String, _ index: Int, _ start: Int64, _ end: Int64,
        _ kind: AudioContentKind, descriptor: String? = nil, words: Int = 0,
        decidedBy: String = AudioContentDecider.wordRate
    ) -> SegmentAudioContentSpan {
        SegmentAudioContentSpan(
            segmentId: segmentId, index: index, startMs: start, endMs: end,
            mediaStartMs: start - 1_000_000, mediaEndMs: end - 1_000_000, kind: kind,
            descriptor: descriptor, confidence: kind == .conversation ? 0.9 : 0.96,
            decidedBy: decidedBy, version: 1, wordCount: words)
    }

    @Test("replace swaps one segment's spans and records what they came from")
    func replaceIsPerSegment() async throws {
        let store = AudioContentStore(db: try .inMemory())
        try await store.replace(
            segmentId: "a", inputKey: "k1",
            spans: [span("a", 0, 0, 60_000, .conversation, words: 120)], atMs: 1)
        try await store.replace(
            segmentId: "b", inputKey: "k2",
            spans: [span("b", 0, 60_000, 120_000, .noConversation)], atMs: 1)
        try await store.replace(
            segmentId: "a", inputKey: "k3",
            spans: [
                span("a", 0, 0, 30_000, .conversation, words: 60),
                span("a", 1, 30_000, 60_000, .noConversation, descriptor: "fewWords", words: 1),
            ], atMs: 2)
        #expect(try await store.inputKeys() == ["a": "k3", "b": "k2"])
        #expect(try await store.spans(segmentId: "a").map(\.index) == [0, 1])
        #expect(try await store.maskingSpans().map(\.segmentId) == ["a"])
        try await store.forget(segmentIds: ["a"])
        #expect(try await store.inputKeys() == ["b": "k2"])
        #expect(try await store.spans(segmentId: "a").isEmpty)
    }

    @Test("adjacent spans that say the same thing merge across the segment seam")
    func mergesAcrossSegments() async throws {
        let store = AudioContentStore(db: try .inMemory())
        try await store.replace(
            segmentId: "a", inputKey: "k",
            spans: [
                span("a", 0, 0, 60_000, .conversation, words: 100),
                span("a", 1, 60_000, 120_000, .noConversation),
            ], atMs: 1)
        // The next segment starts 400 ms later: a seam, not information.
        try await store.replace(
            segmentId: "b", inputKey: "k",
            spans: [span("b", 0, 120_400, 300_000, .noConversation)], atMs: 1)
        let spans = try await store.spans(overlappingMs: 0..<1_000_000)
        #expect(spans.map(\.kind) == [.conversation, .noConversation])
        #expect(spans[1].startMs == 60_000 && spans[1].endMs == 300_000)
        // Clipped to the window asked for.
        let clipped = try await store.spans(overlappingMs: 30_000..<90_000)
        #expect(clipped.first?.startMs == 30_000 && clipped.last?.endMs == 90_000)
    }

    @Test("a correction relabels classified time only, and the later correction wins")
    func correctionsApplyOverClassifiedTime() {
        let stored = [
            AudioContentSpan(
                startMs: 0, endMs: 600_000, kind: .noConversation, confidence: 0.96,
                decidedBy: AudioContentDecider.wordRate, version: 1),
            // 600 000 - 900 000 is a gap: nothing stored.
            AudioContentSpan(
                startMs: 900_000, endMs: 1_200_000, kind: .noConversation, confidence: 0.96,
                decidedBy: AudioContentDecider.wordRate, version: 1),
        ]
        let overrides = [
            AudioContentOverride(id: "1", startMs: 300_000, endMs: 1_000_000, kind: .conversation, createdAtMs: 1),
            AudioContentOverride(id: "2", startMs: 950_000, endMs: 2_000_000, kind: .noConversation, createdAtMs: 2),
        ]
        let out = AudioContentStore.effectiveSpans(
            stored: stored, overrides: overrides, window: 0..<2_000_000)
        #expect(out.map(\.startMs) == [0, 300_000, 900_000, 950_000])
        #expect(out.map(\.endMs) == [300_000, 600_000, 950_000, 1_200_000])
        #expect(out.map(\.kind) == [.noConversation, .conversation, .conversation, .noConversation])
        #expect(out.map(\.decidedBy) == ["wordRate", "user", "user", "user"])
        #expect(out[1].confidence == 1 && out[1].descriptor == nil)
        // The gap stays unclassified even though a correction covers it.
        #expect(!out.contains { $0.startMs < 900_000 && $0.endMs > 600_000 })
    }

    @Test("the digest moves with any span or correction in the window and nothing outside it")
    func digestTracksTheWindow() async throws {
        let store = AudioContentStore(db: try .inMemory())
        let window: Range<Int64> = 0..<200_000
        let empty = try await store.digest(overlappingMs: window)
        try await store.replace(
            segmentId: "a", inputKey: "k",
            spans: [span("a", 0, 0, 60_000, .conversation, words: 100)], atMs: 1)
        let one = try await store.digest(overlappingMs: window)
        #expect(one != empty)
        // Rewriting the same content leaves it alone: an observer must not republish nothing.
        try await store.replace(
            segmentId: "a", inputKey: "k2",
            spans: [span("a", 0, 0, 60_000, .conversation, words: 100)], atMs: 5)
        #expect(try await store.digest(overlappingMs: window) == one)
        // A change far outside the window leaves it alone too.
        try await store.replace(
            segmentId: "z", inputKey: "k",
            spans: [span("z", 0, 9_000_000, 9_060_000, .noConversation)], atMs: 1)
        #expect(try await store.digest(overlappingMs: window) == one)
        // A verdict change inside moves it; so does a correction.
        try await store.replace(
            segmentId: "a", inputKey: "k3",
            spans: [span("a", 0, 0, 60_000, .noConversation, words: 1)], atMs: 6)
        let changed = try await store.digest(overlappingMs: window)
        #expect(changed != one)
        let correction = try await store.addOverride(
            startMs: 0, endMs: 60_000, kind: .conversation, atMs: 7)
        let corrected = try await store.digest(overlappingMs: window)
        #expect(corrected != changed)
        #expect(try await store.spans(overlappingMs: window).first?.decidedBy == "user")
        try await store.removeOverride(id: correction.id)
        #expect(try await store.digest(overlappingMs: window) == changed)
    }
}
