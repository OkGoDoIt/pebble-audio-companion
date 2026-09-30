import CompanionRuntime
import Foundation
import Testing

// The log has one job the in-memory ring could not do: outlive the process that wrote it. Every
// failure worth diagnosing here — suspension, jettison, a Bluetooth relaunch, a watchdog kill —
// ends with the process gone, so a log that dies with it is empty exactly when it matters.

@Suite struct FlightRecorderTests {

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flight-recorder-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func linesSurviveANewRecorderOverTheSameDirectory() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = FlightRecorder(directory: directory)
        first.recordLaunch(cause: "foreground", version: "2.0.0")
        first.record("link ready")
        _ = first.export()  // flushes

        // A second recorder is what the NEXT process gets. The point of the whole class.
        let second = FlightRecorder(directory: directory)
        second.recordLaunch(cause: "background", version: "2.0.0")
        let text = second.export()

        #expect(text.contains("process start (foreground)"))
        #expect(text.contains("link ready"))
        #expect(text.contains("process start (background)"))
    }

    @Test func rotationKeepsTheRecentPastAndBoundsTheFile() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Small enough to rotate several times over.
        let recorder = FlightRecorder(directory: directory, maxBytes: 4_096)
        for index in 0..<800 {
            recorder.record("line \(index) with enough text to move the byte count along")
        }
        let text = recorder.export()

        // The newest lines are always there...
        #expect(text.contains("line 799"))
        // ...the oldest have been rotated out...
        #expect(!text.contains("line 0 with"))
        // ...and the file never grows without bound (active + one rotated predecessor). The
        // active file is created lazily by the next write, so it is legitimately ABSENT when the
        // last line happened to rotate — and whether it does depends on the line length, which
        // carries the machine's uptime ("[up 761051.9s]"). Read strictly, this failed on some
        // days and passed on others.
        let active = (try? Data(contentsOf: recorder.activeURL).count) ?? 0
        let previous = (try? Data(contentsOf: recorder.previousURL).count) ?? 0
        #expect(active <= 4_096 + 1_024)
        #expect(previous <= 4_096 + 1_024)
    }

    @Test func everyLineCarriesADateAZoneAndAMonotonicClock() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let recorder = FlightRecorder(directory: directory)
        recorder.record("something happened")
        let line = recorder.export()

        // The ring stamped HH:mm:ss.SSS, which cannot order two lines from different days and
        // shifts silently when the user travels. "It stopped overnight" needs a date.
        #expect(line.contains("-") && line.contains("T"), "expected an ISO-8601 date: \(line)")
        // Uptime alongside wall time is how a suspension is read off the log: wall time advances
        // across it, uptime does too, but a heartbeat gap appears in both.
        #expect(line.contains("[up "), "expected a monotonic uptime: \(line)")
    }

    @Test func recentLinesAreNewestFirstForTheScreen() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let recorder = FlightRecorder(directory: directory)
        recorder.record("oldest")
        recorder.record("newest")

        let lines = recorder.recentLines()
        #expect(lines.first?.contains("newest") == true)
        #expect(lines.last?.contains("oldest") == true)
    }

    @Test func exportFileGathersBothGenerationsIntoOneShareableFile() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let recorder = FlightRecorder(directory: directory, maxBytes: 512)
        for index in 0..<200 { recorder.record("line \(index)") }

        let url = try #require(recorder.exportFile())
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("line 199"))
        #expect(text.count > 512, "the shared file must span the rotated generation too")
    }

    @Test func deleteAllLeavesNothingBehind() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let recorder = FlightRecorder(directory: directory)
        recorder.record("private")
        #expect(!recorder.export().isEmpty)

        recorder.deleteAll()
        #expect(recorder.export().isEmpty)
    }
}
