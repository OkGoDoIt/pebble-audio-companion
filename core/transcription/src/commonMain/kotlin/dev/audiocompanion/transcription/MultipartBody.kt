package dev.audiocompanion.transcription

import kotlinx.io.buffered
import kotlinx.io.files.FileSystem
import kotlinx.io.files.Path

/**
 * Assembles a `multipart/form-data` request body to a file on disk so it can be uploaded by a
 * background transport (which uploads from a file, not an in-memory body). Returns the
 * `Content-Type` header value carrying the boundary.
 */
object MultipartBody {
    data class FilePart(
        val name: String,
        val filename: String,
        val contentType: String,
        val bytes: ByteArray,
    )

    /** Writes the body to [path] and returns the matching `Content-Type` header value. */
    fun writeTo(
        fileSystem: FileSystem,
        path: Path,
        boundary: String,
        textFields: List<Pair<String, String>>,
        file: FilePart,
    ): String {
        val dashBoundary = "--$boundary"
        fileSystem.sink(path).buffered().use { sink ->
            textFields.forEach { (name, value) ->
                sink.write("$dashBoundary\r\n".encodeToByteArray())
                sink.write(
                    "Content-Disposition: form-data; name=\"$name\"\r\n\r\n".encodeToByteArray(),
                )
                sink.write(value.encodeToByteArray())
                sink.write("\r\n".encodeToByteArray())
            }
            sink.write("$dashBoundary\r\n".encodeToByteArray())
            sink.write(
                (
                    "Content-Disposition: form-data; name=\"${file.name}\"; " +
                        "filename=\"${file.filename}\"\r\n"
                    ).encodeToByteArray(),
            )
            sink.write("Content-Type: ${file.contentType}\r\n\r\n".encodeToByteArray())
            sink.write(file.bytes)
            sink.write("\r\n".encodeToByteArray())
            sink.write("$dashBoundary--\r\n".encodeToByteArray())
        }
        return "multipart/form-data; boundary=$boundary"
    }
}
