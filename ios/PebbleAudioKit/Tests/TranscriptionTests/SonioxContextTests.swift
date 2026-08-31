import Foundation
import Testing

@testable import Transcription

// Port of `core/transcription/src/jvmTest/.../SonioxContextTest.kt` — both cases, same names.

@Suite struct SonioxContextTests {

    @Test func configJsonIncludesContextWhenProvided() throws {
        let provider = SonioxRealtimeProvider(
            connector: UnusedWebSocketConnector(),
            apiKey: { "key" },
            cloudConsent: { true },
            contextText: { "About me: Roger at Pebble" },
            contextTerms: { ["Pebble", "Sarah"] }
        )
        let json = provider.configJson(key: "key", sampleRateHz: 16_000)
        #expect(json.contains(#""context""#))
        #expect(json.contains("About me: Roger at Pebble"))
        #expect(json.contains("Pebble"))
    }

    @Test func buildSonioxContextJsonObjectOmitsWhenEmpty() throws {
        #expect(buildSonioxContextJsonObject(contextText: nil, contextTerms: []) == nil)
        let object = try #require(
            buildSonioxContextJsonObject(contextText: "notes", contextTerms: ["Term"])
        )
        #expect(object["text"] as? String == "notes")
    }
}
