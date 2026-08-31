import Foundation

// Port of `core/transcription/.../CloudUpload.kt`.

/// A pre-assembled HTTP upload to run on a suspension-proof background transport (iOS background
/// `URLSession`). The body is already on disk so the platform can keep uploading it while the app
/// is suspended and hand back the result on relaunch.
public struct CloudUploadRequest: Sendable, Equatable {
    /// Stable id used to correlate the outcome back to a job (the segment id for these uploads).
    public let jobId: String
    public let url: String
    public let method: String
    public let headers: [String: String]
    /// Path to the already-assembled request body on disk.
    public let bodyFilePath: String

    public init(
        jobId: String,
        url: String,
        method: String = "POST",
        headers: [String: String] = [:],
        bodyFilePath: String
    ) {
        self.jobId = jobId
        self.url = url
        self.method = method
        self.headers = headers
        self.bodyFilePath = bodyFilePath
    }
}

/// Terminal result of a `CloudUploadRequest`.
public struct CloudUploadOutcome: Sendable, Equatable {
    public let jobId: String
    /// HTTP status, or 0 on a transport error (no response).
    public let httpStatus: Int
    public let responseBody: String
    /// Non-nil when the upload failed at the transport layer (no HTTP response).
    public let error: String?

    public init(jobId: String, httpStatus: Int, responseBody: String = "", error: String? = nil) {
        self.jobId = jobId
        self.httpStatus = httpStatus
        self.responseBody = responseBody
        self.error = error
    }

    public var isSuccess: Bool { error == nil && (200..<300).contains(httpStatus) }
}

/// Suspension-proof HTTP upload transport. On iOS this is a background `URLSession` that keeps
/// uploading while the app is suspended and relaunches the app on completion. Implementations
/// are durable across process death.
public protocol BackgroundUploader: Sendable {
    /// Queues `request` for background upload. Safe to call again for an already-queued job id.
    func enqueue(_ request: CloudUploadRequest) async

    /// Outcomes as uploads finish — including ones that completed while the app was suspended.
    /// Single-consumer: the upload coordinator's `start()` is the consumer.
    var outcomes: AsyncStream<CloudUploadOutcome> { get }

    /// Re-attach to in-flight uploads after a relaunch and replay completed-while-dead outcomes.
    func reconcile() async

    /// Job ids the transport still considers in flight, so the coordinator can reconcile state.
    func inFlightJobIds() async -> Set<String>
}
