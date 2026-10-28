import Foundation

/// Where a belief about the installed firmware came from.
///
/// The provenance is part of the answer, not decoration. The watch states its exact build in its
/// Device Information Service, and that is the only source strong enough to say "up to date".
/// (The companion Info characteristic's `fw_version_packed` is major.minor.patch only, which
/// every build of a release shares, so it cannot tell two builds apart.) Saying "Installed: 4.36"
/// from a hand-off record would be a claim the app cannot support: the person may have cancelled
/// at the share sheet, the Pebble app may have refused the board, the watch may have been out of
/// range.
public enum FirmwareVersionSource: Sendable, Equatable {
    /// The watch reported it: the Firmware Revision String of its Device Information Service.
    case watchReported
    /// This app handed that build to the Pebble app on this date. A record of an intention, not
    /// of an install — worded that way everywhere it is shown.
    case handedOff(Date)
}

/// A version this app believes is on the watch, and why it believes it.
public struct KnownFirmware: Sendable, Equatable {
    public let version: FirmwareVersion
    public let source: FirmwareVersionSource

    public init(version: FirmwareVersion, source: FirmwareVersionSource) {
        self.version = version
        self.source = source
    }

    /// Whether this is the watch's own word. Only a `watchReported` version is strong enough to
    /// let the UI say "up to date" as a fact rather than as an inference.
    public var isFromWatch: Bool { source == .watchReported }
}

/// The answer to "is there something to install?".
public enum FirmwareAvailability: Sendable, Equatable {
    /// No release feed is configured. The whole feature is invisible in this state.
    case notConfigured
    /// The feed loaded and lists nothing this watch could take.
    case noReleases
    /// A release exists and nothing is known about what is installed, so the app cannot say
    /// whether it is an update. The person decides — they know what they last flashed.
    case available(FirmwareRelease)
    /// Strictly newer than what is believed installed.
    case update(FirmwareRelease, from: FirmwareVersion)
    /// The newest published release is the one believed installed.
    case upToDate(FirmwareRelease, installed: FirmwareVersion)
    /// What is believed installed is newer than anything published — a local build, usually.
    /// Reported as a fact, never as "an update is available".
    case installedIsNewer(FirmwareRelease, installed: FirmwareVersion)

    /// The release this state is about, when there is one.
    public var release: FirmwareRelease? {
        switch self {
        case .notConfigured, .noReleases: return nil
        case .available(let r): return r
        case .update(let r, _): return r
        case .upToDate(let r, _): return r
        case .installedIsNewer(let r, _): return r
        }
    }

    /// Whether the app is actively suggesting the person install something. Deliberately false
    /// for `.available`: an offer the app cannot justify as an upgrade is shown, but it does not
    /// get a badge or a nudge.
    public var isUpdate: Bool {
        if case .update = self { return true }
        return false
    }
}

/// The pure decision: feed in, one answer out.
///
/// Kept free of networking, files and state so it can be pinned by tests, because this is where
/// a wrong answer has consequences — telling someone a build is newer when it is older is how
/// a watch ends up flashed backwards.
public enum FirmwareUpdateCheck {

    /// - Parameters:
    ///   - feed: what the publisher lists.
    ///   - board: the watch's board when it is known. **It never is today** — the audio-companion
    ///     service carries no hardware identifier (`InfoSnapshot` has none), so this is nil in
    ///     the shipping app and no board filtering happens. That is survivable because the
    ///     official Pebble app performs the real hardware gate before it writes anything:
    ///     `FirmwareUpdater.performSafetyChecks` throws `SafetyCheckFailed` on
    ///     `watchPlatform != firmware.hwRev`. This app's job is to state the board it is offering,
    ///     not to be the last line of defence.
    ///   - installed: what is believed to be on the watch, or nil.
    ///   - includePrereleases: off by default; a prerelease is never offered unless asked for.
    public static func evaluate(
        feed: FirmwareFeed,
        board: FirmwareBoard? = nil,
        installed: FirmwareVersion? = nil,
        includePrereleases: Bool = false
    ) -> FirmwareAvailability {
        let candidates = feed.releases
            .filter { includePrereleases || !$0.prerelease }
            .filter { board == nil || $0.board == board }
        guard let latest = newest(of: candidates) else { return .noReleases }
        guard let installed else { return .available(latest) }

        if latest.version > installed { return .update(latest, from: installed) }
        if latest.version == installed { return .upToDate(latest, installed: installed) }
        return .installedIsNewer(latest, installed: installed)
    }

    /// Newest by version; publish date only breaks a version tie, and the feed's own order
    /// breaks a tie in both (so a hand-written feed is at least deterministic).
    static func newest(of releases: [FirmwareRelease]) -> FirmwareRelease? {
        releases.enumerated().max { a, b in
            if a.element.version != b.element.version { return a.element.version < b.element.version }
            switch (a.element.publishedAt, b.element.publishedAt) {
            case let (.some(l), .some(r)) where l != r: return l < r
            case (.none, .some): return true
            case (.some, .none): return false
            default: return a.offset < b.offset
            }
        }?.element
    }
}
