import AudioCodec
import Foundation
import Testing

@testable import Transcription

// Port of `core/transcription/src/jvmTest/.../OpenAiTranscriptionProviderTest.kt` — all 6 cases,
// same names. The KMP tests faked HTTP with ktor's MockEngine; here the injected `HttpTransport`
// plays that role, so no test touches the network.

/// Hermetic `HttpTransport` fake (the MockEngine analogue): runs the handler, records every
/// request for assertions. Shared by the OpenAI and Soniox provider suites.
final class FakeHttpTransport: HttpTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [HttpTransportRequest] = []
    private let handler: @Sendable (HttpTransportRequest) async throws -> HttpTransportResponse

    init(handler: @escaping @Sendable (HttpTransportRequest) async throws -> HttpTransportResponse) {
        self.handler = handler
    }

    var requests: [HttpTransportRequest] {
        lock.withLock { recorded }
    }

    func execute(_ request: HttpTransportRequest) async throws -> HttpTransportResponse {
        lock.withLock { recorded.append(request) }
        return try await handler(request)
    }
}

/// Thread-safe call counter (the KMP tests' captured `var calls`).
final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }

    var count: Int { lock.withLock { value } }
}

func jsonResponse(_ content: String) -> HttpTransportResponse {
    HttpTransportResponse(status: 200, text: content)
}

@Suite struct OpenAiProviderTests {

    @Test func unavailableWithoutConsentOrKey() async throws {
        let transport = FakeHttpTransport { _ in
            throw AssertionError("provider should not issue requests without consent and an API key")
        }
        let provider = OpenAiTranscriptionProvider(
            transport: transport,
            apiKey: { "" },
            cloudConsent: { false }
        )

        #expect(await provider.isAvailable() == false)
        do {
            _ = try await provider.transcribe(
                pcmChunks: pcmStream([Data([1, 2])]), sampleRateHz: 16_000
            )
            Issue.record("expected ProviderUnavailable")
        } catch TranscriptionError.providerUnavailable {
            // expected
        }
    }

    @Test func uploadsWavMultipartAndParsesText() async throws {
        let transport = FakeHttpTransport { _ in
            jsonResponse(#"{"text":"hello watch"}"#)
        }
        let provider = OpenAiTranscriptionProvider(
            transport: transport,
            apiKey: { "test-key" },
            cloudConsent: { true },
            model: { "gpt-transcribe" }
        )

        let result = try await provider.transcribe(
            pcmChunks: pcmStream([Data(repeating: 1, count: 640)]), sampleRateHz: 16_000
        )

        #expect(result.text == "hello watch")
        #expect(result.providerId == "openai")
        let request = try #require(transport.requests.first)
        #expect(request.headers["Authorization"] == "Bearer test-key")
        // The body is multipart form data carrying a WAV file part.
        let body = try #require(request.body)
        let bodyText = String(decoding: body, as: UTF8.self)
        #expect(bodyText.contains("name=\"model\""))
        #expect(bodyText.contains("Content-Type: audio/wav"))
        #expect(bodyText.contains("RIFF"))
    }

    @Test func splitsLargePcmIntoMultipleUploads() async throws {
        let calls = CallCounter()
        let transport = FakeHttpTransport { _ in
            jsonResponse("{\"text\":\"part \(calls.next())\"}")
        }
        let provider = OpenAiTranscriptionProvider(
            transport: transport,
            apiKey: { "test-key" },
            cloudConsent: { true },
            maxUploadBytes: 100
        )

        let result = try await provider.transcribe(
            pcmChunks: pcmStream([Data(repeating: 7, count: 120)]), sampleRateHz: 16_000
        )

        #expect(calls.count == 3)
        #expect(result.text == "part 1\npart 2\npart 3")
    }

    @Test func parsesWhisperVerboseTimestamps() async throws {
        let transport = FakeHttpTransport { _ in
            jsonResponse(
                """
                {
                  "text": "hello watch",
                  "segments": [
                    {"start": 1.25, "end": 2.5, "text": "hello watch"}
                  ],
                  "words": [
                    {"start": 1.25, "end": 1.7, "word": "hello"},
                    {"start": 1.8, "end": 2.5, "word": "watch"}
                  ]
                }
                """
            )
        }
        let provider = OpenAiTranscriptionProvider(
            transport: transport,
            apiKey: { "test-key" },
            cloudConsent: { true },
            model: { "whisper-1" }
        )

        let result = try await provider.transcribe(
            pcmChunks: pcmStream([Data(repeating: 1, count: 640)]), sampleRateHz: 16_000
        )

        #expect(result.text == "hello watch")
        #expect(result.segments == [TranscriptSegment(text: "hello watch", startMs: 1_250, endMs: 2_500)])
        #expect(
            result.words == [
                TranscriptWord(text: "hello", startMs: 1_250, endMs: 1_700),
                TranscriptWord(text: "watch", startMs: 1_800, endMs: 2_500),
            ]
        )
    }

    @Test func diarizationUsesDiarizeModelAndParsesSpeakers() async throws {
        let transport = FakeHttpTransport { _ in
            jsonResponse(
                """
                {
                  "text": "hi there",
                  "segments": [
                    {"type":"transcript.text.segment","id":"s0","start":0.0,"end":1.0,
                     "text":"hi","speaker":"agent"},
                    {"type":"transcript.text.segment","id":"s1","start":1.0,"end":2.0,
                     "text":"there","speaker":"customer"}
                  ]
                }
                """
            )
        }
        let provider = OpenAiTranscriptionProvider(
            transport: transport,
            apiKey: { "test-key" },
            cloudConsent: { true },
            model: { "gpt-transcribe" }, // overridden by diarization
            diarizationEnabled: { true }
        )

        let result = try await provider.transcribe(
            pcmChunks: pcmStream([Data(repeating: 1, count: 640)]), sampleRateHz: 16_000
        )

        #expect(result.text == "hi there")
        #expect(result.modelUsed == "gpt-4o-transcribe-diarize")
        #expect(result.segments.map(\.speaker) == ["agent", "customer"])
        #expect(result.segments.first?.startMs == 0)
        #expect(result.segments.last?.endMs == 2_000)
    }

    @Test func wavEncoderWritesExpectedHeader() throws {
        let wav = PcmWav.encodeMono16(pcm: Data([1, 2, 3, 4]), sampleRateHz: 16_000)

        #expect(String(decoding: wav.subdata(in: 0..<4), as: UTF8.self) == "RIFF")
        #expect(String(decoding: wav.subdata(in: 8..<12), as: UTF8.self) == "WAVE")
        #expect(String(decoding: wav.subdata(in: 12..<16), as: UTF8.self) == "fmt ")
        #expect(String(decoding: wav.subdata(in: 36..<40), as: UTF8.self) == "data")
        #expect(wav.count == 48)
        #expect(wav.subdata(in: 44..<48) == Data([1, 2, 3, 4]))
    }
}
