import Foundation

/// A firmware version, parsed well enough to order two of them correctly.
///
/// This exists because the obvious implementation is wrong in a way that ships bad firmware:
/// `"4.10" > "4.9"` is false as a string compare, so a plain `<` on the tag would have called a
/// newer build older and quietly stopped offering updates at 4.9. Ordering is therefore over
/// the numeric components, never over the text.
///
/// Accepted shape (a superset of what PebbleOS tags look like — `v4.36`, `v4.36.1`, and the
/// audio-companion branch's own suffixed tags):
///
///     [v]MAJOR[.MINOR[.PATCH[.EXTRA…]]][-prerelease][+build]
///
/// Ordering, in priority order:
///
/// 1. **Numeric core**, component by component, missing components read as 0 — so `4.36` and
///    `4.36.0` are the same version, which is what a release feed that omits a trailing zero
///    means.
/// 2. **Prerelease**, semver's rule: a version WITH a prerelease sorts before the same version
///    without one (`4.36.1-rc.1` < `4.36.1`). Identifiers compare numerically when both are
///    numeric, otherwise as text.
/// 3. **Build metadata** — and here we deliberately deviate from semver, which says build
///    metadata is ignored for ordering. This project's firmware is upstream PebbleOS plus a
///    branch, so two publishable builds can differ ONLY in that suffix (`4.36.1+audio.3` then
///    `4.36.1+audio.4`). Under strict semver those compare equal and the second one would never
///    be offered. Build metadata is therefore significant, ranked last, with "has one" sorting
///    after "has none" (a build of 4.36.1 comes after plain 4.36.1).
///
/// Equality follows the same rule set: two versions are `==` exactly when they order the same.
/// `4.36` and `v4.36.0` are equal; `4.36.1+audio.3` and `4.36.1` are not.
public struct FirmwareVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    /// The version exactly as the feed (or the watch) spelled it. Displayed verbatim: an
    /// invented canonical form ("4.36.0" for a release tagged "v4.36") would not match what the
    /// person sees on the release page.
    public let raw: String

    /// The dot-separated numeric core, `v` stripped. Never empty.
    public let components: [Int]
    /// Dot-separated identifiers after the first `-`, empty when there is no prerelease.
    public let prerelease: [String]
    /// Dot-separated identifiers after the first `+`, empty when there is no build metadata.
    public let build: [String]

    public var description: String { raw }

    /// Parses a version tag, or returns nil when there is no numeric core to order by.
    ///
    /// Returning nil rather than a "0.0.0" fallback is deliberate: an unparseable version must
    /// make the caller say "unknown", never make it claim the oldest possible version and offer
    /// every release as an upgrade.
    public init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var body = Substring(trimmed)
        if body.first == "v" || body.first == "V" { body = body.dropFirst() }

        // `+` binds looser than `-`: semver puts build metadata last, so split it off first and
        // a `-` inside build metadata stays inside it.
        var buildText = Substring("")
        if let plus = body.firstIndex(of: "+") {
            buildText = body[body.index(after: plus)...]
            body = body[..<plus]
        }
        var prereleaseText = Substring("")
        if let dash = body.firstIndex(of: "-") {
            prereleaseText = body[body.index(after: dash)...]
            body = body[..<dash]
        }

        let numeric = body.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard !numeric.isEmpty else { return nil }
        var parsed: [Int] = []
        parsed.reserveCapacity(numeric.count)
        for part in numeric {
            // Every component must be a plain non-negative integer. Anything else ("4.x",
            // "latest") is not a version we can order, and guessing at one is how a bad
            // comparison ships.
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let value = Int(part) else {
                return nil
            }
            parsed.append(value)
        }

        self.raw = trimmed
        self.components = parsed
        self.prerelease = FirmwareVersion.identifiers(prereleaseText)
        self.build = FirmwareVersion.identifiers(buildText)
    }

    private static func identifiers(_ text: Substring) -> [String] {
        guard !text.isEmpty else { return [] }
        return text.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    }

    // MARK: Ordering

    public static func < (lhs: FirmwareVersion, rhs: FirmwareVersion) -> Bool {
        ordering(lhs, rhs) == .orderedAscending
    }

    public static func == (lhs: FirmwareVersion, rhs: FirmwareVersion) -> Bool {
        ordering(lhs, rhs) == .orderedSame
    }

    public func hash(into hasher: inout Hasher) {
        // Must agree with `==`: trailing zeros are not part of identity, so normalise them away
        // before hashing or `4.36` and `4.36.0` would be equal with different hashes.
        var core = components
        while core.count > 1, core.last == 0 { core.removeLast() }
        hasher.combine(core)
        hasher.combine(prerelease)
        hasher.combine(build)
    }

    static func ordering(_ lhs: FirmwareVersion, _ rhs: FirmwareVersion) -> ComparisonResult {
        let width = max(lhs.components.count, rhs.components.count)
        for index in 0..<width {
            let l = index < lhs.components.count ? lhs.components[index] : 0
            let r = index < rhs.components.count ? rhs.components[index] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        // Semver: a prerelease sorts BEFORE the release it leads to.
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, false): return .orderedDescending
        case (false, true): return .orderedAscending
        default: break
        }
        let prereleaseOrder = compareIdentifiers(lhs.prerelease, rhs.prerelease)
        if prereleaseOrder != .orderedSame { return prereleaseOrder }
        // Deviation from semver, documented on the type: a build of X is later than plain X.
        switch (lhs.build.isEmpty, rhs.build.isEmpty) {
        case (true, false): return .orderedAscending
        case (false, true): return .orderedDescending
        default: break
        }
        return compareIdentifiers(lhs.build, rhs.build)
    }

    /// Semver identifier ordering: numeric identifiers compare as numbers and rank below
    /// alphanumeric ones; a shorter run of otherwise-equal identifiers sorts first.
    private static func compareIdentifiers(_ lhs: [String], _ rhs: [String]) -> ComparisonResult {
        for index in 0..<min(lhs.count, rhs.count) {
            let l = lhs[index]
            let r = rhs[index]
            if l == r { continue }
            switch (Int(l), Int(r)) {
            case let (.some(ln), .some(rn)):
                return ln < rn ? .orderedAscending : .orderedDescending
            case (.some, .none):
                return .orderedAscending
            case (.none, .some):
                return .orderedDescending
            case (.none, .none):
                return l < r ? .orderedAscending : .orderedDescending
            }
        }
        if lhs.count == rhs.count { return .orderedSame }
        return lhs.count < rhs.count ? .orderedAscending : .orderedDescending
    }
}
