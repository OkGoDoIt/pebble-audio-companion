import Foundation
import Testing

@testable import Intelligence

// Reading the Private Cloud Compute entitlement out of a provisioning profile — the one public
// signal that decides whether a request may be sent at all on iOS 27.

@Suite("Apple Private Cloud Compute · entitlement")
struct ApplePrivateCloudEntitlementTests {
    /// A profile-shaped blob: DER-ish junk around an XML plist, the way Xcode writes them.
    private func profile(entitlements: String) -> Data {
        var data = Data([0x30, 0x82, 0x1A, 0x2B, 0x06, 0x09, 0x2A, 0x86])
        data.append(
            Data(
                """
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                <plist version="1.0">
                <dict>
                    <key>AppIDName</key><string>Pebble Audio</string>
                    <key>Entitlements</key>
                    <dict>
                        <key>application-identifier</key><string>TEAM.dev.audiocompanion.app</string>
                        \(entitlements)
                    </dict>
                    <key>Name</key><string>test</string>
                </dict>
                </plist>
                """.utf8))
        data.append(Data([0x00, 0x31, 0x82, 0x0B, 0xFF, 0xFE]))
        return data
    }

    @Test func aProfileThatGrantsItSaysYes() {
        let granted = profile(
            entitlements: "<key>com.apple.developer.private-cloud-compute</key><true/>")
        #expect(ApplePrivateCloudEntitlement.isGranted(inProfile: granted))
    }

    @Test func aProfileWithoutItSaysNo() {
        #expect(!ApplePrivateCloudEntitlement.isGranted(inProfile: profile(entitlements: "")))
        let denied = profile(
            entitlements: "<key>com.apple.developer.private-cloud-compute</key><false/>")
        #expect(!ApplePrivateCloudEntitlement.isGranted(inProfile: denied))
    }

    /// Every failure to read is "no": junk, an empty file, a plist with no Entitlements.
    @Test func anythingUnreadableSaysNo() {
        #expect(!ApplePrivateCloudEntitlement.isGranted(inProfile: Data()))
        #expect(!ApplePrivateCloudEntitlement.isGranted(inProfile: Data([0x30, 0x82, 0x00])))
        let noEntitlements = Data(
            #"<?xml version="1.0"?><plist version="1.0"><dict><key>Name</key><string>x</string></dict></plist>"#
                .utf8)
        #expect(!ApplePrivateCloudEntitlement.isGranted(inProfile: noEntitlements))
    }

    @Test func aBundleWithoutAnEmbeddedProfileSaysNo() {
        // The kit's own test bundle is not signed with a profile.
        #expect(!ApplePrivateCloudEntitlement.isGranted(in: Bundle(for: Marker.self)))
    }

    @Test func theValueShapesAreReadTolerantly() {
        #expect(ApplePrivateCloudEntitlement.granted(true))
        #expect(!ApplePrivateCloudEntitlement.granted(false))
        #expect(!ApplePrivateCloudEntitlement.granted(nil))
        #expect(ApplePrivateCloudEntitlement.granted(NSNumber(value: true)))
        #expect(!ApplePrivateCloudEntitlement.granted(NSNumber(value: false)))
        #expect(ApplePrivateCloudEntitlement.granted(["something"]))
    }

    /// Opportunistic: any real profile Xcode has cached on this Mac must parse to an
    /// `Entitlements` dictionary, whatever it grants. Skipped silently when there is none.
    @Test func realProfilesOnThisMacParse() throws {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/Xcode/UserData/Provisioning Profiles")
        guard
            let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return }
        let profiles = names.filter { $0.hasSuffix(".mobileprovision") }.prefix(3)
        for name in profiles {
            let data = try Data(contentsOf: directory.appendingPathComponent(name))
            let entitlements = ApplePrivateCloudEntitlement.entitlements(inProfile: data)
            #expect(entitlements != nil, Comment(rawValue: name))
            #expect(entitlements?["application-identifier"] is String, Comment(rawValue: name))
        }
    }

    private final class Marker {}
}
