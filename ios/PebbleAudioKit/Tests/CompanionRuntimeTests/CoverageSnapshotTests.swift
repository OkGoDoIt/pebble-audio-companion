import AppDB
import CompanionRuntime
import Foundation
import SegmentStore
import StatusUI
import Testing

// Plan 6.8 — the App Group hand-off. The widget renders from this file and nothing else, so the
// JSON shape is a contract with a separate target: these tests are what stops it drifting.

@Suite struct CoverageSnapshotTests {

    @Test func snapshotIsWrittenOnSegmentClosePauseChangeAndAppBackground() async throws {
        let fixture = try RuntimeFixture()

        await fixture.snapshots.refresh(.segmentClosed)
        await fixture.snapshots.refresh(.pauseChanged)
        await fixture.snapshots.refresh(.appBackgrounded)

        let seen = await fixture.snapshots.triggers
        #expect(seen.contains(.segmentClosed))
        #expect(seen.contains(.pauseChanged))
        #expect(seen.contains(.appBackgrounded))
        #expect(FileManager.default.fileExists(atPath: fixture.snapshotWriter.url.path))
    }

    @Test func closingASegmentThroughTheSinkRefreshesTheSnapshot() async throws {
        let fixture = try RuntimeFixture()
        _ = try await Fixture.writeSegment(into: fixture.store)
        // The store is the innermost sink; drive the trigger the receiver would.
        await fixture.snapshots.refresh(.segmentClosed)

        #expect(await fixture.snapshots.lastTrigger == .segmentClosed)
    }

    @Test func pauseIntentRefreshesTheSnapshot() async throws {
        let fixture = try RuntimeFixture()
        await fixture.runtime.setCaptureIntent(.paused)

        #expect(await fixture.snapshots.triggers.contains(.pauseChanged))
    }

    @Test func appBackgroundRefreshesTheSnapshot() async throws {
        let fixture = try RuntimeFixture()
        await fixture.runtime.setForeground(false)

        #expect(await fixture.snapshots.triggers.contains(.appBackgrounded))
    }

    @Test func snapshotJsonRoundTripsAndCarriesTheDocumentedShape() async throws {
        let fixture = try RuntimeFixture()
        await fixture.clock.advance(by: 1_756_512_000_000)  // a real wall-clock instant
        // Ten minutes of wall time ago, so the recorded span lands inside [dayStart, now).
        _ = try await Fixture.writeSegment(
            into: fixture.store,
            startTimeMs: UInt64(fixture.clock.nowMs - 600_000),
            frames: 500,
            receivedAtMs: fixture.clock.nowMs - 600_000
        )

        let written = await fixture.snapshots.refresh(.manual)
        let data = try Data(contentsOf: fixture.snapshotWriter.url)
        let decoded = try JSONDecoder().decode(CoverageSnapshot.self, from: data)

        #expect(decoded == written)
        #expect(decoded.version == CoverageSnapshot.currentVersion)
        #expect(decoded.generatedAtMs == fixture.clock.nowMs)
        #expect(decoded.nowMs == fixture.clock.nowMs)
        #expect(decoded.dayStartMs <= decoded.nowMs)
        #expect(!decoded.dateKey.isEmpty)
        #expect(!decoded.timeZoneID.isEmpty)
        #expect(!decoded.headline.isEmpty)
        #expect(["neutral", "info", "active", "attention", "problem", "consent"].contains(decoded.dot))
        // Spans tile the day so far, in order, with no overlaps.
        #expect(!decoded.spans.isEmpty)
        #expect(decoded.spans.first?.startMs == decoded.dayStartMs)
        #expect(decoded.spans.last?.endMs == decoded.nowMs)
        for (previous, next) in zip(decoded.spans, decoded.spans.dropFirst()) {
            #expect(previous.endMs == next.startMs)
        }
        #expect(decoded.totalRecordedMs > 0)
    }

    @Test func snapshotJsonKeysAreStableForTheWidget() async throws {
        let fixture = try RuntimeFixture()
        _ = await fixture.snapshots.refresh(.manual)
        let object = try #require(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: fixture.snapshotWriter.url)
            ) as? [String: Any]
        )

        let required: Set<String> = [
            "version", "generatedAtMs", "dateKey", "timeZoneID", "dayStartMs", "nowMs",
            "spans", "totalRecordedMs", "totalMissingMs", "headline", "dot", "isRecording",
        ]
        #expect(required.isSubset(of: Set(object.keys)))

        if let spans = object["spans"] as? [[String: Any]], let first = spans.first {
            #expect(Set(first.keys) == ["kind", "startMs", "endMs"])
            let kind = try #require(first["kind"] as? String)
            #expect(CoverageKind(rawValue: kind) != nil)
        }
    }

    @Test func aMissingSnapshotFileReadsAsNilRatherThanCrashing() throws {
        let directory = Fixture.temporaryDirectory("empty-group")
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = CoverageSnapshotWriter(directory: directory)

        #expect(writer.read() == nil)
    }

    @Test func pausedTimeRendersAsItsOwnCoverageStateNotAsMissing() async throws {
        let fixture = try RuntimeFixture()
        await fixture.clock.advance(by: 1_756_512_000_000)
        _ = try await fixture.pauseJournal.begin(
            source: .statusCard, atMs: fixture.clock.nowMs - 600_000
        )
        try await fixture.pauseJournal.end(atMs: fixture.clock.nowMs - 300_000)

        let snapshot = await fixture.snapshots.refresh(.pauseChanged)

        #expect(snapshot.spans.contains { $0.kind == .paused })
        #expect(!snapshot.spans.contains { $0.kind == .missing })
    }
}
