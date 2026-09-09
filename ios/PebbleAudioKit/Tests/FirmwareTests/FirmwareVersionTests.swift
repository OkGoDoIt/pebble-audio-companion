import Foundation
import Testing

@testable import Firmware

// Ordering firmware versions is the one piece of pure arithmetic in this feature that, if wrong,
// installs the wrong build. These pin the cases that a naive implementation gets wrong.

@Suite("Firmware version ordering")
struct FirmwareVersionTests {

    private func v(_ text: String) throws -> FirmwareVersion {
        try #require(FirmwareVersion(text), "expected '\(text)' to parse")
    }

    @Test("The string-compare trap: 4.10 is newer than 4.9")
    func numericNotLexical() throws {
        #expect(try v("4.9") < v("4.10"))
        #expect(try v("v4.9.9") < v("v4.10.0"))
        // The one that made this type exist: as text, "4.10" sorts BEFORE "4.9".
        #expect("4.10" < "4.9")
    }

    @Test("A `v` prefix and trailing zeros are not part of identity")
    func normalisation() throws {
        #expect(try v("v4.36") == v("4.36.0"))
        #expect(try v("4.36") == v("4.36.0.0"))
        #expect(try v("V4.36.1") == v("4.36.1"))
        // Equal versions must hash equally or a Set/Dictionary of releases misbehaves.
        #expect(try Set([v("v4.36"), v("4.36.0")]).count == 1)
    }

    @Test("Missing components read as zero, so 4.36 is older than 4.36.1")
    func missingComponents() throws {
        #expect(try v("4.36") < v("4.36.1"))
        #expect(try v("4.36.1") > v("4.36"))
    }

    @Test("A prerelease sorts before the release it leads to")
    func prereleaseOrdering() throws {
        #expect(try v("4.37.0-rc.1") < v("4.37.0"))
        #expect(try v("4.37.0-rc.1") < v("4.37.0-rc.2"))
        #expect(try v("4.37.0-rc.2") < v("4.37.0-rc.10"))  // numeric identifiers, not text
        #expect(try v("4.37.0-alpha") < v("4.37.0-beta"))
        #expect(try v("4.36.9") < v("4.37.0-rc.1"))
    }

    @Test("Build metadata is significant — the branch suffix is often the only difference")
    func buildMetadataIsSignificant() throws {
        // Strict semver calls these equal, which would mean audio.4 is never offered after
        // audio.3. See the type's doc comment for why this project deviates.
        #expect(try v("4.36.1+audio.3") < v("4.36.1+audio.4"))
        #expect(try v("4.36.1") < v("4.36.1+audio.1"))
        #expect(try v("4.36.1+audio.3") != v("4.36.1"))
    }

    @Test("Unorderable text is nil, never a zero version")
    func rejectsUnorderable() {
        // A "0.0.0" fallback would make every release look like an upgrade over it.
        #expect(FirmwareVersion("latest") == nil)
        #expect(FirmwareVersion("") == nil)
        #expect(FirmwareVersion("v") == nil)
        #expect(FirmwareVersion("4.x") == nil)
        #expect(FirmwareVersion("4..1") == nil)
        #expect(FirmwareVersion("-1.0") == nil)
        #expect(FirmwareVersion("four") == nil)
    }

    @Test("Whitespace around a tag does not change it")
    func trimsWhitespace() throws {
        #expect(try v("  v4.36.1\n") == v("4.36.1"))
    }

    @Test("Ordering is total and consistent when a list is sorted")
    func sorts() throws {
        let sorted = try ["4.37.0", "4.9", "4.10", "4.37.0-rc.1", "4.36.1+audio.2", "4.36.1"]
            .map { try v($0) }
            .sorted()
            .map(\.raw)
        #expect(sorted == ["4.9", "4.10", "4.36.1", "4.36.1+audio.2", "4.37.0-rc.1", "4.37.0"])
    }
}
