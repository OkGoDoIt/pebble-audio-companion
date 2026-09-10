import AudioCodec
import Foundation

// Port of `core/transcription/.../CloudUploadCapable.kt`.

/// Provider-side knowledge for driving a background (suspension-proof) upload. Keeping this on
/// the provider lets the upload coordinator stay completely provider-agnostic: it only assembles
/// the body, hands it to the transport, and asks the provider what a response means.
///
/// Two shapes are supported:
///  - single-shot (OpenAI): the upload's HTTP response IS the transcript -> `.done`.
///  - upload-then-control-plane (Soniox): the upload returns a file handle; the small
///    create/poll/fetch control plane runs later in an awake window -> `.needsControlPlane`.
public protocol CloudUploadCapable: Sendable {
    /// The container this provider is sent, decided once by measurement rather than at runtime.
    /// See `CloudUploadFormats`.
    var uploadFormat: CloudAudioFormat { get }

    /// The initial background upload (endpoint, headers, multipart parts) for an already-packaged
    /// body, or nil if this provider cannot currently background-upload (e.g. no key / consent /
    /// too large).
    ///
    /// The body arrives ENCODED rather than as PCM: choosing the container is a policy decision
    /// that outlived being a per-provider constant, and re-deriving it here would mean every
    /// provider re-implementing the same ladder.
    func uploadPlan(audio: CloudAudioBody, sampleRateHz: Int) async -> CloudUploadPlan?

    /// Interprets the upload's HTTP response: a finished transcript, or a follow-up step.
    func onUploadResponse(httpStatus: Int, body: String) async throws -> CloudUploadStep

    /// Runs the remaining control plane (e.g. Soniox create/poll/fetch) from `controlState`.
    func completeControlPlane(controlState: String) async throws -> TranscriptionResult
}

/// Endpoint + headers + parts the coordinator assembles into a body file for the transport.
public struct CloudUploadPlan: Sendable {
    public let url: String
    public let headers: [String: String]
    public let textFields: [(String, String)]
    public let file: MultipartBody.FilePart

    public init(
        url: String,
        headers: [String: String] = [:],
        textFields: [(String, String)] = [],
        file: MultipartBody.FilePart
    ) {
        self.url = url
        self.headers = headers
        self.textFields = textFields
        self.file = file
    }
}

public enum CloudUploadStep: Sendable {
    /// The upload response already contains the transcript.
    case done(TranscriptionResult)

    /// A follow-up control plane is required; the value is opaque provider state (e.g. file id).
    case needsControlPlane(String)
}
