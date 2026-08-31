import XCTest

/// The snapshot is a wire contract between two processes that ship together but run apart.
/// These tests pin the JSON keys, the tolerant decode, and the fraction math the strip uses.
final class CoverageSnapshotTests: XCTestCase {
    private func sample() -> CoverageSnapshot {
        CoverageSnapshot(
            generatedAtMs: 1_756_512_000_000,
            dateKey: "2026-08-30",
            timeZoneID: "America/Los_Angeles",
            dayStartMs: 1_756_472_400_000,
            nowMs: 1_756_512_000_000,
            spans: [
                .init(kind: .recorded, startMs: 1_756_472_400_000, endMs: 1_756_476_000_000),
                .init(kind: .quiet, startMs: 1_756_476_000_000, endMs: 1_756_477_800_000),
                .init(kind: .missing, startMs: 1_756_477_800_000, endMs: 1_756_477_860_000),
                .init(kind: .paused, startMs: 1_756_477_860_000, endMs: 1_756_479_660_000),
            ],
            totalRecordedMs: 3_600_000,
            totalMissingMs: 60_000,
            headline: "Recording",
            detail: "Pebble Time 2 · connected",
            dot: "active",
            isRecording: true
        )
    }

    func testRoundTripsThroughJSON() throws {
        let original = sample()
        let data = try JSONEncoder().encode(original)
        let decoded = try XCTUnwrap(CoverageSnapshot.load(from: data))
        XCTAssertEqual(decoded, original)
    }

    func testDecodesTheWriterKeysVerbatim() throws {
        // Field-for-field with `CompanionRuntime.CoverageSnapshot`'s documented v1 contract.
        let json = """
            {
              "version": 1,
              "generatedAtMs": 1756512000000,
              "dateKey": "2026-08-30",
              "timeZoneID": "America/Los_Angeles",
              "dayStartMs": 1756472400000,
              "nowMs": 1756512000000,
              "spans": [{ "kind": "recorded", "startMs": 1756472400000, "endMs": 1756476000000 }],
              "totalRecordedMs": 3600000,
              "totalMissingMs": 0,
              "headline": "Recording",
              "detail": "Pebble Time 2 · connected",
              "dot": "active",
              "isRecording": true
            }
            """
        let snapshot = try XCTUnwrap(CoverageSnapshot.load(from: Data(json.utf8)))
        XCTAssertEqual(snapshot.version, 1)
        XCTAssertEqual(snapshot.dateKey, "2026-08-30")
        XCTAssertEqual(snapshot.timeZoneID, "America/Los_Angeles")
        XCTAssertEqual(snapshot.spans.count, 1)
        XCTAssertEqual(snapshot.spans[0].kind, .recorded)
        XCTAssertEqual(snapshot.spans[0].durationMs, 3_600_000)
        XCTAssertEqual(snapshot.headline, "Recording")
        XCTAssertEqual(snapshot.dot, "active")
        XCTAssertTrue(snapshot.isRecording)
    }

    func testMissingFieldsAndUnknownKindsDegradeInsteadOfFailing() throws {
        // A newer writer adds a field and a kind; an older widget must still render.
        let json = """
            { "version": 2, "dayStartMs": 0, "nowMs": 1000, "futureField": "x",
              "spans": [{ "kind": "hibernating", "startMs": 0, "endMs": 1000 }] }
            """
        let snapshot = try XCTUnwrap(CoverageSnapshot.load(from: Data(json.utf8)))
        XCTAssertEqual(snapshot.spans[0].kind, .off, "unknown kinds draw nothing, never loss")
        XCTAssertEqual(snapshot.headline, "")
        XCTAssertEqual(snapshot.dot, "neutral")
        XCTAssertFalse(snapshot.isRecording)
        XCTAssertTrue(snapshot.isEmptyDay)
    }

    func testMalformedJSONReturnsNil() {
        XCTAssertNil(CoverageSnapshot.load(from: Data("not json".utf8)))
        XCTAssertNil(CoverageSnapshot.load(from: Data()))
    }

    func testLoadsFromAFileURL() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("coverage-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try JSONEncoder().encode(sample()).write(to: url)
        XCTAssertEqual(CoverageSnapshot.load(from: url), sample())
        XCTAssertNil(
            CoverageSnapshot.load(from: url.appendingPathExtension("missing")),
            "a missing file is 'no data yet', not a crash"
        )
    }

    func testFractionRangeMapsTheLogicalDayOntoTheStrip() throws {
        let snapshot = sample()
        // First span: 5 AM → 6 AM of a 24 h day = 0 … 1/24.
        let first = try XCTUnwrap(snapshot.fractionRange(of: snapshot.spans[0]))
        XCTAssertEqual(first.lowerBound, 0, accuracy: 0.0001)
        XCTAssertEqual(first.upperBound, 1.0 / 24.0, accuracy: 0.0001)

        // A one-minute loss is a real, non-zero slice — never rounded away.
        let loss = try XCTUnwrap(snapshot.fractionRange(of: snapshot.spans[2]))
        XCTAssertGreaterThan(loss.upperBound - loss.lowerBound, 0)
    }

    func testFractionRangeClampsOutOfDaySpansAndDropsEmptyOnes() {
        let snapshot = sample()
        let before = CoverageSnapshot.Span(
            kind: .recorded, startMs: snapshot.dayStartMs - 5_000, endMs: snapshot.dayStartMs
        )
        XCTAssertNil(snapshot.fractionRange(of: before), "zero-width after clamping = not drawn")

        let straddling = CoverageSnapshot.Span(
            kind: .recorded, startMs: snapshot.dayStartMs - 5_000,
            endMs: snapshot.dayStartMs + 3_600_000
        )
        let range = snapshot.fractionRange(of: straddling)
        XCTAssertEqual(range?.lowerBound, 0)
    }
}
