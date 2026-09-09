import Foundation
import Testing

@testable import Firmware

@Suite("Firmware update decision")
struct FirmwareUpdateCheckTests {

    private func release(
        _ version: String,
        board: String = "obelix",
        prerelease: Bool = false,
        publishedAt: Date? = nil
    ) throws -> FirmwareRelease {
        FirmwareRelease(
            version: try #require(FirmwareVersion(version)),
            board: FirmwareBoard(board),
            publishedAt: publishedAt,
            assetURL: URL(string: "https://example.invalid/\(version).pbz")!,
            sha256: String(repeating: "a", count: 64),
            prerelease: prerelease
        )
    }

    @Test("With nothing known about the watch, the newest release is offered but not pushed")
    func unknownInstalled() throws {
        let feed = FirmwareFeed(releases: [try release("4.9"), try release("4.10")])
        let result = FirmwareUpdateCheck.evaluate(feed: feed)
        #expect(result == .available(try release("4.10")))
        // `.available` is an offer, not a claim that it is an upgrade — it must not badge.
        #expect(result.isUpdate == false)
    }

    @Test("A strictly newer release is an update")
    func update() throws {
        let feed = FirmwareFeed(releases: [try release("4.36.1")])
        let installed = try #require(FirmwareVersion("4.36.0"))
        let result = FirmwareUpdateCheck.evaluate(feed: feed, installed: installed)
        #expect(result == .update(try release("4.36.1"), from: installed))
        #expect(result.isUpdate)
    }

    @Test("The same version is up to date, not an update")
    func upToDate() throws {
        let feed = FirmwareFeed(releases: [try release("v4.36")])
        let installed = try #require(FirmwareVersion("4.36.0"))
        let result = FirmwareUpdateCheck.evaluate(feed: feed, installed: installed)
        #expect(result == .upToDate(try release("v4.36"), installed: installed))
        #expect(result.isUpdate == false)
    }

    @Test("A locally built firmware newer than the feed is stated, never downgraded")
    func installedIsNewer() throws {
        let feed = FirmwareFeed(releases: [try release("4.36.1")])
        let installed = try #require(FirmwareVersion("4.37.0"))
        let result = FirmwareUpdateCheck.evaluate(feed: feed, installed: installed)
        #expect(result == .installedIsNewer(try release("4.36.1"), installed: installed))
        #expect(result.isUpdate == false)
    }

    @Test("Prereleases are invisible unless asked for")
    func prereleasesAreOptIn() throws {
        let feed = FirmwareFeed(releases: [try release("4.36.1"), try release("4.37.0-rc.1", prerelease: true)])
        #expect(FirmwareUpdateCheck.evaluate(feed: feed).release?.version.raw == "4.36.1")
        #expect(
            FirmwareUpdateCheck.evaluate(feed: feed, includePrereleases: true).release?.version.raw
                == "4.37.0-rc.1"
        )
    }

    @Test("An empty or entirely-prerelease feed offers nothing")
    func noReleases() throws {
        #expect(FirmwareUpdateCheck.evaluate(feed: FirmwareFeed(releases: [])) == .noReleases)
        let onlyPre = FirmwareFeed(releases: [try release("4.37.0-rc.1", prerelease: true)])
        #expect(FirmwareUpdateCheck.evaluate(feed: onlyPre) == .noReleases)
    }

    @Test("A known board filters; an unknown board does not hide everything")
    func boardFiltering() throws {
        let feed = FirmwareFeed(releases: [
            try release("4.36.1", board: "obelix"),
            try release("4.40.0", board: "asterix"),
        ])
        // The app does not know the board today, so nothing is filtered and the newest wins.
        // The screen names the board it is offering — that is what keeps this honest.
        #expect(FirmwareUpdateCheck.evaluate(feed: feed).release?.board == FirmwareBoard("asterix"))
        // When a board IS known, only that board's builds are candidates.
        #expect(
            FirmwareUpdateCheck.evaluate(feed: feed, board: .pebbleTime2).release?.version.raw
                == "4.36.1"
        )
        #expect(FirmwareUpdateCheck.evaluate(feed: feed, board: FirmwareBoard("nothing")) == .noReleases)
    }

    @Test("Version wins over publish date; the date only breaks a version tie")
    func ordering() throws {
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let new = Date(timeIntervalSince1970: 1_800_000_000)
        // A 4.9 published yesterday must not beat a 4.10 published last year.
        let feed = FirmwareFeed(releases: [
            try release("4.9", publishedAt: new),
            try release("4.10", publishedAt: old),
        ])
        #expect(FirmwareUpdateCheck.evaluate(feed: feed).release?.version.raw == "4.10")

        let tie = FirmwareFeed(releases: [
            try release("4.10", board: "obelix", publishedAt: old),
            try release("4.10", board: "asterix", publishedAt: new),
        ])
        #expect(FirmwareUpdateCheck.evaluate(feed: tie).release?.board == FirmwareBoard("asterix"))
    }

    @Test("The decision over the real fixture feed")
    func overFixture() throws {
        let feed = try FirmwareFeed.decode(firmwareFixture("feed_valid.json"))
        // Newest non-prerelease is 4.36.1 (two boards publish it; either is version-correct).
        let offered = try #require(FirmwareUpdateCheck.evaluate(feed: feed).release)
        #expect(offered.version.raw == "v4.36.1")

        let installed = try #require(FirmwareVersion("v4.10"))
        let result = FirmwareUpdateCheck.evaluate(feed: feed, board: .pebbleTime2, installed: installed)
        #expect(result.isUpdate)
        #expect(result.release?.version.raw == "v4.36.1")
        #expect(result.release?.board == .pebbleTime2)
    }
}
