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
//
// The profile is what the build MAY claim; the code signature is what it DOES claim, and only
// the second is enforced. So both are read (2026-09-29): the entitlements blob in the running
// executable's embedded signature must carry the key too. Without that, a profile regenerated
// with the capability would have enabled a binary signed from an entitlements file that never
// listed it — and that binary traps on its first request.

public enum ApplePrivateCloudEntitlement {
    /// The managed entitlement's key, as it appears in a profile's `Entitlements` dictionary.
    public static let key = "com.apple.developer.private-cloud-compute"

    /// Whether this binary may use the entitlement: the profile it was signed with GRANTS it,
    /// and the signature it actually carries CLAIMS it. False when either is missing or cannot
    /// be read — every failure is "not enabled", never a guess at "enabled".
    ///
    /// The profile alone was not enough, and the gap was a trap waiting for a provisioning
    /// change. The binary is signed with `App/App.entitlements` (project.yml's
    /// `CODE_SIGN_ENTITLEMENTS`), which does not list this key; a profile regenerated with the
    /// capability — a team-wide managed capability does exactly that — would have made this
    /// return true for a binary whose signature has no such entitlement, and iOS 27 TRAPS on
    /// the first request from such a binary. The entitlements the kernel enforces are the ones
    /// in the code signature, so that is what is read now, alongside the profile.
    public static func isGranted(in bundle: Bundle = .main) -> Bool {
        guard let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
            let profile = try? Data(contentsOf: url),
            let executable = bundle.executableURL
        else { return false }
        return isGranted(
            profile: profile, signedEntitlements: signedEntitlements(ofExecutableAt: executable))
    }

    /// The decision over both halves, for tests: the profile grants it AND the signature
    /// claims it.
    static func isGranted(profile: Data, signedEntitlements: [String: Any]?) -> Bool {
        guard isGranted(inProfile: profile), let signedEntitlements else { return false }
        return granted(signedEntitlements[key])
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

    // MARK: - The entitlements in the code signature

    /// The entitlements the executable at `url` is SIGNED with — the XML blob in its embedded
    /// code signature — or nil when the file is not a Mach-O this can walk, carries no
    /// signature, or its signature has no entitlements blob. Reads the header, the load
    /// commands and the signature only; never the whole binary.
    static func signedEntitlements(ofExecutableAt url: URL) -> [String: Any]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return signedEntitlements { offset, count in
            guard count > 0 else { return nil }
            do {
                try handle.seek(toOffset: offset)
                let data = try handle.read(upToCount: count)
                return data?.count == count ? data : nil
            } catch {
                return nil
            }
        }
    }

    /// The same walk over bytes already in memory, for tests.
    static func signedEntitlements(inMachO data: Data) -> [String: Any]? {
        signedEntitlements { offset, count in
            guard count > 0, offset <= UInt64(data.count),
                UInt64(count) <= UInt64(data.count) - offset
            else { return nil }
            let start = data.startIndex + Int(offset)
            return Data(data[start..<start + count])
        }
    }

