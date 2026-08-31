import Foundation

// Port of `core/transcription/.../MultipartBody.kt`.

/// Assembles `multipart/form-data` request bodies. The file-writing variant exists for the
/// background transport (a background `URLSession` uploads from a file, not an in-memory body);
/// the in-memory variant serves the synchronous provider paths. Both return the matching
/// `Content-Type` header value carrying the boundary.
public enum MultipartBody {
    public struct FilePart: Sendable {
        public let name: String
        public let filename: String
        public let contentType: String
        public let bytes: Data

        public init(name: String, filename: String, contentType: String, bytes: Data) {
            self.name = name
            self.filename = filename
            self.contentType = contentType
            self.bytes = bytes
        }
    }

    /// Assembles the body in memory. Returns the body and the `Content-Type` header value.
    public static func encode(
        boundary: String,
        textFields: [(String, String)],
        file: FilePart
    ) -> (body: Data, contentType: String) {
        let dashBoundary = "--\(boundary)"
        var body = Data()
        for (name, value) in textFields {
            body.append(Data("\(dashBoundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data(value.utf8))
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("\(dashBoundary)\r\n".utf8))
        body.append(
            Data(
                ("Content-Disposition: form-data; name=\"\(file.name)\"; "
                    + "filename=\"\(file.filename)\"\r\n").utf8
            )
        )
        body.append(Data("Content-Type: \(file.contentType)\r\n\r\n".utf8))
        body.append(file.bytes)
        body.append(Data("\r\n".utf8))
        body.append(Data("\(dashBoundary)--\r\n".utf8))
        return (body, "multipart/form-data; boundary=\(boundary)")
    }

    /// Writes the body to `fileURL` (atomically) and returns the `Content-Type` header value.
    @discardableResult
    public static func writeTo(
        fileURL: URL,
        boundary: String,
        textFields: [(String, String)],
        file: FilePart
    ) throws -> String {
        let (body, contentType) = encode(boundary: boundary, textFields: textFields, file: file)
        try body.write(to: fileURL, options: .atomic)
        return contentType
    }
}
