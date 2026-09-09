import Foundation
import Testing

@testable import Firmware

// The feed decoder is the app's border with a document it does not control. Its job is to be
// strict — a release it cannot fully vouch for is dropped, never softened into an offer.

struct FixtureError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func firmwareFixture(_ name: String) throws -> Data {
    guard let resourceURL = Bundle.module.resourceURL else {
        throw FixtureError("Bundle.module has no resourceURL")
    }
    let url = resourceURL
        .appendingPathComponent("Fixtures", isDirectory: true)
        .appendingPathComponent(name, isDirectory: false)
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw FixtureError("Fixture missing at \(url.path)")
    }
    return try Data(contentsOf: url)
}

@Suite("Firmware feed decoding")
struct FirmwareFeedTests {

    @Test("A sound feed decodes every release")
    func decodesValidFeed() throws {
        let feed = try FirmwareFeed.decode(firmwareFixture("feed_valid.json"))
        #expect(feed.schemaVersion == 1)
        #expect(feed.releases.count == 5)
        #expect(feed.rejectedCount == 0)

        let latest = try #require(feed.releases.first { $0.version.raw == "v4.36.1" && $0.board == .pebbleTime2 })
        #expect(latest.board.displayName == "Pebble Time 2")
        #expect(latest.sizeBytes == 1_245_184)
        #expect(latest.sha256 == String(repeating: "1", count: 64))
        #expect(latest.prerelease == false)
        #expect(latest.publishedAt != nil)
        #expect(latest.notes.hasPrefix("Upstream 4.36.1"))
    }

    @Test("Every unverifiable release is dropped, and the drops are counted")
    func dropsUnverifiableReleases() throws {
        let feed = try FirmwareFeed.decode(firmwareFixture("feed_hostile.json"))
        // Exactly one entry in that document is sound.
        #expect(feed.releases.count == 1)
        #expect(feed.rejectedCount == 5)
        #expect(feed.releases[0].version.raw == "v4.35.0")

        // Specifically: nothing plaintext, nothing digest-less, nothing unorderable survived.
        #expect(!feed.releases.contains { $0.assetURL.scheme != "https" })
        #expect(feed.releases.allSatisfy { FirmwareRelease.isSHA256Hex($0.sha256) })
        #expect(!feed.releases.contains { $0.version.raw == "latest" })
    }

    @Test("A newer schema is refused whole rather than guessed at")
    func refusesFutureSchema() throws {
        let data = try firmwareFixture("feed_future_schema.json")
        #expect(throws: FirmwareFeedError.self) { try FirmwareFeed.decode(data) }
    }

    @Test("A document that is not the feed at all is a clean error")
    func rejectsGarbage() {
        #expect(throws: FirmwareFeedError.self) { try FirmwareFeed.decode(Data("not json".utf8)) }
        #expect(throws: FirmwareFeedError.self) { try FirmwareFeed.decode(Data("{}".utf8)) }
    }

    @Test("Digest validation accepts exactly 64 lowercase hex characters")
    func digestShape() {
        #expect(FirmwareRelease.isSHA256Hex(String(repeating: "a", count: 64)))
        #expect(FirmwareRelease.isSHA256Hex(String(repeating: "0", count: 64)))
        #expect(!FirmwareRelease.isSHA256Hex(String(repeating: "A", count: 64)))  // uppercase
        #expect(!FirmwareRelease.isSHA256Hex(String(repeating: "a", count: 63)))
        #expect(!FirmwareRelease.isSHA256Hex(String(repeating: "a", count: 65)))
        #expect(!FirmwareRelease.isSHA256Hex("sha256:" + String(repeating: "a", count: 57)))
        #expect(!FirmwareRelease.isSHA256Hex(String(repeating: "g", count: 64)))  // not hex
        #expect(!FirmwareRelease.isSHA256Hex(""))
    }

    @Test("The download is named with the .pbz suffix the Pebble app routes on")
    func fileNameCarriesTheSuffix() throws {
        let feed = try FirmwareFeed.decode(firmwareFixture("feed_valid.json"))
        for release in feed.releases {
            #expect(release.suggestedFileName.hasSuffix(".pbz"))
            #expect(!release.suggestedFileName.contains("/"))
            #expect(!release.suggestedFileName.contains(" "))
        }
        let named = FirmwareRelease(
            version: try #require(FirmwareVersion("4.36.1+audio 3/beta")),
            board: FirmwareBoard("obelix"),
            assetURL: URL(string: "https://example.invalid/a.pbz")!,
            sha256: String(repeating: "a", count: 64)
        )
        // Path separators and spaces are scrubbed; the suffix survives.
        #expect(named.suggestedFileName == "pebble-4.36.1-audio-3-beta-obelix.pbz")
    }

    @Test("Boards normalise, so 'Obelix' and 'obelix ' are one board")
    func boardNormalisation() {
        #expect(FirmwareBoard("Obelix") == FirmwareBoard("obelix"))
        #expect(FirmwareBoard(" obelix ") == .pebbleTime2)
        #expect(FirmwareBoard("obelix").displayName == "Pebble Time 2")
        #expect(FirmwareBoard("something-new").displayName == nil)
    }

    @Test("A release round-trips through encode and decode")
    func roundTrip() throws {
        let feed = try FirmwareFeed.decode(firmwareFixture("feed_valid.json"))
        let original = feed.releases[0]
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FirmwareRelease.self, from: data)
        #expect(decoded == original)
    }
}
