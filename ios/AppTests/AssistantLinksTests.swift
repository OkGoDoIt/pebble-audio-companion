import Foundation
import Testing

// The links the Connect step opens are an external contract: Claude's prefilled Add custom
// connector dialog documents its values percent-encoded whole (`https%3A%2F%2F…`), the way the
// server's own Connect page writes the same link.

@Suite("assistant links")
struct AssistantLinksTests {
    @Test func claudesLinkEncodesTheWholeAddressAndReadsBack() throws {
        let url = try #require(AssistantLinks.claude(connector: "https://pebbleaudio.okgodoit.com/mcp"))

        #expect(url.absoluteString == "https://claude.ai/customize/connectors?modal=add-custom-connector"
            + "&connectorName=Pebble%20Audio&connectorUrl=https%3A%2F%2Fpebbleaudio.okgodoit.com%2Fmcp")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "connectorUrl" }?.value == "https://pebbleaudio.okgodoit.com/mcp")
        #expect(items.first { $0.name == "connectorName" }?.value == "Pebble Audio")
    }

    @Test func aPortAndAQueryInTheAddressSurvive() throws {
        let url = try #require(AssistantLinks.claude(connector: "https://archive.example:8443/mcp?x=1&y=2"))

        #expect(url.absoluteString.hasSuffix("connectorUrl=https%3A%2F%2Farchive.example%3A8443%2Fmcp%3Fx%3D1%26y%3D2"))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "connectorUrl" }?.value == "https://archive.example:8443/mcp?x=1&y=2")
    }
}
