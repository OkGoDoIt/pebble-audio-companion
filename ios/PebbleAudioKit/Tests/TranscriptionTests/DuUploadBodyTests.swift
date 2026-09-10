import AudioCodec
import Foundation
import Testing

@testable import Transcription

// Stream DU. Three separate claims, kept in one suite because they are all about what leaves the
// phone:
//   1. the segment audio goes out as FLAC, and the bytes still decode to the same samples;
//   2. the upload request states a network policy, and it defaults to Wi-Fi only;
//   3. Soniox's per-token confidence is decoded and carried into the stored turns.

@Suite struct DuUploadBodyTests {
    private static let rate = 16_000

    /// A couple of seconds of deterministic 16 kHz mono PCM16 with enough structure that FLAC has
    /// something to predict (a constant buffer compresses to almost nothing and would make the
    /// size assertions meaningless).
    private static func pcm(seconds: Double = 2) -> Data {
        let samples = Int(Double(rate) * seconds)
        var out = Data(capacity: samples * 2)
        var state: UInt32 = 0x1234_5678
        for i in 0..<samples {
            state = state &* 1_664_525 &+ 1_013_904_223
            let tone = Int(3_000 * sin(Double(i) * 0.05))
            let value = Int16(clamping: tone + Int(Int16(truncatingIfNeeded: state >> 20)))
            out.append(UInt8(truncatingIfNeeded: value))
            out.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        return out
    }

    // MARK: - 1. The body is FLAC

    @Test func sonioxBackgroundUploadSendsFlacThatDecodesToTheSameSamples() async throws {
        let pcm = Self.pcm()
        let wav = PcmWav.encodeMono16(pcm: pcm, sampleRateHz: Self.rate)
        let provider = SonioxTranscriptionProvider(
            transport: FakeHttpTransport { _ in throw AssertionError("no requests expected") },
            apiKey: { "test-key" },
            cloudConsent: { true }
        )

        // PT moved container choice out of the provider and onto the ladder
        // (`CloudUploadFormats`), so the FLAC rung is now built by the caller and handed
        // over; what this asserts — the bytes on the wire decode to the identical samples — is
        // unchanged.
        let body = CloudAudioBody.encode(wav: wav, sampleRateHz: Self.rate, format: .flac)
        let plan = try #require(await provider.uploadPlan(audio: body, sampleRateHz: Self.rate))

        #expect(plan.file.filename == "segment.flac")
        #expect(plan.file.contentType == "audio/flac")
        #expect(plan.file.bytes.prefix(4).elementsEqual("fLaC".utf8))
        // The point of the whole change: fewer bytes, identical audio.
        #expect(plan.file.bytes.count < wav.count)
        #expect(
            try PcmFlac.decodeToPcmMono16(flac: plan.file.bytes, sampleRateHz: Self.rate) == pcm)
    }

