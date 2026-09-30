import Foundation
import Intelligence
import Transcription

// A developer-only measurement channel: lets a measurement run on the phone, with the app's own
// keys and its own AI path, without a key ever leaving the phone.
//
// How it is used (see `docs/audio-content-classification.md`, "Running a measurement on the
// phone"): the Mac copies a job file into `<container>/analysis/inbox/` with
// `xcrun devicectl device copy to`, the app notices it within a minute, runs every item, and
// appends one JSON line per item to `analysis/outbox/<job id>.jsonl`, then writes
// `<job id>.done`. The Mac copies the outbox back. A job that is interrupted resumes where it
// stopped: items already in the outbox are skipped.
//
// It does NOTHING unless a job file is present, and the only way to put one there is a
// developer with the device paired to Xcode. It sends only what the job names, only to the
// person's configured AI provider or to OpenAI's API host, and only through the same consent
// the app's own AI work needs. Its cost when idle is one directory listing a minute.

public struct AnalysisJob: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// Each item's `text` goes to an AI provider with `prompt`; the answer is recorded.
        case aiJudge
        /// Each item's `body` goes to `path` on OpenAI's API with the app's OpenAI key. A string
        /// value `{{CLIP_BASE64}}` anywhere in the body is replaced by the base64 of the item's
        /// `clip` file (relative to `analysis/`).
        case openAiRaw
    }

    public enum Provider: String, Codable, Sendable {
        /// The person's remote provider (OpenAI with their key, or Private Cloud Compute).
        case remote
        /// The on-device model.
        case local
    }

    public struct Item: Codable, Sendable, Equatable {
        public var id: String
        public var text: String?
        public var clip: String?
        public var body: JSONValue?
    }

    public var id: String
    public var kind: Kind
    public var provider: Provider?
    /// Only run while the phone is charging (for on-device model work).
    public var requiresCharging: Bool?
    public var prompt: AiPromptTemplate?
    public var metadata: [String: String]?
    public var method: String?
    public var path: String?
    /// Items run concurrently, at most this many at a time (default 1, at most 6).
    public var parallel: Int?
    public var items: [Item]
}

/// Minimal JSON value so a job can carry an arbitrary request body.
public enum JSONValue: Codable, Sendable, Equatable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]),
        array([JSONValue]), null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    /// Replaces every string equal to `placeholder` with `value`.
    func replacing(_ placeholder: String, with value: String) -> JSONValue {
        switch self {
        case .string(let v): return .string(v == placeholder ? value : v)
        case .object(let v): return .object(v.mapValues { $0.replacing(placeholder, with: value) })
        case .array(let v): return .array(v.map { $0.replacing(placeholder, with: value) })
        default: return self
        }
    }
}

