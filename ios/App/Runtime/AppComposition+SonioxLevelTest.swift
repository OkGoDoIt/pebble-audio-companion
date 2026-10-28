import CompanionRuntime
import Foundation
import Transcription
import UIKit

// A measurement, not a feature: the Soniox level A/B (2026-10-28). Does Soniox transcribe quiet
// watch audio better when it is made louder first? Answered on public LibriSpeech speech only.
//
// It runs only when the app is launched with PEBBLE_SONIOX_LEVEL_TEST=1 (devicectl's
// `--environment-variables`), which no tap on the icon can do. It uploads the bodies a Mac copied
// into `diagnostics/soniox-level-test/bodies/` with the Soniox key this phone already holds, so the
// key never leaves the phone, and sends each one the way `SonioxTranscriptionProvider` does:
// the same multipart body, `stt-async-v5`, speaker labels on, no language hint. It sends no
// context, because the app's context is the wearer's own "About You" text. Each raw transcript goes
// to `results/<name>.json` for the Mac to score; each upload is deleted on Soniox once read. A body
// that already has a result is skipped, so a relaunch only sends what is missing, and a refused
// account (401/402/403) stops the run.
extension AppComposition {
    func installSonioxLevelTest() {
        guard ProcessInfo.processInfo.environment["PEBBLE_SONIOX_LEVEL_TEST"] == "1" else { return }
        let directory = containerRoot.appendingPathComponent(
            "diagnostics/soniox-level-test", isDirectory: true)
        // A simulator run against a local stand-in (research/tools/soniox_ab_dryrun.py --serve)
        // passes its address and a dummy key; nothing else ever sets these.
        let environment = ProcessInfo.processInfo.environment
        let fake = environment["PEBBLE_SONIOX_LEVEL_TEST_BASE"]
        let key = fake == nil
            ? settings.keychain.string(for: .sonioxApiKey) : environment["PEBBLE_SONIOX_LEVEL_TEST_KEY"]
        Task { @MainActor in
            // The run takes many minutes in the foreground; a locked screen would suspend it.
            UIApplication.shared.isIdleTimerDisabled = true
            await SonioxLevelTest.run(
                directory: directory, key: key,
                baseUrl: fake ?? SonioxTranscriptionProvider.defaultBaseUrl)
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }
}

enum SonioxLevelTest {
    private static let model = SonioxTranscriptionProvider.defaultModel

    private struct Refused: Error { let message: String }
    private struct Failed: Error { let message: String }

    private struct Outcome: Encodable {
        let name: String
        let status: String
        var error: String? = nil
        var seconds: Double? = nil
        var audioDurationMs: Int? = nil
    }

    private struct Log: Encodable {
        let finishedAt: String
        let model: String
        let results: [Outcome]
    }

