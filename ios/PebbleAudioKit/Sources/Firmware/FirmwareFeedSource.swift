import Foundation

/// Where the release feed lives — the one configuration point for the whole feature.
///
/// **Nothing is published yet, so this is deliberately unset.** With no source the update check
/// returns `.notConfigured`, no network call is ever made, and Settings does not draw the row at
/// all. That is the intended shipping state: a firmware screen that shows a permanently failing
/// feed would be worse than no screen, because it would read as the app being broken rather than
/// as the feature not having started.
///
/// To turn it on, put the raw URL of the feed JSON in `publishedFeedURL` below — for a GitHub
/// release that is a `https://github.com/<owner>/<repo>/releases/latest/download/firmware.json`
/// URL, which always resolves to the newest release's copy of the file, so the constant never
/// needs to change again. `FirmwareFeed` carries the schema and a worked example.
public enum FirmwareFeedSource {

    // ─────────────────────────────────────────────────────────────────────────────────────
    // PLACEHOLDER — set this when the firmware is actually published somewhere.
    // Must be https (`FirmwareRelease.assetURL` explains why). Leave nil until then.
    // ─────────────────────────────────────────────────────────────────────────────────────
    public static let publishedFeedURL: URL? = nil

    /// `UserDefaults` key for pointing a build at a different feed without a rebuild — a staging
    /// feed, or a `file://` fixture during development. Overrides the constant when set.
    public static let overrideDefaultsKey = "firmwareFeedURL"

    /// The feed to use, or nil when the feature is dormant.
    ///
    /// The override is checked first so a developer can aim a build at a test feed, and it is
    /// held to the same `https` rule as the constant — with one exception, `file://`, so a
    /// fixture on disk can stand in for a server. There is no in-app text field for this on
    /// purpose: an app that lets anyone type in a firmware source is an app that will eventually
    /// be talked into installing someone else's firmware.
    public static func resolved(
        defaults: UserDefaults = .standard,
        override: URL? = nil
    ) -> URL? {
        if let override { return validate(override) }
        if let text = defaults.string(forKey: overrideDefaultsKey),
           let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
           let validated = validate(url) {
            return validated
        }
        return publishedFeedURL.flatMap(validate)
    }

    /// True when there is somewhere to fetch from. Every surface gates on this.
    public static func isConfigured(defaults: UserDefaults = .standard) -> Bool {
        resolved(defaults: defaults) != nil
    }

    static func validate(_ url: URL) -> URL? {
        switch url.scheme?.lowercased() {
        case "https": return url
        case "file": return url
        default: return nil
        }
    }
}
