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

/// v2 (2026-08-31). The widget set grew from one coverage strip to status/now/follow-ups, so the
/// snapshot carries the live state too. The rule that matters most here is the OLD-FILE one: a
/// v1 snapshot written by an app that has not been updated yet must decode into something the
/// new widgets render honestly — "unknown", never a confident-looking zero.
final class CoverageSnapshotV2Tests: XCTestCase {
    private func sample() -> CoverageSnapshot {
        CoverageSnapshot(
            generatedAtMs: 1_756_512_000_000,
            dateKey: "2026-08-30",
            timeZoneID: "America/Los_Angeles",
            dayStartMs: 1_756_472_400_000,
            nowMs: 1_756_512_000_000,
            spans: [.init(kind: .recorded, startMs: 1_756_472_400_000, endMs: 1_756_476_000_000)],
            totalRecordedMs: 3_600_000,
            totalMissingMs: 0,
            headline: "Recording",
            detail: "Pebble Time 2 · connected",
            dot: "active",
            isRecording: true,
            state: .recording,
            currentStartedAtMs: 1_756_510_800_000,
            liveTitle: "Standup",
            liveLine: "Push the release to Thursday",
            activity: [
                .init(kind: .recorded, level: 0.9),
                .init(kind: .quiet, level: 0),
                .init(kind: .missing, level: 0.2),
            ],
            activityWindowMs: 600_000,
            followUps: [
                .init(id: "f1", text: "Email Dana", conversationId: "c1"),
                .init(id: "f2", text: "Order tiles", conversationId: nil),
            ],
            openFollowUpCount: 5
        )
    }

    func testRoundTripsEveryV2Field() throws {
        let original = sample()
        let data = try JSONEncoder().encode(original)
        let decoded = try XCTUnwrap(CoverageSnapshot.load(from: data))
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.version, 2)
        XCTAssertEqual(decoded.state, .recording)
        XCTAssertEqual(decoded.followUps.first?.conversationId, "c1")
        XCTAssertNil(decoded.followUps.last?.conversationId)
    }

    func testDecodesTheWriterKeysVerbatim() throws {
        // Field-for-field with `CompanionRuntime.CoverageSnapshot`'s documented v2 contract.
        let json = """
            {
              "version": 2,
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
              "isRecording": true,
              "state": "recording",
              "currentStartedAtMs": 1756510800000,
              "liveTitle": "Standup",
              "liveLine": "Push the release to Thursday",
              "activity": [{ "kind": "recorded", "level": 0.9 }],
              "activityWindowMs": 600000,
              "followUps": [{ "id": "f1", "text": "Email Dana", "conversationId": "c1" }],
              "openFollowUpCount": 5
            }
            """
        let decoded = try XCTUnwrap(CoverageSnapshot.load(from: Data(json.utf8)))

        XCTAssertEqual(decoded.state, .recording)
        XCTAssertEqual(decoded.currentStartedAtMs, 1_756_510_800_000)
        XCTAssertEqual(decoded.liveTitle, "Standup")
        XCTAssertEqual(decoded.liveLine, "Push the release to Thursday")
        XCTAssertEqual(decoded.activity, [.init(kind: .recorded, level: 0.9)])
        XCTAssertEqual(decoded.activityWindowMs, 600_000)
        XCTAssertEqual(decoded.followUps.count, 1)
        XCTAssertEqual(decoded.openFollowUpCount, 5)
    }

    /// The compatibility case this version bump exists for.
    func testAV1FileDecodesWithTheNewFieldsAbsentRatherThanWrong() throws {
        let json = """
            {
              "version": 1,
              "generatedAtMs": 1756512000000,
              "dateKey": "2026-08-30",
              "timeZoneID": "America/Los_Angeles",
              "dayStartMs": 1756472400000,
              "nowMs": 1756512000000,
              "spans": [],
              "totalRecordedMs": 0,
              "totalMissingMs": 0,
              "headline": "Recording",
              "dot": "active",
              "isRecording": true
            }
            """
        let decoded = try XCTUnwrap(CoverageSnapshot.load(from: Data(json.utf8)))

        XCTAssertEqual(decoded.version, 1)
        XCTAssertFalse(decoded.hasLiveDetail, "a v1 file must announce that it cannot say more")
        // `isRecording` is the only live fact v1 carries, so `state` is derived from it rather
        // than invented — claiming `.notRecording` would be a lie in the dangerous direction.
        XCTAssertEqual(decoded.state, .recording)
        XCTAssertNil(decoded.currentStartedAtMs, "no timer without a start the file knows")
        XCTAssertNil(decoded.liveTitle)
        XCTAssertNil(decoded.liveLine)
        XCTAssertEqual(decoded.activity, [])
        XCTAssertEqual(decoded.followUps, [])
        XCTAssertEqual(decoded.openFollowUpCount, 0)
    }

    func testAV1FileThatWasNotRecordingDecodesAsUnknownNotAsPaused() throws {
        let json = """
            { "version": 1, "headline": "Paused", "dot": "attention", "isRecording": false }
            """
        let decoded = try XCTUnwrap(CoverageSnapshot.load(from: Data(json.utf8)))

        XCTAssertEqual(decoded.state, .unknown)
        // The prose headline is still the approved vocabulary, so the widget has something true
        // to show even though the machine-readable state is unavailable.
        XCTAssertEqual(decoded.headline, "Paused")
    }

    func testAnUnknownFutureStateDecodesAsUnknownRatherThanFailing() throws {
        let json = """
            { "version": 3, "state": "levitating", "headline": "Hovering", "dot": "sparkly" }
            """
        let decoded = try XCTUnwrap(CoverageSnapshot.load(from: Data(json.utf8)))

        XCTAssertEqual(decoded.state, .unknown)
        XCTAssertEqual(decoded.headline, "Hovering")
    }

    func testActivityLevelsAreClampedOnTheWayIn() throws {
        let json = """
            { "activity": [{ "kind": "recorded", "level": 4.5 },
                           { "kind": "wormhole", "level": -2 }] }
            """
        let decoded = try XCTUnwrap(CoverageSnapshot.load(from: Data(json.utf8)))

        XCTAssertEqual(decoded.activity[0].level, 1)
        XCTAssertEqual(decoded.activity[1].level, 0)
        XCTAssertEqual(decoded.activity[1].kind, .off, "an unknown kind draws as nothing")
    }

    func testStalenessIsMeasuredFromTheWriteTimeAndNeverNegative() {
        var snapshot = sample()
        let generated = Date(timeIntervalSince1970: Double(snapshot.generatedAtMs) / 1000)

        XCTAssertFalse(snapshot.isStale(at: generated.addingTimeInterval(60)))
        XCTAssertTrue(snapshot.isStale(at: generated.addingTimeInterval(3 * 3600)))
        XCTAssertEqual(snapshot.ageMs(at: generated.addingTimeInterval(-100)), 0)

        snapshot.generatedAtMs = 0
        XCTAssertTrue(snapshot.isStale(at: Date()), "a file with no timestamp is not fresh")
    }

    func testCurrentStartedAtConvertsMillisecondsToADate() throws {
        let snapshot = sample()
        let started = try XCTUnwrap(snapshot.currentStartedAt)
        XCTAssertEqual(started.timeIntervalSince1970, 1_756_510_800, accuracy: 0.001)
    }
}
