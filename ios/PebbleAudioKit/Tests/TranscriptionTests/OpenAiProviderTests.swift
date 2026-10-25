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

    @Test func uploadsAudioMultipartAndParsesText() async throws {
        let transport = FakeHttpTransport { _ in
            jsonResponse(#"{"text":"hello watch"}"#)
        }
        let provider = OpenAiTranscriptionProvider(
            transport: transport,
            apiKey: { "test-key" },
            cloudConsent: { true },
            model: { "gpt-transcribe" }
        )

        // Half a second of audio. Long enough to clear `PcmFlac.minimumFrames`, so this asserts
        // the body a real segment produces rather than the short-chunk WAV fallback.
        let result = try await provider.transcribe(
            pcmChunks: pcmStream([Data(repeating: 1, count: 16_000)]), sampleRateHz: 16_000
        )

        #expect(result.text == "hello watch")
        #expect(result.providerId == "openai")
        let request = try #require(transport.requests.first)
        #expect(request.headers["Authorization"] == "Bearer test-key")
        // The body is multipart form data carrying the segment audio. FLAC since stream DU —
        // lossless, so the model sees the same samples, at ~31% of the bytes. This is the
        // SYNCHRONOUS path, which is handed decoded PCM and so tops out at FLAC; the background
        // path packages the watch's own Speex frames instead. See
        // `OpenAiTranscriptionProvider.pcmFormatLadder`, `PcmFlac` and `OggSpeex`.
        let body = try #require(request.body)
        let bodyText = String(decoding: body, as: UTF8.self)
        #expect(bodyText.contains("name=\"model\""))
        #expect(bodyText.contains("Content-Type: audio/flac"))
        #expect(bodyText.contains("filename=\"segment-0.flac\""))
        #expect(bodyText.contains("fLaC"))
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

    @Test func independentUploadsNeverShareSpeakerLabels() async throws {
        let transport = FakeHttpTransport { _ in
            jsonResponse(
                """
                {
                  "text": "yes again hello unclear",
                  "segments": [
                    {"start":0.0,"end":0.005,"text":"yes","speaker":"A"},
                    {"start":0.005,"end":0.01,"text":"again","speaker":"A"},
                    {"start":0.01,"end":0.015,"text":"hello","speaker":"B"},
                    {"start":0.015,"end":0.02,"text":"unclear"}
                  ]
                }
                """
            )
        }
        let provider = OpenAiTranscriptionProvider(
            transport: transport,
            apiKey: { "test-key" },
            cloudConsent: { true },
            diarizationEnabled: { true },
            maxUploadBytes: 100
        )

        // Each request can hold 56 PCM bytes = 28 ms at this test sample rate. The same
        // raw A/B labels in all three responses must not imply the same people across them.
        let result = try await provider.transcribe(
            pcmChunks: pcmStream([Data(repeating: 7, count: 168)]), sampleRateHz: 1_000
        )

        #expect(transport.requests.count == 3)
        #expect(result.segments.map(\.speaker) == [
            "1", "1", "2", nil, "3", "3", "4", nil, "5", "5", "6", nil,
        ])
        #expect(result.segments.map(\.startMs) == [
            0, 5, 10, 15, 28, 33, 38, 43, 56, 61, 66, 71,
        ])
        #expect(result.segments.map(\.text) == Array(
            repeating: ["yes", "again", "hello", "unclear"], count: 3).flatMap { $0 })

        // Stream delivery boundaries do not define requests or identities. Replaying the same
        // PCM in different-sized input buffers must produce exactly the same persisted result.
        let fragmented = try await provider.transcribe(
            pcmChunks: pcmStream([
                Data(repeating: 7, count: 30), Data(repeating: 7, count: 70),
                Data(repeating: 7, count: 68),
            ]), sampleRateHz: 1_000
        )
        #expect(fragmented == result)
    }

    @Test func chunkMergingPreservesUnlabeledWordTimings() async throws {
        let transport = FakeHttpTransport { _ in
            jsonResponse(
                """
                {
                  "text": "hello",
                  "segments": [{"start":0.0,"end":0.01,"text":"hello"}],
                  "words": [{"start":0.0,"end":0.01,"word":"hello"}]
                }
                """
            )
        }
        let provider = OpenAiTranscriptionProvider(
            transport: transport,
            apiKey: { "test-key" },
            cloudConsent: { true },
            model: { "whisper-1" },
            maxUploadBytes: 100
        )
        let result = try await provider.transcribe(
            pcmChunks: pcmStream([Data(repeating: 7, count: 112)]), sampleRateHz: 1_000
        )

        #expect(transport.requests.count == 2)
        #expect(result.segments.map(\.speaker) == [nil, nil])
        #expect(result.words == [
            TranscriptWord(text: "hello", startMs: 0, endMs: 10),
            TranscriptWord(text: "hello", startMs: 28, endMs: 38),
        ])
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
