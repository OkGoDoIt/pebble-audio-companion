import Foundation

/// What one published firmware build looks like, and the feed that lists them.
///
/// The shape is deliberately small and strict. Everything here ends up deciding whether a
/// several-hundred-kilobyte binary gets written to the flash of a watch someone wears, so the
/// decoder's job is to reject anything it cannot fully vouch for rather than to be forgiving:
/// a release that fails validation is dropped, and a feed whose releases all fail decodes to an
/// empty feed, which the UI renders as "nothing to install" — never as an unverified offer.

// MARK: - Errors

public enum FirmwareFeedError: Error, Equatable, Sendable {
    /// No release feed is configured. Not a failure — the whole feature is optional and stays
    /// invisible until a feed URL exists.
    case notConfigured
    /// The feed URL or an asset URL is not `https`. See `FirmwareRelease.assetURL`.
    case insecureURL(String)
    case http(status: Int)
    case malformed(String)
    case network(String)

    public var isNotConfigured: Bool { self == .notConfigured }
}

// MARK: - Board

/// The watch a build is for, as the firmware build system names it (`obelix` for Pebble Time 2).
///
/// This is a plain string rather than an enum because the set of boards is upstream's to
/// change; an enum here would silently drop a release for a board added after this app shipped.
public struct FirmwareBoard: Sendable, Hashable, Codable, CustomStringConvertible {
    public let id: String

    public init(_ id: String) {
        self.id = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public init(from decoder: any Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(id)
    }

    public var description: String { id }

    /// The only board this project actually builds for today (`pbl configure --board obelix@pvt`).
    public static let pebbleTime2 = FirmwareBoard("obelix")

    /// Human name, when we happen to know one. Nil is fine and common — an unknown board is
    /// shown by its build-system id rather than by a guess.
    public var displayName: String? {
        switch id {
        case "obelix": return "Pebble Time 2"
        case "asterix": return "Pebble 2 Duo"
        default: return nil
        }
    }
}

// MARK: - Release

public struct FirmwareRelease: Sendable, Equatable, Identifiable, Codable {
    /// Stable id for lists and for remembering what was handed off. The version tag plus board
    /// is unique per release by construction.
    public var id: String { "\(board.id)/\(version.raw)" }

    public let version: FirmwareVersion
    public let board: FirmwareBoard
    /// When the build was published, for "3 days ago" and for ordering two releases that
    /// somehow carry the same version.
    public let publishedAt: Date?
    /// Release notes, plain text. Shown verbatim and never parsed — this is the one field the
    /// person reads to decide, so the app must not editorialise it.
    public let notes: String
    /// Where the `.pbz` lives.
    ///
    /// Required to be `https`. The checksum below travels in the same document, so plaintext
    /// transport would let one attacker rewrite the image and its digest together; requiring TLS
    /// on both is the cheap half of making the digest mean something.
    public let assetURL: URL
    /// Expected size, for the progress bar and as a first cheap mismatch check.
    public let sizeBytes: Int64?
    /// Lowercase SHA-256 hex of the `.pbz`, 64 characters.
    ///
    /// **Required.** A release without a usable digest is dropped, because the alternative is an
    /// app that downloads a binary it cannot check and hands it to something that will flash it.
    /// "Offer it anyway and warn" is not a real option here: the warning would be shown to
    /// someone who has no way to act on it.
    public let sha256: String
    /// A build the publisher does not consider ready. Never offered by default; the update
    /// check has to be asked for it explicitly.
    public let prerelease: Bool

    public init(
        version: FirmwareVersion,
        board: FirmwareBoard,
        publishedAt: Date? = nil,
        notes: String = "",
        assetURL: URL,
        sizeBytes: Int64? = nil,
        sha256: String,
        prerelease: Bool = false
    ) {
        self.version = version
        self.board = board
        self.publishedAt = publishedAt
        self.notes = notes
        self.assetURL = assetURL
        self.sizeBytes = sizeBytes
        self.sha256 = sha256.lowercased()
        self.prerelease = prerelease
    }