    /// The walk: a fat header (arm64 slice preferred), the 64-bit Mach-O header, its load
    /// commands to `LC_CODE_SIGNATURE`, and the code-signing super blob to its entitlements
    /// slot. Every step is bounds-checked; anything unexpected is nil — "not signed with it".
    static func signedEntitlements(read: (UInt64, Int) -> Data?) -> [String: Any]? {
        guard let head = read(0, 8) else { return nil }
        var slice: UInt64 = 0
        let fatMagic = head.uint32(at: 0, bigEndian: true)
        if fatMagic == 0xcafe_babe || fatMagic == 0xcafe_babf {
            let is64 = fatMagic == 0xcafe_babf
            let count = Int(head.uint32(at: 4, bigEndian: true))
            let entry = is64 ? 32 : 20
            guard (1...16).contains(count), let table = read(8, count * entry) else { return nil }
            var chosen: UInt64?
            for index in 0..<count {
                let base = index * entry
                let offset =
                    is64
                    ? table.uint64(at: base + 8, bigEndian: true)
                    : UInt64(table.uint32(at: base + 8, bigEndian: true))
                // CPU_TYPE_ARM64 — the slice an iPhone runs.
                if table.uint32(at: base, bigEndian: true) == 0x0100_000c {
                    chosen = offset
                    break
                }
                if chosen == nil { chosen = offset }
            }
            guard let chosen else { return nil }
            slice = chosen
        }
        guard let header = read(slice, 32), header.uint32(at: 0, bigEndian: false) == 0xfeed_facf
        else { return nil }
        let commandCount = Int(header.uint32(at: 16, bigEndian: false))
        let commandBytes = Int(header.uint32(at: 20, bigEndian: false))
        guard commandCount > 0, (1...(16 << 20)).contains(commandBytes),
            let commands = read(slice + 32, commandBytes)
        else { return nil }
        var cursor = 0
        for _ in 0..<commandCount {
            guard cursor + 8 <= commands.count else { return nil }
            let command = commands.uint32(at: cursor, bigEndian: false)
            let size = Int(commands.uint32(at: cursor + 4, bigEndian: false))
            guard size >= 8, cursor + size <= commands.count else { return nil }
            // LC_CODE_SIGNATURE: a linkedit_data_command, { cmd, cmdsize, dataoff, datasize }.
            if command == 0x1d, size >= 16 {
                let offset = UInt64(commands.uint32(at: cursor + 8, bigEndian: false))
                let length = Int(commands.uint32(at: cursor + 12, bigEndian: false))
                guard (1...(64 << 20)).contains(length), let blob = read(slice + offset, length)
                else { return nil }
                return entitlements(inSuperBlob: blob)
            }
            cursor += size
        }
        return nil
    }

    /// The XML entitlements out of a code-signing super blob (big-endian throughout):
    /// `CSMAGIC_EMBEDDED_SIGNATURE`, then an index of { type, offset }; slot 5 is the
    /// entitlements blob, `CSMAGIC_EMBEDDED_ENTITLEMENTS` followed by the plist.
    static func entitlements(inSuperBlob blob: Data) -> [String: Any]? {
        guard blob.count >= 12, blob.uint32(at: 0, bigEndian: true) == 0xfade_0cc0 else {
            return nil
        }
        let count = Int(blob.uint32(at: 8, bigEndian: true))
        guard count >= 0, 12 + count * 8 <= blob.count else { return nil }
        for index in 0..<count {
            guard blob.uint32(at: 12 + index * 8, bigEndian: true) == 5 else { continue }
            let offset = Int(blob.uint32(at: 16 + index * 8, bigEndian: true))
            guard offset + 8 <= blob.count,
                blob.uint32(at: offset, bigEndian: true) == 0xfade_7171
            else { return nil }
            let length = Int(blob.uint32(at: offset + 4, bigEndian: true))
            guard length >= 8, offset + length <= blob.count else { return nil }
            let start = blob.startIndex + offset + 8
            let plist = Data(blob[start..<blob.startIndex + offset + length])
            return (try? PropertyListSerialization.propertyList(from: plist, format: nil))
                as? [String: Any]
        }
        return nil
    }
}

extension Data {
    /// Four bytes at `offset` (from the start of this value), in the given byte order. The
    /// caller has checked the bounds.
    fileprivate func uint32(at offset: Int, bigEndian: Bool) -> UInt32 {
        let bytes = (0..<4).map { UInt32(self[startIndex + offset + $0]) }
        return bigEndian
            ? bytes[0] << 24 | bytes[1] << 16 | bytes[2] << 8 | bytes[3]
            : bytes[3] << 24 | bytes[2] << 16 | bytes[1] << 8 | bytes[0]
    }

    fileprivate func uint64(at offset: Int, bigEndian: Bool) -> UInt64 {
        let high = UInt64(uint32(at: offset, bigEndian: bigEndian))
        let low = UInt64(uint32(at: offset + 4, bigEndian: bigEndian))
        return bigEndian ? high << 32 | low : low << 32 | high
    }
}
