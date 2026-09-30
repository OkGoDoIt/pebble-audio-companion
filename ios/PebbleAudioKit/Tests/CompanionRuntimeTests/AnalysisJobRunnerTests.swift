import Foundation
import Intelligence
import Testing
import Transcription

@testable import CompanionRuntime

@Suite("analysis job runner")
struct AnalysisJobRunnerTests {
    struct EchoProvider: AiProvider {
        let id = "echo"
        func isAvailable() async -> Bool { true }
        func run(_ request: AiRunRequest) async throws -> AiProviderResult {
            if request.transcripts[0].text == "fail" { throw AiError.providerFailed("nope") }
            return AiProviderResult(text: "judged: \(request.transcripts[0].text)", modelUsed: "echo-1")
        }
    }

    final class RecordingTransport: HttpTransport, @unchecked Sendable {
        let lock = NSLock()
        var requests: [HttpTransportRequest] = []
        func execute(_ request: HttpTransportRequest) async throws -> HttpTransportResponse {
            lock.withLock { requests.append(request) }
            return HttpTransportResponse(status: 200, text: #"{"ok":true}"#)
        }
    }

    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("analysis-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent("analysis/inbox"), withIntermediateDirectories: true)
        return url
    }

    private func write(_ job: AnalysisJob, to root: URL) throws {
        try JSONEncoder().encode(job).write(
            to: root.appendingPathComponent("analysis/inbox/\(job.id).json"))
    }

    private func lines(_ root: URL, _ id: String) throws -> [[String: JSONValue]] {
        let text = try String(
            contentsOf: root.appendingPathComponent("analysis/outbox/\(id).jsonl"), encoding: .utf8)
        return try text.split(whereSeparator: \.isNewline).map {
            try JSONDecoder().decode([String: JSONValue].self, from: Data($0.utf8))
        }
    }

    @Test("an AI job records one line per item, failures included, and is marked done")
    func aiJob() async throws {
        let root = try root()
        let prompt = AiPromptTemplate(id: "judge", title: "Judge", systemPrompt: "s", userPrompt: "u")
        try write(
            AnalysisJob(
                id: "j1", kind: .aiJudge, provider: .remote, prompt: prompt, parallel: 2,
                items: [
                    .init(id: "a", text: "one"), .init(id: "b", text: "fail"),
                    .init(id: "c", text: "three"),
                ]), to: root)
        let runner = AnalysisJobRunner(
            root: root, remote: EchoProvider(), local: nil, openAiKey: { nil },
            transport: RecordingTransport())
        #expect(await runner.runPending() == ["j1"])
        let out = try lines(root, "j1")
        #expect(Set(out.compactMap { if case .string(let id)? = $0["id"] { id } else { nil } }) == ["a", "b", "c"])
        let a = try #require(out.first { $0["id"] == .string("a") })
        #expect(a["text"] == .string("judged: one") && a["ok"] == .bool(true))
        #expect(out.first { $0["id"] == .string("b") }?["ok"] == .bool(false))
        // Done jobs are not run again.
        #expect(await runner.runPending().isEmpty)
    }

    @Test("a raw OpenAI job substitutes the clip and sends only to OpenAI with the app's key")
    func rawJobSubstitutesClip() async throws {
        let root = try root()
        try Data([1, 2, 3]).write(to: root.appendingPathComponent("analysis/clip.wav"))
        try write(
            AnalysisJob(
                id: "r1", kind: .openAiRaw, path: "/v1/chat/completions",
                items: [
                    .init(
                        id: "x", clip: "clip.wav",
                        body: .object(["audio": .string(AnalysisJobRunner.clipPlaceholder)]))
                ]), to: root)
        let transport = RecordingTransport()
        let runner = AnalysisJobRunner(
            root: root, remote: nil, local: nil, openAiKey: { "sk-test" }, transport: transport)
        #expect(await runner.runPending() == ["r1"])
        let request = try #require(transport.lock.withLock { transport.requests.first })
        #expect(request.url == "https://api.openai.com/v1/chat/completions")
        #expect(request.headers["Authorization"] == "Bearer sk-test")
        let body = try JSONDecoder().decode([String: String].self, from: try #require(request.body))
        #expect(body["audio"] == Data([1, 2, 3]).base64EncodedString())
    }

    @Test("a job that needs the charger waits for it, and nothing runs without a job")
    func chargingAndIdle() async throws {
        let root = try root()
        let charging = Box(false)
        let runner = AnalysisJobRunner(
            root: root, remote: nil, local: EchoProvider(), openAiKey: { nil },
            transport: RecordingTransport(), isCharging: { charging.value })
        #expect(await runner.runPending().isEmpty)
        let prompt = AiPromptTemplate(id: "judge", title: "Judge", systemPrompt: "s", userPrompt: "u")
        try write(
            AnalysisJob(
                id: "l1", kind: .aiJudge, provider: .local, requiresCharging: true, prompt: prompt,
                items: [.init(id: "a", text: "one")]), to: root)
        #expect(await runner.runPending().isEmpty)
        charging.value = true
        #expect(await runner.runPending() == ["l1"])
    }

    final class Box: @unchecked Sendable {
        var value: Bool
        init(_ value: Bool) { self.value = value }
    }
}