    static func run(directory: URL, key: String?, baseUrl: String) async {
        let log: @Sendable (String) -> Void = { AppRuntimeLog.shared.record("soniox level test: \($0)") }
        guard let key, !key.isEmpty else {
            log("no Soniox key on this phone; nothing sent")
            return
        }
        let fm = FileManager.default
        let results = directory.appendingPathComponent("results", isDirectory: true)
        try? fm.createDirectory(at: results, withIntermediateDirectories: true)
        let bodies = ((try? fm.contentsOfDirectory(
            at: directory.appendingPathComponent("bodies", isDirectory: true),
            includingPropertiesForKeys: nil)) ?? [])
            .filter { ["ogg", "flac"].contains($0.pathExtension) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        log("\(bodies.count) files to check")
        var outcomes: [Outcome] = []
        var refused = false
        // Three at a time, like the Mac runner.
        for start in stride(from: 0, to: bodies.count, by: 3) where !refused {
            let batch = Array(bodies[start..<min(start + 3, bodies.count)])
            let finished = await withTaskGroup(of: Outcome.self) { group in
                for body in batch {
                    group.addTask { await send(body, key: key, baseUrl: baseUrl, results: results) }
                }
                var collected: [Outcome] = []
                for await outcome in group { collected.append(outcome) }
                return collected
            }
            for outcome in finished {
                log("\(outcome.name) \(outcome.status)\(outcome.error.map { ": \($0)" } ?? "")")
                if outcome.status == "refused" { refused = true }
            }
            outcomes += finished
        }
        let summary = Log(
            finishedAt: ISO8601DateFormatter().string(from: Date()), model: model, results: outcomes)
        if let data = try? JSONEncoder().encode(summary) {
            try? data.write(to: results.appendingPathComponent("run-log.json"), options: .atomic)
        }
        let done = outcomes.filter { $0.status == "done" }.count
        log("finished: \(done) sent, \(outcomes.count - done) not\(refused ? " (Soniox refused the account)" : "")")
    }

    private static func send(_ body: URL, key: String, baseUrl: String, results: URL) async -> Outcome {
        let name = body.deletingPathExtension().lastPathComponent
        let out = results.appendingPathComponent("\(name).json")
        if FileManager.default.fileExists(atPath: out.path) { return Outcome(name: name, status: "kept") }
        let started = Date()
        var fileId: String?
        var transcriptionId: String?
        defer {
            let ids = [transcriptionId.map { "/v1/transcriptions/\($0)" }, fileId.map { "/v1/files/\($0)" }]
            Task {
                for path in ids.compactMap({ $0 }) { _ = try? await call("DELETE", path, key: key, baseUrl: baseUrl) }
            }
        }
        do {
            let ext = body.pathExtension
            let (multipart, contentType) = MultipartBody.encode(
                boundary: "PebbleAudioKit-\(UUID().uuidString)",
                textFields: [],
                file: MultipartBody.FilePart(
                    name: "file", filename: "segment.\(ext)",
                    contentType: ext == "ogg" ? "audio/ogg" : "audio/flac",
                    bytes: try Data(contentsOf: body)))
            fileId = try id(in: await call("POST", "/v1/files", key: key, baseUrl: baseUrl, body: multipart, contentType: contentType))
            let create = try JSONSerialization.data(withJSONObject: [
                "model": model, "file_id": fileId ?? "", "enable_speaker_diarization": true,
            ])
            transcriptionId = try id(in: await call(
                "POST", "/v1/transcriptions", key: key, baseUrl: baseUrl, body: create, contentType: "application/json"))
            var meta: [String: Any] = [:]
            let deadline = Date().addingTimeInterval(45 * 60)
            while true {
                let data = try await call("GET", "/v1/transcriptions/\(transcriptionId ?? "")", key: key, baseUrl: baseUrl)
                meta = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
                let status = meta["status"] as? String
                if status == "completed" { break }
                if status == "error" {
                    throw Failed(message: "Soniox could not transcribe it: \(meta["error_message"] ?? "")")
                }
                if Date() > deadline { throw Failed(message: "not finished after 45 minutes") }
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
            let transcript = try await call(
                "GET", "/v1/transcriptions/\(transcriptionId ?? "")/transcript", key: key, baseUrl: baseUrl)
            try transcript.write(to: out, options: .atomic)
            return Outcome(
                name: name, status: "done", seconds: Date().timeIntervalSince(started),
                audioDurationMs: meta["audio_duration_ms"] as? Int)
        } catch let refused as Refused {
            return Outcome(name: name, status: "refused", error: refused.message)
        } catch let failed as Failed {
            return Outcome(name: name, status: "failed", error: failed.message)
        } catch {
            return Outcome(name: name, status: "failed", error: "\(error)")
        }
    }

    private static func id(in data: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let id = object["id"] as? String
        else { throw Failed(message: "no id in the response") }
        return id
    }

    private static func call(
        _ method: String, _ path: String, key: String, baseUrl: String, body: Data? = nil,
        contentType: String? = nil
    ) async throws -> Data {
        var request = URLRequest(url: URL(string: baseUrl + path)!)
        request.httpMethod = method
        request.timeoutInterval = 900
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        let (data, response) =
            if let body {
                try await URLSession.shared.upload(for: request, from: body)
            } else {
                try await URLSession.shared.data(for: request)
            }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let text = String(decoding: data.prefix(240), as: UTF8.self)
        if [401, 402, 403].contains(status) { throw Refused(message: "Soniox refused the account (\(status)): \(text)") }
        guard (200..<300).contains(status) else { throw Failed(message: "\(method) \(path) failed (\(status)): \(text)") }
        return data
    }
}
