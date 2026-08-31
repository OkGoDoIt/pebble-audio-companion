import Compression
import Foundation

// The model archives are plain ZIPs, and iOS has no public unzip API — the KMP app used okio's
// `openZip`. This is the equivalent: a minimal ZIP reader (central directory + stored/deflated
// entries, ZIP64 aware) over a memory-MAPPED archive, inflating through a fixed-size window so
// a 1.2 GB archive never becomes 1.2 GB of resident memory.

public enum ZipExtractionError: Error, Equatable, Sendable {
    case notAZipArchive
    case unsupportedCompression(UInt16)
    case corruptArchive(String)
    /// An entry tried to escape the destination directory (`..`, or an absolute path).
    case unsafeEntryPath(String)
    case writeFailed(String)
}

/// Extracts one archive into one directory. A seam so the store's state machine can be tested
/// without producing real ZIP bytes.
public protocol ParakeetArchiveExtracting: Sendable {
    func extract(archiveAt archive: URL, into directory: URL) throws
}

public struct ZipArchiveExtractor: ParakeetArchiveExtracting {
    public init() {}

    public func extract(archiveAt archive: URL, into directory: URL) throws {
        try ZipArchive.extract(archiveAt: archive, into: directory)
    }
}

enum ZipArchive {
    private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4B50
    private static let zip64LocatorSignature: UInt32 = 0x0706_4B50
    private static let zip64EndSignature: UInt32 = 0x0606_4B50
    private static let centralFileSignature: UInt32 = 0x0201_4B50
    private static let localFileSignature: UInt32 = 0x0403_4B50
    private static let windowBytes = 1 << 18  // 256 KiB inflate/copy window

    struct Entry {
        var name: String
        var method: UInt16
        var compressedSize: Int
        var uncompressedSize: Int
        var localHeaderOffset: Int
    }

    static func extract(archiveAt archive: URL, into directory: URL) throws {
        let data = try Data(contentsOf: archive, options: .alwaysMapped)
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let root = directory.standardizedFileURL
        for entry in try entries(in: data) {
            let destination = try safeDestination(root: root, entryName: entry.name)
            if entry.name.hasSuffix("/") {
                try manager.createDirectory(at: destination, withIntermediateDirectories: true)
                continue
            }
            try manager.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try write(entry: entry, from: data, to: destination)
        }
    }

    /// Rejects entries that would land outside `root` (the KMP extractor's `..` guard, widened
    /// to absolute paths and to anything that normalizes out of the destination).
    static func safeDestination(root: URL, entryName: String) throws -> URL {
        let name = entryName.hasSuffix("/") ? String(entryName.dropLast()) : entryName
        guard !name.isEmpty, !name.hasPrefix("/"), !name.hasPrefix("~"),
            !name.split(separator: "/").contains("..")
        else { throw ZipExtractionError.unsafeEntryPath(entryName) }
        let destination = root.appendingPathComponent(name).standardizedFileURL
        guard destination.path.hasPrefix(root.path + "/") else {
            throw ZipExtractionError.unsafeEntryPath(entryName)
        }
        return destination
    }

    // MARK: - Central directory

    static func entries(in data: Data) throws -> [Entry] {
        let (directoryOffset, entryCount) = try centralDirectoryLocation(in: data)
        var entries: [Entry] = []
        entries.reserveCapacity(entryCount)
        var offset = directoryOffset
        for _ in 0..<entryCount {
            guard try u32(data, offset) == centralFileSignature else {
                throw ZipExtractionError.corruptArchive("bad central directory entry")
            }
            let nameLength = Int(try u16(data, offset + 28))
            let extraLength = Int(try u16(data, offset + 30))
            let commentLength = Int(try u16(data, offset + 32))
            let nameStart = offset + 46
            guard nameStart + nameLength <= data.count,
                let name = String(data: data[nameStart..<nameStart + nameLength], encoding: .utf8)
            else { throw ZipExtractionError.corruptArchive("bad entry name") }
            var entry = Entry(
                name: name,
                method: try u16(data, offset + 10),
                compressedSize: Int(try u32(data, offset + 20)),
                uncompressedSize: Int(try u32(data, offset + 24)),
                localHeaderOffset: Int(try u32(data, offset + 42))
            )
            try applyZip64(
                extraAt: nameStart + nameLength, length: extraLength, in: data, to: &entry
            )
            entries.append(entry)
            offset = nameStart + nameLength + extraLength + commentLength
        }
        return entries
    }

    /// ZIP64 extended-information extra field (0x0001): the 0xFFFFFFFF placeholders are
    /// replaced, in this fixed order, by the 64-bit values that are actually present.
    private static func applyZip64(
        extraAt start: Int, length: Int, in data: Data, to entry: inout Entry
    ) throws {
        var cursor = start
        let end = start + length
        guard end <= data.count else {
            throw ZipExtractionError.corruptArchive("extra field past end of archive")
        }
        while cursor + 4 <= end {
            let headerId = try u16(data, cursor)
            let size = Int(try u16(data, cursor + 2))
            let body = cursor + 4
            guard body + size <= end else { break }
            if headerId == 0x0001 {
                var field = body
                if entry.uncompressedSize == 0xFFFF_FFFF, field + 8 <= body + size {
                    entry.uncompressedSize = Int(try u64(data, field))
                    field += 8
                }
                if entry.compressedSize == 0xFFFF_FFFF, field + 8 <= body + size {
                    entry.compressedSize = Int(try u64(data, field))
                    field += 8
                }
                if entry.localHeaderOffset == 0xFFFF_FFFF, field + 8 <= body + size {
                    entry.localHeaderOffset = Int(try u64(data, field))
                }
                return
            }
            cursor = body + size
        }
    }

