import Foundation
import Testing

@testable import Transcription

/// The directories a system framework leaves under `tmp/` (`ScratchFileSweep.directoryRules`):
/// 6.19 GB of Neural Engine compiler dumps on the phone on 2026-10-12, three times the audio.
@Suite struct ScratchDirectorySweepTests {
    @Test func removesOldCompilerFoldersWholeAndLeavesFreshOnes() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("sweep-dirs-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let parent = dir.appendingPathComponent("com.apple.MetalPerformanceShadersGraph", isDirectory: true)
        let twoDaysAgo = Date().addingTimeInterval(-2 * 86_400)

        func folder(_ name: String, under: URL = parent, files: [(String, Int)], modified: Date) throws -> URL {
            let url = under.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            for (file, bytes) in files {
                try Data(count: bytes).write(to: url.appendingPathComponent(file))
            }
            try fm.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
            return url
        }
        let old = try folder(
            "mpsgraph-77842-2026-09-29_23_13_00-3696236805",
            files: [("main_x_ANE_region_0_0.bc.mlir", 4_096), ("compiler_options.plist", 700)],
            modified: twoDaysAgo)
        let fresh = try folder(
            "mpsgraph-99999-2026-10-12_23_00_00-1", files: [("main.bc.mlir", 512)], modified: Date())
        let unrelated = try folder("not-a-compile", files: [("keep.txt", 100)], modified: twoDaysAgo)
        let elsewhere = try folder(
            "mpsgraph-elsewhere", under: dir, files: [("keep.mlir", 100)], modified: twoDaysAgo)

        let result = ScratchFileSweep.run(in: dir)

        #expect(result == ScratchFileSweep.Result(files: 2, bytes: 4_796))
        #expect(!fm.fileExists(atPath: old.path), "the old compile folder goes, whole")
        #expect(fm.fileExists(atPath: fresh.path), "a folder a compile may still be writing stays")
        #expect(fm.fileExists(atPath: unrelated.path), "only the named prefix is touched")
        #expect(fm.fileExists(atPath: elsewhere.path), "only under the named parent")
    }

    @Test func aMissingParentIsNothingToDo() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sweep-nodirs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(ScratchFileSweep.run(in: dir) == ScratchFileSweep.Result(files: 0, bytes: 0))
    }
    @Test func abandonedEnrollmentAudioIsSweptButCurrentSampleIsKept() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let old = dir.appendingPathComponent("voice-enrollment-old.wav")
        let fresh = dir.appendingPathComponent("voice-enrollment-current.wav")
        try Data(repeating: 1, count: 32).write(to: old)
        try Data(repeating: 2, count: 64).write(to: fresh)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-3_600)], ofItemAtPath: old.path)
        _ = ScratchFileSweep.run(in: dir)
        #expect(!fm.fileExists(atPath: old.path))
        #expect(fm.fileExists(atPath: fresh.path))
    }

}