    @Test func openAiBackgroundUploadSendsFlacThatDecodesToTheSameSamples() async throws {
        let pcm = Self.pcm()
        let wav = PcmWav.encodeMono16(pcm: pcm, sampleRateHz: Self.rate)
        let provider = OpenAiTranscriptionProvider(
            transport: FakeHttpTransport { _ in throw AssertionError("no requests expected") },
            apiKey: { "test-key" },
            cloudConsent: { true }
        )

        let body = CloudAudioBody.encode(wav: wav, sampleRateHz: Self.rate, format: .flac)
        let plan = try #require(await provider.uploadPlan(audio: body, sampleRateHz: Self.rate))

        #expect(plan.file.filename == "segment.flac")
        #expect(plan.file.contentType == "audio/flac")
        #expect(
            try PcmFlac.decodeToPcmMono16(flac: plan.file.bytes, sampleRateHz: Self.rate) == pcm)
    }

    @Test func sonioxSynchronousUploadAlsoSendsFlac() async throws {
        let transport = FakeHttpTransport { request in
            let path = URL(string: request.url)?.path ?? ""
            switch (request.method, path) {
            case ("POST", "/v1/files"): return jsonResponse(#"{"id":"file-1"}"#)
            case ("POST", "/v1/transcriptions"): return jsonResponse(#"{"id":"tr-1"}"#)
            case ("GET", "/v1/transcriptions/tr-1"):
                return jsonResponse(#"{"id":"tr-1","status":"completed"}"#)
            case ("GET", "/v1/transcriptions/tr-1/transcript"):
                return jsonResponse(#"{"text":"hi","tokens":[{"text":"hi","start_ms":0,"end_ms":9}]}"#)
            case ("DELETE", _): return HttpTransportResponse(status: 204, text: "")
            default: throw AssertionError("unexpected \(request.method) \(path)")
            }
        }
        let provider = SonioxTranscriptionProvider(
            transport: transport, apiKey: { "k" }, cloudConsent: { true },
            pollIntervalMs: 1, sleep: { _ in })

        _ = try await provider.transcribe(
            pcmChunks: pcmStream([Self.pcm(seconds: 0.5)]), sampleRateHz: Self.rate)

        let upload = try #require(transport.requests.first)
        let head = String(decoding: (upload.body ?? Data()).prefix(400), as: UTF8.self)
        #expect(head.contains("filename=\"segment.flac\""))
        #expect(head.contains("Content-Type: audio/flac"))
    }

    @Test func theFormatIsAPerProviderConstant() {
        // A constant per provider, established by measurement against both production endpoints
        // (2026-09-08) and changed by a commit, not by a phone. It was briefly a runtime ladder
        // with a learned downgrade; that mechanism misread a billing outage as a container
        // rejection and durably retired Ogg Speex, so the decision moved back into the source.
        // See `CloudUploadFormats`.
        #expect(SonioxTranscriptionProvider.uploadFormat == .oggSpeex)
        #expect(OpenAiTranscriptionProvider.uploadFormat == .oggSpeex)
        // The synchronous path is handed decoded PCM and so can never package frames.
        #expect(SonioxTranscriptionProvider.pcmFormat == .flac)
        #expect(OpenAiTranscriptionProvider.pcmFormat == .flac)
        #expect(CloudAudioFormat.wav.contentType == "audio/wav")
        #expect(CloudAudioFormat.flac.contentType == "audio/flac")
        #expect(CloudAudioFormat.oggSpeex.contentType == "audio/ogg")
    }

    // MARK: - 2. The upload states a network policy

    @Test func uploadsAreWifiOnlyByDefault() {
        let uploader = URLSessionBackgroundUploader(sessionIdentifier: "test.\(UUID().uuidString)")
        #expect(uploader.currentNetworkPolicy == .wifiOnly)

        let request = uploader.uploadRequest(
            for: CloudUploadRequest(
                jobId: "seg-1", url: "https://example.invalid/v1/files",
                bodyFilePath: "/dev/null"))

        // All three, because all three default to `true` on `URLRequest` and any one left unset
        // would let ~40 MB/day out over the network it names.
        #expect(request?.allowsCellularAccess == false)
        #expect(request?.allowsExpensiveNetworkAccess == false)
        #expect(request?.allowsConstrainedNetworkAccess == false)
    }

    @Test func choosingAnyNetworkLetsCellularThrough() {
        let uploader = URLSessionBackgroundUploader(
            sessionIdentifier: "test.\(UUID().uuidString)", networkPolicy: { .anyNetwork })

        let request = uploader.uploadRequest(
            for: CloudUploadRequest(
                jobId: "seg-1", url: "https://example.invalid/v1/files", bodyFilePath: "/dev/null"))

        #expect(request?.allowsCellularAccess == true)
        #expect(request?.allowsExpensiveNetworkAccess == true)
        #expect(request?.allowsConstrainedNetworkAccess == true)
    }

    @Test func thePolicyIsReReadPerRequestSoASettingChangeTakesEffectImmediately() {
        // A background `URLSession` cannot be reconfigured once created, so the policy CANNOT
        // live on the session: if it did, "use cellular too" would need an app reinstall.
        let choice = PolicyBox(.wifiOnly)
        let uploader = URLSessionBackgroundUploader(sessionIdentifier: "test.\(UUID().uuidString)")
        uploader.setNetworkPolicy { choice.value }

        let job = CloudUploadRequest(
            jobId: "seg-1", url: "https://example.invalid/v1/files", bodyFilePath: "/dev/null")
        #expect(uploader.uploadRequest(for: job)?.allowsCellularAccess == false)

        choice.value = .anyNetwork

        #expect(uploader.uploadRequest(for: job)?.allowsCellularAccess == true)
    }

    @Test func headersAndMethodSurviveThePolicyStamp() {
        let uploader = URLSessionBackgroundUploader(sessionIdentifier: "test.\(UUID().uuidString)")
        let request = uploader.uploadRequest(
            for: CloudUploadRequest(
                jobId: "seg-1",
                url: "https://example.invalid/v1/files",
                headers: ["Authorization": "Bearer k", "Content-Type": "multipart/form-data"],
                bodyFilePath: "/dev/null"))

        #expect(request?.httpMethod == "POST")
        #expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer k")
        #expect(request?.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data")
    }

    // MARK: - 3. Soniox confidence is collected

    @Test func perTokenConfidenceIsDecodedAndSummarisedPerTurn() throws {
        let json = """
            {"text":"hello there general",
             "tokens":[
               {"text":"hello ","start_ms":0,"end_ms":300,"speaker":"1","confidence":0.98},
               {"text":"there ","start_ms":300,"end_ms":600,"speaker":"1","confidence":0.90},
               {"text":"general","start_ms":700,"end_ms":900,"speaker":"2","confidence":0.42}
             ]}
            """
        let transcript = try JSONDecoder().decode(
            SonioxTranscriptionProvider.SonioxTranscript.self, from: Data(json.utf8))
        let tokens = try #require(transcript.tokens)

        #expect(tokens.map(\.confidence) == [0.98, 0.90, 0.42])

        let provider = SonioxTranscriptionProvider(
            transport: FakeHttpTransport { _ in throw AssertionError("unused") },
            apiKey: { "k" }, cloudConsent: { true }, diarizationEnabled: { true })
        let segments = provider.groupIntoSegments(tokens)

        #expect(segments.count == 2)
        // Mean and floor over the turn's own tokens, rounded to four decimals.
        #expect(segments[0].confidence == 0.94)
        #expect(segments[0].minConfidence == 0.9)
        #expect(segments[1].confidence == 0.42)
        #expect(segments[1].minConfidence == 0.42)
    }

    @Test func aResponseWithoutConfidenceLeavesItNilRatherThanZero() throws {
        // Zero would read as "the provider was certain this is wrong", which is a different and
        // much stronger claim than "the provider did not say".
        let json = #"{"text":"hi","tokens":[{"text":"hi","start_ms":0,"end_ms":100}]}"#
        let transcript = try JSONDecoder().decode(
            SonioxTranscriptionProvider.SonioxTranscript.self, from: Data(json.utf8))
        let provider = SonioxTranscriptionProvider(
            transport: FakeHttpTransport { _ in throw AssertionError("unused") },
            apiKey: { "k" }, cloudConsent: { true })

        let segments = provider.groupIntoSegments(try #require(transcript.tokens))

        #expect(segments.count == 1)
        #expect(segments[0].confidence == nil)
        #expect(segments[0].minConfidence == nil)
    }

    @Test func realtimeTokensCarryConfidenceIntoSpeakerTurns() throws {
        let frame = """
            {"tokens":[
              {"text":"hello ","is_final":true,"speaker":"1","start_ms":0,"end_ms":300,"confidence":0.8},
              {"text":"there","is_final":true,"speaker":"1","start_ms":300,"end_ms":600,"confidence":0.6}
            ]}
            """
        struct Frame: Decodable { var tokens: [SonioxRtToken] }
        let tokens = try JSONDecoder().decode(Frame.self, from: Data(frame.utf8)).tokens
        #expect(tokens.map(\.confidence) == [0.8, 0.6])

        let update = SonioxRealtimeAccumulator(diarization: true)
            .accept(tokens: tokens, finished: true)

        #expect(update.segments.count == 1)
        #expect(update.segments[0].confidence == 0.7)
        #expect(update.segments[0].minConfidence == 0.6)
    }

    // MARK: - 3b. Storing it needs no migration

    @Test func confidenceIsAdditiveOnDiskInBothDirections() throws {
        // Forward: a turn with no confidence must not grow two `null` keys in 591 existing
        // transcript files. `TranscriptStore.kt` reads with `ignoreUnknownKeys = true`, so the
        // reverse direction is safe too.
        let plain = TranscriptSegment(text: "hi", startMs: 0, endMs: 10, speaker: "1")
        let encoded = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        #expect(!encoded.contains("confidence"))

        // Backward: a file written before this change still decodes, with nil confidence.
        let legacy = #"{"text":"hi","startMs":0,"endMs":10,"speaker":"1"}"#
        let decoded = try JSONDecoder().decode(TranscriptSegment.self, from: Data(legacy.utf8))
        #expect(decoded.confidence == nil)
        #expect(decoded.minConfidence == nil)
        #expect(decoded.text == "hi")

        // And a turn that HAS it round-trips.
        let scored = TranscriptSegment(
            text: "hi", startMs: 0, endMs: 10, confidence: 0.5, minConfidence: 0.25)
        let reloaded = try JSONDecoder().decode(
            TranscriptSegment.self, from: try JSONEncoder().encode(scored))
        #expect(reloaded == scored)
    }
}

/// Mutable, `Sendable` holder so a test can change the user's choice between two requests.
private final class PolicyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: CloudUploadNetwork
    init(_ value: CloudUploadNetwork) { stored = value }
    var value: CloudUploadNetwork {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