    /// The file name the download is saved under.
    ///
    /// **The `.pbz` suffix is load-bearing, not cosmetic.** The official Pebble iOS app routes an
    /// opened document purely by its name: `RealPebbleDeepLinkHandler.handle()` reaches
    /// `handleFirmware()` only through `uri.lastPathSegment?.endsWith(".pbz")`. A file handed
    /// over as `firmware` or `download.bin` is silently ignored by that app — no error, nothing
    /// happens — so the suffix is asserted here rather than left to whatever the asset URL
    /// happened to be called.
    public var suggestedFileName: String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._"))
        let stem = "pebble-\(version.raw)-\(board.id)"
            .unicodeScalars
            .map { allowed.contains($0) ? Character($0) : "-" }
        return String(stem) + ".pbz"
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case version, board, publishedAt, notes, url, sizeBytes, sha256, prerelease
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let versionText = try c.decode(String.self, forKey: .version)
        guard let version = FirmwareVersion(versionText) else {
            throw DecodingError.dataCorruptedError(
                forKey: .version, in: c, debugDescription: "Unorderable version '\(versionText)'"
            )
        }
        self.version = version
        self.board = try c.decode(FirmwareBoard.self, forKey: .board)
        guard !board.id.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .board, in: c, debugDescription: "Empty board"
            )
        }
        self.publishedAt = try c.decodeIfPresent(String.self, forKey: .publishedAt)
            .flatMap(FirmwareFeed.date(fromISO8601:))
        self.notes = (try c.decodeIfPresent(String.self, forKey: .notes) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let urlText = try c.decode(String.self, forKey: .url)
        guard let url = URL(string: urlText), let scheme = url.scheme?.lowercased() else {
            throw DecodingError.dataCorruptedError(
                forKey: .url, in: c, debugDescription: "Unparseable asset URL"
            )
        }
        guard scheme == "https" else {
            throw DecodingError.dataCorruptedError(
                forKey: .url, in: c, debugDescription: "Asset URL must be https, got '\(scheme)'"
            )
        }
        self.assetURL = url

        self.sizeBytes = try c.decodeIfPresent(Int64.self, forKey: .sizeBytes)
        let digest = try c.decode(String.self, forKey: .sha256).lowercased()
        guard FirmwareRelease.isSHA256Hex(digest) else {
            throw DecodingError.dataCorruptedError(
                forKey: .sha256, in: c,
                debugDescription: "sha256 must be 64 hex characters"
            )
        }
        self.sha256 = digest
        self.prerelease = try c.decodeIfPresent(Bool.self, forKey: .prerelease) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version.raw, forKey: .version)
        try c.encode(board, forKey: .board)
        if let publishedAt {
            try c.encode(FirmwareFeed.iso8601.format(publishedAt), forKey: .publishedAt)
        }
        if !notes.isEmpty { try c.encode(notes, forKey: .notes) }
        try c.encode(assetURL.absoluteString, forKey: .url)
        try c.encodeIfPresent(sizeBytes, forKey: .sizeBytes)
        try c.encode(sha256, forKey: .sha256)
        if prerelease { try c.encode(prerelease, forKey: .prerelease) }
    }

    /// 64 lowercase hex characters and nothing else. A digest that is truncated, uppercase-with-
    /// stray-spaces or prefixed `sha256:` is rejected at decode rather than at verify time, so a
    /// typo in the feed can never produce a download that "verifies".
    static func isSHA256Hex(_ text: String) -> Bool {
        text.count == 64 && text.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}

// MARK: - Feed

/// The published document: a schema version and the releases.
///
/// Decoding drops individual malformed releases instead of failing the whole feed, so one
/// bad entry cannot hide every good one — but each drop is recorded in `rejectedCount` so the
/// UI can say the feed was partly unreadable rather than pretending it was short.
///
/// The document to publish alongside the `.pbz` assets (one release shown; `notes`,
/// `publishedAt`, `sizeBytes` and `prerelease` are optional, everything else is required):
///
/// ```json
/// {
///   "schemaVersion": 1,
///   "releases": [
///     {
///       "version": "v4.36.1+audio.3",
///       "board": "obelix",
///       "publishedAt": "2026-08-14T09:30:00Z",
///       "notes": "Upstream 4.36.1. Audio companion service unchanged.",
///       "url": "https://github.com/OWNER/REPO/releases/download/v4.36.1/pebble-4.36.1-obelix.pbz",
///       "sizeBytes": 1245184,
///       "sha256": "…64 lowercase hex characters, `shasum -a 256 the.pbz`…",
///       "prerelease": false
///     }
///   ]
/// }
/// ```
///
/// `board` is the firmware build system's board name — `obelix` for Pebble Time 2, matching
/// `pbl configure --board obelix@pvt`. `Tests/FirmwareTests/Fixtures/feed_valid.json` is a
/// complete working example.
public struct FirmwareFeed: Sendable, Equatable {
    /// Bumped only for a breaking change to the document shape. A feed declaring a schema this
    /// build does not know is refused wholesale: guessing at an unknown layout is exactly the
    /// kind of cleverness that ends up flashing the wrong file.
    public static let supportedSchemaVersion = 1

    public let schemaVersion: Int
    public let releases: [FirmwareRelease]
    /// Entries the decoder threw away. Non-zero means the feed says more than this app can read.
    public let rejectedCount: Int

    public init(schemaVersion: Int = FirmwareFeed.supportedSchemaVersion,
                releases: [FirmwareRelease],
                rejectedCount: Int = 0) {
        self.schemaVersion = schemaVersion
        self.releases = releases
        self.rejectedCount = rejectedCount
    }

    public static func decode(_ data: Data) throws -> FirmwareFeed {
        struct Envelope: Decodable {
            let schemaVersion: Int?
            let releases: [FailableRelease]
        }
        /// One release, or nothing. `Result` rather than `try?` so the count of dropped entries
        /// survives.
        struct FailableRelease: Decodable {
            let release: FirmwareRelease?
            init(from decoder: any Decoder) throws {
                release = try? FirmwareRelease(from: decoder)
            }
        }

        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw FirmwareFeedError.malformed("Feed is not the expected JSON document")
        }
        let schema = envelope.schemaVersion ?? supportedSchemaVersion
        guard schema <= supportedSchemaVersion else {
            throw FirmwareFeedError.malformed(
                "Feed schema \(schema) is newer than this app understands"
            )
        }
        let decoded = envelope.releases.compactMap(\.release)
        return FirmwareFeed(
            schemaVersion: schema,
            releases: decoded,
            rejectedCount: envelope.releases.count - decoded.count
        )
    }

    // MARK: Dates

    // Format STYLES, not formatters: `Date.ISO8601FormatStyle` is a `Sendable` value, where an
    // `ISO8601DateFormatter` held in a static is shared mutable state to the compiler. The default
    // style is exactly `.withInternetDateTime` (date, time, "Z" or an offset).
    static let iso8601 = Date.ISO8601FormatStyle()

    private static let iso8601Fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// GitHub stamps release dates without fractional seconds; other generators add them.
    /// A date that parses under neither is dropped, not defaulted to "now" — a wrong date would
    /// make a stale release look fresh.
    static func date(fromISO8601 text: String) -> Date? {
        (try? iso8601.parse(text)) ?? (try? iso8601Fractional.parse(text))
    }
}