public actor AnalysisJobRunner {
    public static let clipPlaceholder = "{{CLIP_BASE64}}"
    static let openAiHost = "https://api.openai.com"

    private let root: URL
    private let remote: AiProvider?
    private let local: AiProvider?
    private let openAiKey: @Sendable () -> String?
    private let transport: HttpTransport
    private let isCharging: @Sendable () -> Bool
    private let log: RuntimeLog
    private var running = false

    /// `root` is the app's data root (`…/audio-companion`); jobs live under `root/analysis`.
    public init(
        root: URL, remote: AiProvider?, local: AiProvider?,
        openAiKey: @escaping @Sendable () -> String?, transport: HttpTransport,
        isCharging: @escaping @Sendable () -> Bool = { false }, log: RuntimeLog = .silent
    ) {
        self.root = root.appendingPathComponent("analysis", isDirectory: true)
        self.remote = remote
        self.local = local
        self.openAiKey = openAiKey
        self.transport = transport
        self.isCharging = isCharging
        self.log = log
    }

    private var inbox: URL { root.appendingPathComponent("inbox", isDirectory: true) }
    private var outbox: URL { root.appendingPathComponent("outbox", isDirectory: true) }

    /// Checks for work every `intervalSeconds` for as long as the task lives.
    public func pollForever(intervalSeconds: UInt64 = 60) async {
        while !Task.isCancelled {
            await runPending()
            try? await Task.sleep(nanoseconds: intervalSeconds * 1_000_000_000)
        }
    }

    /// Runs every job in the inbox that is not done. Returns the ids of jobs finished now.
    @discardableResult
    public func runPending() async -> [String] {
        guard !running else { return [] }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: inbox.path)) ?? []
        let jobs = names.filter { $0.hasSuffix(".json") }.sorted()
        guard !jobs.isEmpty else { return [] }
        running = true
        defer { running = false }
        try? FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
        var finished: [String] = []
        for name in jobs {
            let url = inbox.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                let job = try? JSONDecoder().decode(AnalysisJob.self, from: data)
            else {
                log.write("analysis: unreadable job \(name)")
                continue
            }
            let done = outbox.appendingPathComponent("\(job.id).done")
            if FileManager.default.fileExists(atPath: done.path) { continue }
            if job.requiresCharging == true, !isCharging() { continue }
            if await run(job) {
                FileManager.default.createFile(atPath: done.path, contents: Data())
                finished.append(job.id)
                log.write("analysis: job \(job.id) finished (\(job.items.count) items)")
            }
        }
        return finished
    }

    /// Runs one job's outstanding items. True when every item has a line in the outbox.
    func run(_ job: AnalysisJob) async -> Bool {
        let resultsURL = outbox.appendingPathComponent("\(job.id).jsonl")
        let done = Self.completedIds(resultsURL)
        let pending = job.items.filter { !done.contains($0.id) }
        if pending.isEmpty { return true }
        log.write("analysis: job \(job.id) running \(pending.count) of \(job.items.count) items")
        let width = min(max(job.parallel ?? 1, 1), 6)
        var index = 0
        var completed = done.count
        await withTaskGroup(of: [String: JSONValue].self) { group in
            func enqueue() {
                guard index < pending.count else { return }
                let item = pending[index]
                index += 1
                group.addTask { await self.runItem(item, of: job) }
            }
            for _ in 0..<width { enqueue() }
            while let line = await group.next() {
                if case .bool(true)? = line["ok"] { completed += 1 }
                Self.append(line, to: resultsURL)
                if Task.isCancelled { break }
                enqueue()
            }
        }
        // Failed items are written too (ok: false) and count as attempted; a job is done once
        // every item has a line. Re-running a failed item means pushing a new job id.
        return Self.completedIds(resultsURL).isSuperset(of: job.items.map(\.id))
    }

    private func runItem(_ item: AnalysisJob.Item, of job: AnalysisJob) async -> [String: JSONValue] {
        let started = Date()
        var line: [String: JSONValue] = ["id": .string(item.id)]
        do {
            switch job.kind {
            case .aiJudge:
                guard let prompt = job.prompt, let text = item.text else {
                    throw AiError.providerFailed("aiJudge item needs prompt and text")
                }
                let provider = job.provider == .local ? local : remote
                guard let provider else {
                    throw AiError.providerUnavailable(providerId: job.provider?.rawValue ?? "remote")
                }
                let result = try await provider.run(
                    AiRunRequest(
                        requestId: "analysis-\(job.id)-\(item.id)", prompt: prompt,
                        transcripts: [TranscriptExcerpt(segmentId: item.id, text: text)],
                        metadata: job.metadata ?? [:]))
                line["text"] = .string(result.text)
                line["model"] = result.modelUsed.map(JSONValue.string) ?? .null
                line["inputTokens"] = result.inputTokens.map { .number(Double($0)) } ?? .null
                line["outputTokens"] = result.outputTokens.map { .number(Double($0)) } ?? .null
                line["truncated"] = .bool(result.inputTruncated)
            case .openAiRaw:
                guard let key = openAiKey(), !key.isEmpty else {
                    throw AiError.providerUnavailable(providerId: "openai")
                }
                let path = job.path ?? "/v1/models"
                guard path.hasPrefix("/v1/") else { throw AiError.providerFailed("path must start /v1/") }
                var body = item.body
                if let clip = item.clip {
                    let clipURL = root.appendingPathComponent(clip)
                    guard clipURL.path.hasPrefix(root.path) else {
                        throw AiError.providerFailed("clip outside analysis/")
                    }
                    let audio = try Data(contentsOf: clipURL)
                    body = body?.replacing(Self.clipPlaceholder, with: audio.base64EncodedString())
                }
                let response = try await transport.execute(
                    HttpTransportRequest(
                        method: job.method ?? (body == nil ? "GET" : "POST"),
                        url: Self.openAiHost + path,
                        headers: [
                            "Authorization": "Bearer \(key)", "Content-Type": "application/json",
                        ],
                        body: try body.map { try JSONEncoder().encode($0) },
                        carriesAudio: item.clip != nil))
                line["status"] = .number(Double(response.status))
                line["text"] = .string(String(response.text.prefix(200_000)))
                if !response.isSuccess { throw AiError.providerFailed("HTTP \(response.status)") }
            }
            line["ok"] = .bool(true)
        } catch {
            line["ok"] = .bool(false)
            line["error"] = .string(String(describing: error).prefix(600).description)
        }
        line["ms"] = .number((Date().timeIntervalSince(started) * 1000).rounded())
        return line
    }

    static func completedIds(_ url: URL) -> Set<String> {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var ids = Set<String>()
        for line in text.split(whereSeparator: \.isNewline) {
            if let object = try? JSONDecoder().decode([String: JSONValue].self, from: Data(line.utf8)),
                case .string(let id)? = object["id"]
            {
                ids.insert(id)
            }
        }
        return ids
    }

    static func append(_ line: [String: JSONValue], to url: URL) {
        guard var data = try? JSONEncoder().encode(line) else { return }
        data.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
