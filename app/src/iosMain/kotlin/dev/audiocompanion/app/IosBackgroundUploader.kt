@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class, kotlinx.cinterop.BetaInteropApi::class)

package dev.audiocompanion.app

import dev.audiocompanion.transcription.BackgroundUploader
import dev.audiocompanion.transcription.CloudUploadOutcome
import dev.audiocompanion.transcription.CloudUploadRequest
import kotlinx.cinterop.ObjCSignatureOverride
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.suspendCancellableCoroutine
import platform.Foundation.NSData
import platform.Foundation.NSError
import platform.Foundation.NSHTTPURLResponse
import platform.Foundation.NSMutableData
import platform.Foundation.NSMutableURLRequest
import platform.Foundation.NSString
import platform.Foundation.NSURL
import platform.Foundation.NSURLSession
import platform.Foundation.NSURLSessionConfiguration
import platform.Foundation.NSURLSessionDataDelegateProtocol
import platform.Foundation.NSURLSessionDataTask
import platform.Foundation.NSURLSessionTask
import platform.Foundation.NSURLSessionTaskStateRunning
import platform.Foundation.NSURLSessionTaskStateSuspended
import platform.Foundation.NSUTF8StringEncoding
import platform.Foundation.appendData
import platform.Foundation.create
import platform.Foundation.setHTTPMethod
import platform.Foundation.setValue
import platform.darwin.NSObject
import kotlin.coroutines.resume

/**
 * iOS background-upload transport for cloud transcription (plan point 7 / Phase B). Uses a
 * background [NSURLSession] so uploads keep running while the app is suspended; iOS relaunches the
 * app on completion and re-delivers outcomes once [reconcile] recreates the session by identifier.
 *
 * The request body is uploaded from a file (background sessions require file uploads). Each task's
 * `taskDescription` carries the job id so outcomes correlate back to the segment across relaunches.
 */
class IosBackgroundUploader(
    private val sessionIdentifier: String = SESSION_IDENTIFIER,
) : BackgroundUploader {
    private val _outcomes = MutableSharedFlow<CloudUploadOutcome>(extraBufferCapacity = 64)
    override val outcomes: Flow<CloudUploadOutcome> = _outcomes.asSharedFlow()

    private val responseData = mutableMapOf<Long, NSMutableData>()

    /** Set by the AppDelegate from handleEventsForBackgroundURLSession; called when events drain. */
    var backgroundEventsCompletion: (() -> Unit)? = null

    private val delegate = Delegate()
    private val session: NSURLSession by lazy {
        val config =
            NSURLSessionConfiguration.backgroundSessionConfigurationWithIdentifier(sessionIdentifier)
        NSURLSession.sessionWithConfiguration(config, delegate, delegateQueue = null)
    }

    override suspend fun enqueue(request: CloudUploadRequest) {
        val url = NSURL.URLWithString(request.url) ?: return
        val req = NSMutableURLRequest(uRL = url)
        req.setHTTPMethod(request.method)
        request.headers.forEach { (key, value) -> req.setValue(value, forHTTPHeaderField = key) }
        val fileUrl = NSURL.fileURLWithPath(request.bodyFilePath)
        val task = session.uploadTaskWithRequest(req, fromFile = fileUrl)
        task.taskDescription = request.jobId
        task.resume()
    }

    override suspend fun reconcile() {
        // Touching the session recreates it with the same identifier and re-attaches its tasks.
        suspendCancellableCoroutine { cont ->
            session.getAllTasksWithCompletionHandler { _ -> cont.resume(Unit) }
        }
    }

    override suspend fun inFlightJobIds(): Set<String> =
        suspendCancellableCoroutine { cont ->
            session.getAllTasksWithCompletionHandler { tasks ->
                val ids = tasks.orEmpty()
                    .filterIsInstance<NSURLSessionTask>()
                    .filter {
                        it.state == NSURLSessionTaskStateRunning ||
                            it.state == NSURLSessionTaskStateSuspended
                    }
                    .mapNotNull { it.taskDescription }
                    .toSet()
                cont.resume(ids)
            }
        }

    private inner class Delegate : NSObject(), NSURLSessionDataDelegateProtocol {
        @ObjCSignatureOverride
        override fun URLSession(
            session: NSURLSession,
            dataTask: NSURLSessionDataTask,
            didReceiveData: NSData,
        ) {
            val key = dataTask.taskIdentifier.toLong()
            val buffer = responseData.getOrPut(key) { NSMutableData() }
            buffer.appendData(didReceiveData)
        }

        @ObjCSignatureOverride
        override fun URLSession(
            session: NSURLSession,
            task: NSURLSessionTask,
            didCompleteWithError: NSError?,
        ) {
            val jobId = task.taskDescription ?: return
            val key = task.taskIdentifier.toLong()
            val body = responseData.remove(key)?.let { data ->
                NSString.create(data, NSUTF8StringEncoding)?.toString()
            }.orEmpty()
            val outcome = if (didCompleteWithError != null) {
                CloudUploadOutcome(jobId, httpStatus = 0, error = didCompleteWithError.localizedDescription)
            } else {
                val status = (task.response as? NSHTTPURLResponse)?.statusCode?.toInt() ?: 0
                CloudUploadOutcome(jobId, httpStatus = status, responseBody = body)
            }
            _outcomes.tryEmit(outcome)
        }

        override fun URLSessionDidFinishEventsForBackgroundURLSession(session: NSURLSession) {
            backgroundEventsCompletion?.invoke()
            backgroundEventsCompletion = null
        }
    }

    companion object {
        const val SESSION_IDENTIFIER = "dev.audiocompanion.app.transcription-upload"

        /** One background session per app (iOS allows a single session per identifier). */
        val shared: IosBackgroundUploader by lazy { IosBackgroundUploader() }
    }
}
