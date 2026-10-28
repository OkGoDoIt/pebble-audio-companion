import Foundation

/// Where the release feed lives — the one configuration point for the whole feature.
///
/// Builds are published as GitHub releases of the PebbleOS fork by
/// `scripts/publish-firmware-release.sh` (workspace root). Each release carries one `.pbz` with
/// both slots and a `firmware.json` naming it, and `releases/latest/download/firmware.json`
/// always resolves to the newest release's copy — so this constant never changes again.
/// `FirmwareFeed` carries the schema and a worked example.
///
/// With no source the update check returns `.notConfigured`, no network call is ever made, and
/// the firmware rows are not drawn at all.
public enum FirmwareFeedSource {

    /// Must be https (`FirmwareRelease.assetURL` explains why).
    public static let publishedFeedURL: URL? = URL(
        string: "https://github.com/OkGoDoIt/PebbleOS/releases/latest/download/firmware.json"
    )

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
