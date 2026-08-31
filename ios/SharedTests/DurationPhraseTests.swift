import XCTest

/// The loss notification is the one thing this product interrupts a person for, so its numbers
/// have to read as calm and honest — not precise, not alarmist, never zero.
final class DurationPhraseTests: XCTestCase {
    func testSecondsRoundToFivesAndKeepAFloor() {
        XCTAssertEqual(DurationPhrase.approximate(ms: 40_000), "40 seconds")
        XCTAssertEqual(DurationPhrase.approximate(ms: 43_600), "45 seconds")
        XCTAssertEqual(DurationPhrase.approximate(ms: 31_000), "30 seconds")
        // Never "0 seconds": a spool-overflow gap can be tiny, and the phrase still has to
        // name a real amount of missing audio.
        XCTAssertEqual(DurationPhrase.approximate(ms: 0), "5 seconds")
        XCTAssertEqual(DurationPhrase.approximate(ms: 900), "5 seconds")
        XCTAssertEqual(DurationPhrase.approximate(ms: -5_000), "5 seconds")
    }

    func testMinutes() {
        XCTAssertEqual(DurationPhrase.approximate(ms: 58_000), "1 minute", "rounds up to the unit")
        XCTAssertEqual(DurationPhrase.approximate(ms: 60_000), "1 minute")
        XCTAssertEqual(DurationPhrase.approximate(ms: 180_000), "3 minutes")
        XCTAssertEqual(DurationPhrase.approximate(ms: 20 * 60_000), "20 minutes")
        XCTAssertEqual(DurationPhrase.approximate(ms: 59 * 60_000 + 45_000), "1 hour")
    }

    func testHours() {
        XCTAssertEqual(DurationPhrase.approximate(ms: 3_600_000), "1 hour")
        XCTAssertEqual(DurationPhrase.approximate(ms: 2 * 3_600_000), "2 hours")
        XCTAssertEqual(DurationPhrase.approximate(ms: 3_600_000 + 20 * 60_000), "1 hour 20 minutes")
        // A 2-minute remainder rounds away rather than pretending to that resolution.
        XCTAssertEqual(DurationPhrase.approximate(ms: 3_600_000 + 2 * 60_000), "1 hour")
        XCTAssertEqual(DurationPhrase.approximate(ms: 3_600_000 + 59 * 60_000), "2 hours")
    }

    func testAboutAddsTheHedgeExactlyOnce() {
        XCTAssertEqual(DurationPhrase.about(ms: 40_000), "about 40 seconds")
        XCTAssertEqual(DurationPhrase.about(ms: 180_000), "about 3 minutes")
        // The notification body already says "for about {duration}" — so the value it is
        // handed must NOT contain "about".
        XCTAssertFalse(DurationPhrase.approximate(ms: 180_000).contains("about"))
    }

    func testCompactMatchesTheAppsFormattingVocabulary() {
        XCTAssertEqual(DurationPhrase.compact(ms: 38_000), "38 sec")
        XCTAssertEqual(DurationPhrase.compact(ms: 5 * 60_000), "5 min")
        XCTAssertEqual(DurationPhrase.compact(ms: 4 * 3_600_000 + 12 * 60_000), "4 hr 12 min")
        XCTAssertEqual(DurationPhrase.compact(ms: 3_600_000), "1 hr")
        XCTAssertEqual(DurationPhrase.compact(ms: 0), "0 sec")
    }
}
