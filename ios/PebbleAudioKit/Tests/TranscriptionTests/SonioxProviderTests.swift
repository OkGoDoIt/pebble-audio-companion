import Foundation
import Testing

@testable import Transcription

// Port of `core/transcription/src/jvmTest/.../SonioxTranscriptionProviderTest.kt` — all 4 cases,
// same names.

/// WebSocket connector that must never be used (the MockEngine `error("no requests expected")`
/// analogue for the realtime provider's config-only tests).
struct UnusedWebSocketConnector: WebSocketConnector {
    func connect(url: URL, headers: [String: String]) -> any WebSocketConnection {
        fatalError("no sockets expected in unit tests")
    }
}

@Suite struct SonioxProviderTests {

    private final class ServerState: @unchecked Sendable {
        private let lock = NSLock()
        private var _createBody: String?
        private var _pollCount = 0
        private var _deletes: [String] = []

        var createBody: String? { lock.withLock { _createBody } }
        var pollCount: Int { lock.withLock { _pollCount } }
        var deletes: [String] { lock.withLock { _deletes } }

        func recordCreate(_ body: String?) {
            lock.withLock { _createBody = body }
        }

        func nextPoll() -> Int {
            lock.withLock {
                _pollCount += 1
                return _pollCount
            }
        }

        func recordDelete(_ path: String) {
            lock.withLock { _deletes.append(path) }
        }
    }

    @Test func realtimeConfigUsesSonioxRawPcmFormat() throws {
        // Regression guard: Soniox expects "s16le" for raw PCM. "pcm_s16le" makes the server
        // reject the live stream, which silently fell back to local transcription.
        let provider = SonioxRealtimeProvider(
            connector: UnusedWebSocketConnector(),
            apiKey: { "test-key" },
            cloudConsent: { true }
        )
        let config = provider.configJson(key: "test-key", sampleRateHz: 16_000)
        #expect(config.contains(#""audio_format":"s16le""#), "config was: \(config)")
        #expect(!config.contains("pcm_s16le"), "must not use the invalid pcm_s16le token")
        #expect(config.contains(#""sample_rate":16000"#))
    }

    @Test func unavailableWithoutConsentOrKey() async throws {
        let provider = SonioxTranscriptionProvider(
            transport: FakeHttpTransport { _ in
                throw AssertionError("no requests expected without consent/key")
            },
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

    @Test func runsFullFlowGroupsSpeakersAndCleansUp() async throws {
        let state = ServerState()
        let transport = FakeHttpTransport { request in
            let path = URL(string: request.url)?.path ?? ""
            switch (request.method, path) {
            case ("POST", "/v1/files"):
                return jsonResponse(#"{"id":"file-1","filename":"segment.wav","size":10}"#)

            case ("POST", "/v1/transcriptions"):
                state.recordCreate(request.body.map { String(decoding: $0, as: UTF8.self) })
                return jsonResponse(#"{"id":"tr-1","status":"queued"}"#)

            case ("GET", "/v1/transcriptions/tr-1"):
                let status = state.nextPoll() < 2 ? "processing" : "completed"
                return jsonResponse("{\"id\":\"tr-1\",\"status\":\"\(status)\"}")

            case ("GET", "/v1/transcriptions/tr-1/transcript"):
                return jsonResponse(
                    """
                    {"id":"tr-1","text":"hello there general",
                     "tokens":[
                       {"text":"hello ","start_ms":0,"end_ms":300,"speaker":"1"},
                       {"text":"there ","start_ms":300,"end_ms":600,"speaker":"1"},
                       {"text":"general","start_ms":1200,"end_ms":1500,"speaker":"2"}
                     ]}
                    """
                )

            case ("DELETE", _):
                state.recordDelete(path)
                return HttpTransportResponse(status: 204, text: "")

            default:
                throw AssertionError("unexpected \(request.method) \(path)")
            }
        }
        let provider = SonioxTranscriptionProvider(
            transport: transport,
            apiKey: { "test-key" },
            cloudConsent: { true },
            diarizationEnabled: { true },
            pollIntervalMs: 1,
            sleep: { _ in }
        )

        let result = try await provider.transcribe(
            pcmChunks: pcmStream([Data(repeating: 1, count: 640)]), sampleRateHz: 16_000
        )

        #expect(result.text == "hello there general")
        #expect(result.providerId == "soniox")
        // Speaker change -> two segments.
        #expect(result.segments.count == 2)
        #expect(result.segments[0].speaker == "1")
        #expect(result.segments[0].text == "hello there")
        #expect(result.segments[1].speaker == "2")
        #expect(result.segments[1].text == "general")
        #expect(state.pollCount >= 2, "expected to poll until completed")
        #expect(state.createBody?.contains(#""enable_speaker_diarization":true"#) == true)
        // Best-effort cleanup of both the transcription and the file.
        #expect(state.deletes.contains("/v1/transcriptions/tr-1"))
        #expect(state.deletes.contains("/v1/files/file-1"))
    }

    @Test func errorStatusFailsRetryable() async throws {
        let transport = FakeHttpTransport { request in
            let path = URL(string: request.url)?.path ?? ""
            switch (request.method, path) {
            case ("POST", "/v1/files"):
                return jsonResponse(#"{"id":"file-1"}"#)
            case ("POST", "/v1/transcriptions"):
                return jsonResponse(#"{"id":"tr-1","status":"queued"}"#)
            case ("GET", "/v1/transcriptions/tr-1"):
                return jsonResponse(#"{"id":"tr-1","status":"error","error_message":"bad audio"}"#)
            case ("DELETE", _):
                return HttpTransportResponse(status: 204, text: "")
            default:
                throw AssertionError("unexpected \(request.method) \(path)")
            }
        }
        let provider = SonioxTranscriptionProvider(
            transport: transport,
            apiKey: { "k" },
            cloudConsent: { true },
            pollIntervalMs: 1,
            sleep: { _ in }
        )

        do {
            _ = try await provider.transcribe(
                pcmChunks: pcmStream([Data(repeating: 1, count: 640)]), sampleRateHz: 16_000
            )
            Issue.record("expected TranscriptionFailed")
        } catch TranscriptionError.transcriptionFailed(let message, _) {
            #expect(message.contains("bad audio"))
        }
    }
}