    private static func centralDirectoryLocation(in data: Data) throws -> (
        offset: Int, count: Int
    ) {
        guard data.count >= 22 else { throw ZipExtractionError.notAZipArchive }
        // The end-of-central-directory record sits within 64 KiB + 22 of the end (comment).
        let searchStart = max(0, data.count - 22 - 0xFFFF)
        var eocd: Int?
        var probe = data.count - 22
        while probe >= searchStart {
            if (try? u32(data, probe)) == endOfCentralDirectorySignature {
                eocd = probe
                break
            }
            probe -= 1
        }
        guard let eocd else { throw ZipExtractionError.notAZipArchive }
        var count = Int(try u16(data, eocd + 10))
        var offset = Int(try u32(data, eocd + 16))
        if count == 0xFFFF || offset == 0xFFFF_FFFF {
            let locator = eocd - 20
            guard locator >= 0, try u32(data, locator) == zip64LocatorSignature else {
                throw ZipExtractionError.corruptArchive("missing ZIP64 locator")
            }
            let record = Int(try u64(data, locator + 8))
            guard try u32(data, record) == zip64EndSignature else {
                throw ZipExtractionError.corruptArchive("missing ZIP64 end record")
            }
            count = Int(try u64(data, record + 32))
            offset = Int(try u64(data, record + 48))
        }
        guard offset >= 0, offset < data.count else {
            throw ZipExtractionError.corruptArchive("central directory out of range")
        }
        return (offset, count)
    }

    // MARK: - Entry payloads

    private static func write(entry: Entry, from data: Data, to destination: URL) throws {
        let header = entry.localHeaderOffset
        guard try u32(data, header) == localFileSignature else {
            throw ZipExtractionError.corruptArchive("bad local header for \(entry.name)")
        }
        // The local header's name/extra lengths may differ from the central directory's.
        let start = header + 30 + Int(try u16(data, header + 26)) + Int(try u16(data, header + 28))
        let end = start + entry.compressedSize
        guard start >= 0, end <= data.count else {
            throw ZipExtractionError.corruptArchive("entry data out of range: \(entry.name)")
        }
        let payload = data[start..<end]

        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) {
            try manager.removeItem(at: destination)
        }
        guard manager.createFile(atPath: destination.path, contents: nil) else {
            throw ZipExtractionError.writeFailed(destination.path)
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        switch entry.method {
        case 0:
            var cursor = payload.startIndex
            while cursor < payload.endIndex {
                let chunkEnd = min(cursor + windowBytes, payload.endIndex)
                try handle.write(contentsOf: payload[cursor..<chunkEnd])
                cursor = chunkEnd
            }
        case 8:
            try inflate(payload) { try handle.write(contentsOf: $0) }
        default:
            throw ZipExtractionError.unsupportedCompression(entry.method)
        }
    }

    /// Raw-DEFLATE inflate through a fixed output window (`COMPRESSION_ZLIB` is Apple's name
    /// for the headerless deflate stream ZIP stores).
    static func inflate(_ input: Data, write: (Data) throws -> Void) throws {
        var stream = compression_stream(
            dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!, dst_size: 0,
            src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0, state: nil
        )
        guard
            compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
                == COMPRESSION_STATUS_OK
        else { throw ZipExtractionError.corruptArchive("inflate init failed") }
        defer { compression_stream_destroy(&stream) }

        let output = UnsafeMutablePointer<UInt8>.allocate(capacity: windowBytes)
        defer { output.deallocate() }

        var thrown: Error?
        input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            stream.src_ptr = base
            stream.src_size = raw.count
            while true {
                stream.dst_ptr = output
                stream.dst_size = windowBytes
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = windowBytes - stream.dst_size
                if produced > 0 {
                    do {
                        try write(Data(bytes: output, count: produced))
                    } catch {
                        thrown = error
                        return
                    }
                }
                if status == COMPRESSION_STATUS_END { return }
                if status != COMPRESSION_STATUS_OK {
                    thrown = ZipExtractionError.corruptArchive("inflate failed")
                    return
                }
                if produced == 0 && stream.src_size == 0 {
                    thrown = ZipExtractionError.corruptArchive("truncated deflate stream")
                    return
                }
            }
        }
        if let thrown { throw thrown }
    }

    // MARK: - Little-endian readers

    private static func byte(_ data: Data, _ offset: Int) throws -> UInt64 {
        guard offset >= 0, offset < data.count else {
            throw ZipExtractionError.corruptArchive("read past end of archive")
        }
        return UInt64(data[offset])
    }

    static func u16(_ data: Data, _ offset: Int) throws -> UInt16 {
        UInt16(try byte(data, offset) | (try byte(data, offset + 1) << 8))
    }

    static func u32(_ data: Data, _ offset: Int) throws -> UInt32 {
        var value: UInt64 = 0
        for index in 0..<4 { value |= try byte(data, offset + index) << (8 * index) }
        return UInt32(value)
    }

    static func u64(_ data: Data, _ offset: Int) throws -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 { value |= try byte(data, offset + index) << (8 * index) }
        return value
    }
}
