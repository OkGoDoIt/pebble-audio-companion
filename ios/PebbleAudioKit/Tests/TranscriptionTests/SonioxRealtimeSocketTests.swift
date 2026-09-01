import Foundation
import Testing

@testable import Transcription

// The socket half of the Soniox realtime provider: staying connected through a silence, and
// saying something classifiable when the connection ends.
//
// Why this file exists: Soniox closes a realtime socket that has heard neither audio nor a
// keepalive for more than 20 seconds, answering
// `{"error_code": 408, "error_message": "Request timeout."}` — verified against the live API.
// Our audio is voice-activity gated on the WATCH, so a quiet room sends nothing at all; real
// recordings in the field routinely contain minute-long stretches with no frames. Without a
// keepalive the live socket cannot survive an ordinary pause in a conversation.

/// A socket that records what we sent and never answers — a server with nothing to say, which
/// is exactly the situation during a silence.
final class SilentRecordingWebSocket: WebSocketConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var _texts: [String] = []
    private var _dataFrames = 0

    var texts: [String] { lock.withLock { _texts } }
    var dataFrames: Int { lock.withLock { _dataFrames } }
    var keepaliveCount: Int {
        texts.filter { $0 == SonioxRealtimeProvider.keepaliveMessage }.count
    }

    func send(text: String) async throws { lock.withLock { _texts.append(text) } }
    func send(data: Data) async throws { lock.withLock { _dataFrames += 1 } }

    func receive() async throws -> WebSocketMessage {
        // Blocks until the session is torn down, like a real socket mid-silence.
        try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
        throw WebSocketClosedError()
    }

    func close() {}
}

struct FixedWebSocketConnector: WebSocketConnector {
    let socket: SilentRecordingWebSocket
    func connect(url: URL, headers: [String: String]) -> any WebSocketConnection { socket }
}

@Suite struct SonioxRealtimeSocketTests {

    @Test func keepaliveHoldsTheSocketOpenThroughSilence() async throws {
        let socket = SilentRecordingWebSocket()
        let provider = SonioxRealtimeProvider(
            connector: FixedWebSocketConnector(socket: socket),
            apiKey: { "test-key" },
            cloudConsent: { true },
            keepaliveIntervalMs: 20
        )

        // One frame of audio, then a silence that never ends: the watch's voice-activity gate
        // suppressing everything while the segment stays open.
        let pcm = AsyncThrowingStream<Data, Error> { continuation in
            continuation.yield(Data(repeating: 0, count: 640))
        }
        let session = Task {
            for try await _ in provider.transcribeStream(pcm: pcm, sampleRateHz: 16_000) {}
        }

        var seen = 0
        for _ in 0..<300 where seen < 2 {
            try await Task.sleep(nanoseconds: 20_000_000)
            seen = socket.keepaliveCount
        }
        // Snapshot BEFORE tearing down: cancelling ends the audio stream, which legitimately
        // flushes the end-of-audio frame. What is being asserted is the state mid-silence.
        let duringSilence = socket.texts
        session.cancel()
        _ = await session.result

        #expect(seen >= 2, "expected keepalives during the silence; sent: \(duringSilence)")
        // The config frame is still first, and end-of-audio (an empty text frame) has NOT been
        // sent: the segment is open, we are merely quiet.
        #expect(duringSilence.first?.contains(#""audio_format":"s16le""#) == true)
        #expect(!duringSilence.contains(""))
    }

    @Test func keepaliveOnlyFiresWhenSilentAndNeverAfterEndOfAudio() {
        let activity = SonioxSendActivity()
        // First tick after connecting: the config frame has just gone out, nothing is wrong yet.
        #expect(activity.shouldSendKeepalive() == false)
        // A whole tick with no audio — this is the silence the socket would otherwise die in.
        #expect(activity.shouldSendKeepalive() == true)

        activity.noteAudioSent()
        #expect(activity.shouldSendKeepalive() == false, "a talking user costs no extra frames")
        #expect(activity.shouldSendKeepalive() == true)

        // After the final flush the server is finishing up; a keepalive there would only race it.
        activity.noteEndOfAudio()
        #expect(activity.shouldSendKeepalive() == false)
        #expect(activity.shouldSendKeepalive() == false)
    }

    @Test func keepaliveIntervalLeavesMarginUnderSonioxDeadline() {
        // Worst case is two ticks (audio landing just after one), so the interval must be well
        // under half of Soniox's 20 s deadline.
        #expect(SonioxRealtimeProvider.keepaliveIntervalMs * 2 < 20_000)
        #expect(SonioxRealtimeProvider.keepaliveMessage == #"{"type":"keepalive"}"#)
    }

    @Test func serverErrorCodeSurvivesIntoTheSharedFailureVocabulary() {
        // The whole point of carrying `error_code`: "Request timeout." on its own is only
        // `providerTrouble` ("The provider had trouble on its side"), which is both vaguer and
        // wronger than "it took too long to answer".
        let timeout = SonioxRealtimeProvider.realtimeErrorText(code: 408, text: "Request timeout.")
        #expect(timeout.contains("(408)"))
        #expect(TranscriptionFailureKind.classify(timeout) == .timedOut)

        let badKey = SonioxRealtimeProvider.realtimeErrorText(code: 401, text: "Invalid API key.")
        #expect(TranscriptionFailureKind.classify(badKey) == .keyRejected)

        let busy = SonioxRealtimeProvider.realtimeErrorText(code: 429, text: "Too many requests.")
        #expect(TranscriptionFailureKind.classify(busy) == .rateLimited)

        // No code: still classified, just less precisely. Never raw prose.
        let bare = SonioxRealtimeProvider.realtimeErrorText(code: nil, text: "Something happened.")
        #expect(!bare.contains("("))
        #expect(TranscriptionFailureKind.classify(bare) == .providerTrouble)
    }

    @Test func errorFrameIsReadEvenWhenAFieldArrivesInAnOddShape() throws {
        // A synthesized decoder would throw away the whole frame — error prose included — if
        // `error_code` came back as a string, leaving the user a DecodingError in place of the
        // real reason.
        let json = #"{"error_code":"408","error_message":"Request timeout."}"#
        let text = try SonioxRealtimeProvider.errorTextForTesting(json: json)
        #expect(text == "Soniox realtime error (408): Request timeout.")
        #expect(TranscriptionFailureKind.classify(text) == .timedOut)
    }

    @Test func abortedConnectionIsDistinguishedFromAnUnusableNetwork() {
        // POSIX 53 is what iOS raises when it tears a socket down under a suspending app; it is
        // also an ordinary Wi-Fi↔cellular handover. Neither says anything about the provider.
        for code in [32, 53, 54, 57] {
            #expect(
                URLSessionWebSocketConnection.isConnectionAbort(
                    NSError(domain: NSPOSIXErrorDomain, code: code)),
                "POSIX \(code) should read as an interrupted connection")
        }
        #expect(
            URLSessionWebSocketConnection.isConnectionAbort(
                NSError(domain: NSURLErrorDomain, code: URLError.networkConnectionLost.rawValue)))

        // "There is no network here" IS worth reporting, and the vocabulary has `noConnection`
        // for it — so it must NOT be swallowed as an interruption.
        for code in [
            URLError.notConnectedToInternet.rawValue,
            URLError.cannotConnectToHost.rawValue,
            URLError.timedOut.rawValue,
        ] {
            #expect(
                !URLSessionWebSocketConnection.isConnectionAbort(
                    NSError(domain: NSURLErrorDomain, code: code)),
                "URL error \(code) should stay a reportable failure")
        }
    }
}
