import Foundation

// Whether THIS binary may talk to Apple Private Cloud Compute at all.
//
// Why this exists, measured on the iOS 27.0 simulator (24A434): without the managed entitlement
// `com.apple.developer.private-cloud-compute`, `PrivateCloudComputeLanguageModel.availability`
// reads `.available`, `quotaUsage` reads "below limit", `contextSize` answers 32,768, a session
// opens — and the first `respond` does not throw, it TRAPS:
//
//     [IPC] ModelManager received unentitled request. Expected entitlement
//       com.apple.developer.private-cloud-compute
//     FoundationModels/ErrorConversion.swift:140: Fatal error: Missing entitlement: …
//
// macOS 27 throws an `NSError` (-1 over `ModelManagerError 1046`) for the same thing; iOS kills
// the process. So the provider cannot learn the build's status from a failed request, the way
// the first design did — there is no process left to learn in. It has to know before the first
// request, and the one public place the answer lives is the provisioning profile the app was
// signed with: `embedded.mobileprovision`, a CMS envelope around an XML plist whose
// `Entitlements` dictionary is exactly what the signature granted.
//
// A simulator build carries no profile, and neither does an unsigned host process: both read
// as "not enabled", which is the truth, and the provider then never opens a session.

public enum ApplePrivateCloudEntitlement {
    /// The managed entitlement's key, as it appears in a profile's `Entitlements` dictionary.
    public static let key = "com.apple.developer.private-cloud-compute"

    /// Whether the profile the bundle was signed with grants the entitlement. False when there
    /// is no embedded profile (simulator, unsigned), when it cannot be read, or when the key is
    /// absent or false — every failure is "not enabled", never a guess at "enabled".
    public static func isGranted(in bundle: Bundle = .main) -> Bool {
        guard let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
            let data = try? Data(contentsOf: url)
        else { return false }
        return isGranted(inProfile: data)
    }

    /// The same decision over the profile's bytes, for tests.
    public static func isGranted(inProfile data: Data) -> Bool {
        guard let entitlements = entitlements(inProfile: data) else { return false }
        return granted(entitlements[key])
    }

    /// The `Entitlements` dictionary out of a CMS-wrapped profile, or nil when the bytes do not
    /// contain one. The XML plist sits inside the DER envelope as an octet string; locating it by
    /// its own `<?xml` / `</plist>` markers is the documented-enough shape of every profile
    /// Xcode has ever written, and needs no CMS parsing.
    static func entitlements(inProfile data: Data) -> [String: Any]? {
        guard let start = data.range(of: Data("<?xml".utf8))?.lowerBound,
            let end = data.range(of: Data("</plist>".utf8), in: start..<data.endIndex)?.upperBound
        else { return nil }
        let plist = data[start..<end]
        guard
            let object = try? PropertyListSerialization.propertyList(
                from: plist, options: [], format: nil),
            let profile = object as? [String: Any]
        else { return nil }
        return profile["Entitlements"] as? [String: Any]
    }

    /// A key that is present with any value other than `false` counts. Managed entitlements
    /// are booleans; being tolerant of another shape costs nothing, because the framework is
    /// what enforces it, and being strict here would only turn a true "yes" into a wrong "no".
    static func granted(_ value: Any?) -> Bool {
        switch value {
        case nil: return false
        case let flag as Bool: return flag
        case let number as NSNumber: return number.boolValue
        default: return true
        }
    }
}
