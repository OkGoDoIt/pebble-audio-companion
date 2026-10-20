import AppDB
import Foundation
import GRDB
import Receiver

// The phone half of the Pebble Audio archive sync (`server/docs/sync-protocol.md`).
//
// SHAPE OF A PASS
//
//  1. Nothing at all unless a server is linked, the switch is on, the server has not refused
//     this phone, and — for the passes the pipeline asks for — something changed or the server
//     said it has requests waiting. A pass with nothing to send reads one in-memory flag and
//     publishes nothing.
//  2. A pending "Delete all" goes first (`POST /sync/wipe`): nothing may be sent after a wipe
//     that the wipe should have removed.
//  3. The outbox drains in batches (≤ 200 items, ≤ 8 MB), oldest change first. Each batch is a
//     file uploaded on a BACKGROUND session, so it reaches the server even if the app is
//     suspended a second later, and the answer is applied whenever it arrives — this process or
//     the next. Answers are idempotent (`ArchiveOutbox.acknowledge`), and the server ignores a
//     version it has, so a batch lost to a kill is simply sent again.
//  4. The server's requests are pulled and answered: clips remuxed from the stored Speex frames,
//     follow-ups and notes written to the local stores.
//
// WHEN IT RUNS
//
//  - After a pipeline pass that changed something the server cares about (the change gate),
//    and on any pass once the outbox itself has changed (`ArchiveOutboxSignal`).
//  - Every 30 s while the app is on screen (the contract's request poll), on background entry,
//    in the BGProcessing window, and when the person links, turns the switch on, or asks.

/// What asked for a pass.
public enum ArchiveSyncTrigger: String, Sendable {
    /// A pipeline pass; `changed` is whether it changed anything the archive holds.
    case pipeline
    case foregroundTick
    case backgroundEntry
    case backgroundTask
    case linked
    case settings
    case userAsked
    case requestsWaiting
}

/// What the Settings screen shows. Published only when it changes.
public struct ArchiveSyncStatus: Equatable, Sendable {
    public enum Link: Equatable, Sendable {
        case notLinked
        case linked(host: String)
        /// The server answered 401: the token is gone (unlinked from the server's side).
        case revoked(host: String)
    }

    public var link: Link = .notLinked
    public var enabled = false
    public var sending = false
    public var lastBatchAtMs: Int64?
    public var pending = 0
    public var parked = 0
    public var lastError: String?
    public var appTooOld = false
    public var wipePending = false
    public var server: ArchiveServerStatus?
    public var serverStatusAtMs: Int64?

    public init() {}
}

/// Set whenever a write touches the outbox, so a pass knows whether looking is worth it.
final class ArchiveOutboxSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var dirty = true
    private var observer: AnyDatabaseCancellable?

    func mark() { lock.withLock { dirty = true } }

    /// True once per change: reading clears it.
    func take() -> Bool {
        lock.withLock {
            defer { dirty = false }
            return dirty
        }
    }

    func observe(_ writer: any DatabaseWriter) {
        let observation = DatabaseRegionObservation(tracking: Table("sync_outbox"))
        let cancellable = observation.start(
            in: writer, onError: { _ in }, onChange: { [weak self] _ in self?.mark() })
        lock.withLock { observer = cancellable }
    }
}

public actor ArchiveSyncService {
    public struct Dependencies: Sendable {
        public var outbox: ArchiveOutbox
        public var builder: ArchivePayloadBuilder
        public var requests: ArchiveRequestHandler
        public var http: any ArchiveHTTP
        public var uploads: any ArchiveUploading
        public var settings: @Sendable () -> ArchiveSyncSettings
        public var token: @Sendable () -> String?
        /// `<container>/archive-sync`: the state file, batch bodies, clip files.
        public var directory: URL
        public var clock: RuntimeClock
        public var isForeground: @Sendable () -> Bool
        /// Plugged in: a backgrounded pass may then drain more than one batch.
        public var isCharging: @Sendable () -> Bool
        public var log: RuntimeLog

        public init(
            outbox: ArchiveOutbox, builder: ArchivePayloadBuilder, requests: ArchiveRequestHandler,
            http: any ArchiveHTTP, uploads: any ArchiveUploading,
            settings: @escaping @Sendable () -> ArchiveSyncSettings,
            token: @escaping @Sendable () -> String?, directory: URL, clock: RuntimeClock,
            isForeground: @escaping @Sendable () -> Bool, isCharging: @escaping @Sendable () -> Bool,
            log: RuntimeLog = .silent
        ) {
            self.outbox = outbox
            self.builder = builder
            self.requests = requests
            self.http = http
            self.uploads = uploads
            self.settings = settings
            self.token = token
            self.directory = directory
            self.clock = clock
            self.isForeground = isForeground
            self.isCharging = isCharging
            self.log = log
        }
    }

    /// What survives a relaunch.
    struct PersistedState: Codable, Equatable {
        var lastBatchAtMs: Int64?
        var lastError: String?
        /// The device id the server refused (401). Linking again (a new id) clears it.
        var revokedDeviceId: String?
        var appTooOld = false
        var wipePending = false
        var maxItems = ArchiveSyncProtocol.maxItemsPerBatch
        var failures = 0
        var nextAttemptAtMs: Int64?
        var inFlightBatchId: String?
        var inFlightSinceMs: Int64?
        /// Clip request ids being uploaded, and since when.
        var clipsInFlight: [String: Int64] = [:]
    }

    public nonisolated let status = StateSubject(ArchiveSyncStatus())

    private let deps: Dependencies
    private let signal = ArchiveOutboxSignal()
    private var state = PersistedState()
    private var started = false
    private var running = false
    private var rerun = false
    private var requestsDue = true
    private var lastRequestPullMs: Int64?
    private var foregroundTask: Task<Void, Never>?
    private var outcomeTask: Task<Void, Never>?
    private var waiters: [String: CheckedContinuation<Bool, Never>] = [:]

    /// Requests are pulled at most this often by the passes that run anyway.
    static let requestPullIntervalMs: Int64 = 30_000
    /// The contract's request poll while the app is on screen.
    static let foregroundTickMs: Int64 = 30_000
    /// How long a pass waits for a batch's answer before leaving it to arrive on its own.
    static let answerWaitMs: Int64 = 45_000
    /// A batch with no answer and no task after this long is presumed lost and sent again.
    static let lostBatchMs: Int64 = 30 * 60_000

    public init(_ deps: Dependencies) {
        self.deps = deps
    }

    private var stateURL: URL { deps.directory.appendingPathComponent("state.json") }

    // MARK: - Lifecycle

    /// Loads the saved state, listens for answers, and watches the outbox. Idempotent.
    public func start() async {
        guard !started else { return }
        started = true
        try? FileManager.default.createDirectory(at: deps.directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: stateURL),
            let saved = try? JSONDecoder().decode(PersistedState.self, from: data)
        {
            state = saved
        }
        signal.observe(deps.outbox.db.writer)
        let uploads = deps.uploads
        outcomeTask = Task { [weak self] in
            for await outcome in uploads.outcomes {
                await self?.handle(outcome)
            }
        }
        await uploads.reconnect()
        await alignRecording()
        await publish(refreshCounts: true)
    }

    /// A linked phone records changes; an unlinked one does not, and holds none. Recording that
    /// starts here (a link the app stored but never reported, because it was killed in between)
    /// starts from the whole library, exactly as `didLink` does.
    private func alignRecording() async {
        let linked = deps.settings().isLinked
        let active = (try? await deps.outbox.isActive()) ?? false
        guard linked != active else { return }
        do {
            try await deps.outbox.setActive(linked)
            if linked { try await deps.outbox.markEverything() }
        } catch {
            deps.log.failure("archive sync recording", error)
        }
    }

    public func setForeground(_ foreground: Bool) {
        foregroundTask?.cancel()
        foregroundTask = nil
        guard foreground else { return }
        let clock = deps.clock
        foregroundTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pass(.foregroundTick)
                try? await clock.sleep(ms: Self.foregroundTickMs)
            }
        }
    }

    /// The pipeline's hook, at the end of every pass. Cheap when nothing changed: an in-memory
    /// flag and nothing else.
    public func pipelinePassFinished(changed: Bool) async {
        let outboxChanged = signal.take()
        guard changed || outboxChanged || requestsPulledDue() else { return }
        await pass(.pipeline)
    }

    private func requestsPulledDue() -> Bool {
        guard requestsDue else { return false }
        guard let last = lastRequestPullMs else { return true }
        return deps.clock.nowMs - last >= Self.requestPullIntervalMs
    }

    /// The BGProcessing window, background entry, and the person's own taps.
    public func pass(_ trigger: ArchiveSyncTrigger) async {
        if running {
            rerun = true
            return
        }
        running = true
        defer { running = false }
        var rounds = 0
        repeat {
            rerun = false
            rounds += 1
            await passOnce(trigger)
        } while rerun && rounds < 3
    }

    // MARK: - Linking (the app writes the settings and the Keychain; this talks to the server)

    public enum LinkError: Error, Equatable, Sendable {
        case badOrigin
        case codeRefused
        case server(Int)
        case network(String)
        case malformed
    }

    /// `POST /link`. Returns the device id and token for the app to store.
    public func link(
        code: String, origin: URL, deviceName: String, appVersion: String, appBuild: String
    ) async throws -> ArchiveLinkResponse {
        guard ArchiveEndpoint.acceptableOrigin(origin.absoluteString) != nil else {
            throw LinkError.badOrigin
        }
        var request = URLRequest(url: ArchiveEndpoint.url(origin, "/link"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(ArchiveSyncProtocol.version, forHTTPHeaderField: "X-Sync-Protocol")
        request.httpBody = try JSONEncoder().encode(
            ArchiveLinkRequest(
                code: ArchiveLinkInvitation.normalizedCode(code), deviceName: deviceName,
                appVersion: appVersion, appBuild: appBuild))
        let response: ArchiveHTTPResponse
        do { response = try await deps.http.send(request) } catch {
            throw LinkError.network((error as NSError).localizedDescription)
        }
        switch response.status {
        case 200, 201:
            guard let linked = try? JSONDecoder().decode(ArchiveLinkResponse.self, from: response.body)
            else { throw LinkError.malformed }
            return linked
        case 400, 404, 409, 410: throw LinkError.codeRefused
        default: throw LinkError.server(response.status)
        }
    }

    /// The app has stored the new link: start recording changes from the whole library.
    public func didLink() async {
        state = PersistedState()
        save()
        do {
            try await deps.outbox.setActive(false)
            try await deps.outbox.setActive(true)
            let marked = try await deps.outbox.markEverything()
            deps.log.write("archive sync: linked; \(marked) items to send")
        } catch {
            deps.log.failure("archive sync link", error)
        }
        requestsDue = true
        await publish(refreshCounts: true)
        await pass(.linked)
    }

    /// `DELETE /link`, best effort (the server keeps the data and revokes the token), then
    /// stop recording. The app clears the settings and the Keychain.
    public func unlink() async {
        if let endpoint = endpoint() {
            _ = try? await deps.http.send(endpoint.request("DELETE", "/link"))
        }
        try? await deps.outbox.setActive(false)
        state = PersistedState()
        save()
        status.value = ArchiveSyncStatus()
    }

    /// The switch, or the link, changed in Settings.
    public func settingsChanged() async {
        let settings = deps.settings()
        await alignRecording()
        await publish(refreshCounts: false)
        if settings.isLinked, settings.enabled { await pass(.settings) }
    }

    // MARK: - Delete all

    /// Before "Delete all" wipes the library: stop recording, so the thousands of deletes it
    /// writes are never sent one by one.
    public func willWipeLocally() async {
        guard deps.settings().isLinked else { return }
        try? await deps.outbox.setActive(false)
    }

    /// After it: the server is wiped by its own endpoint, then sent whatever is left (people,
    /// hand-written follow-ups).
    public func didWipeLocally() async {
        guard deps.settings().isLinked else { return }
        state.wipePending = true
        save()
        do {
            try await deps.outbox.setActive(true)
            try await deps.outbox.markEverything()
        } catch {
            deps.log.failure("archive sync wipe", error)
        }
        await publish(refreshCounts: true)
        await pass(.userAsked)
    }

    // MARK: - Background session events

    public func reconnect() async {
        await deps.uploads.reconnect()
    }

    // MARK: - The pass

    private func endpoint() -> ArchiveEndpoint? {
        let settings = deps.settings()
        guard let originText = settings.origin, let deviceId = settings.deviceId,
            let origin = URL(string: originText), let token = deps.token(), !token.isEmpty
        else { return nil }
        return ArchiveEndpoint(origin: origin, deviceId: deviceId, token: token)
    }

    private func passOnce(_ trigger: ArchiveSyncTrigger) async {
        // The settings first: an unlinked phone or an off switch costs no Keychain read.
        let settings = deps.settings()
        guard settings.isLinked, settings.enabled, !state.appTooOld,
            state.revokedDeviceId != settings.deviceId, let endpoint = endpoint()
        else { return }
        let now = deps.clock.nowMs
        let asked = trigger == .userAsked || trigger == .linked || trigger == .settings
        if let next = state.nextAttemptAtMs, now < next, !asked { return }

        if state.wipePending {
            guard await wipe(endpoint) else { return }
        }

        // One batch in flight at a time. Its answer is applied whenever it arrives; one with
        // no task left behind it was lost, and its items are simply still pending.
        if let inFlight = state.inFlightBatchId {
            let alive = await deps.uploads.inFlight().contains("batch:\(inFlight)")
            if alive, now - (state.inFlightSinceMs ?? now) < Self.lostBatchMs {
                return
            }
            clearInFlight(inFlight)
        }

        let foreground = deps.isForeground()
        let maxBatches = foreground || deps.isCharging() ? 50 : 2
        var sent = 0
        var pages = 0
        while sent < maxBatches, pages < maxBatches * 4 {
            pages += 1
            let batch: Batch?
            do { batch = try await buildBatch(endpoint) } catch {
                note(error: "Could not prepare changes: \(error)")
                break
            }
            guard let batch else { break }
            if batch.items.isEmpty { continue }  // a page of unchanged rows, cleared
            guard await submit(batch, endpoint) else { break }
            sent += 1
            guard await awaitAnswer(batch.id) else { break }
            if state.failures > 0 || state.revokedDeviceId != nil || state.appTooOld { break }
        }

        if requestsDue || trigger == .foregroundTick || trigger == .backgroundTask
            || trigger == .userAsked || trigger == .requestsWaiting || sent > 0
        {
            await pullRequests(endpoint)
        }
        if sent > 0 { await publish(refreshCounts: true) }
    }

    // MARK: - Batches

    struct Batch {
        var id: String
        var items: [Data]
        var sent: [ArchiveSentItem]
    }

    /// The next page of pending rows as a batch: nil when nothing is pending, empty when every
    /// row on the page turned out to need nothing sent (each is cleared on the way).
    private func buildBatch(_ endpoint: ArchiveEndpoint) async throws -> Batch? {
        let rows = try await deps.outbox.pending(limit: state.maxItems)
        guard !rows.isEmpty else { return nil }
        var items: [Data] = []
        var sent: [ArchiveSentItem] = []
        var bytes = 512
        for row in rows {
            let key = ArchiveItemKey(kind: row.kind, entityId: row.entityId, version: row.version)
            var item: ArchiveBatchItem
            switch row.op {
            case .upsert:
                let built: ArchiveBuilt
                do { built = try await deps.builder.build(row) } catch {
                    try await deps.outbox.reject(
                        kind: row.kind, id: row.entityId, reason: "not built: \(error)")
                    continue
                }
                switch built {
                case .payload(let data, let hash, let pieceKey):
                    item = ArchiveBatchItem(
                        key: key, op: .upsert, changedAtMs: row.changedAtMs, payload: data,
                        hash: hash, pieceKey: pieceKey)
                case .unchanged(let hash, let pieceKey):
                    try await deps.outbox.markUnchanged(key, hash: hash, pieceKey: pieceKey)
                    continue
                case .gone:
                    try await deps.outbox.convertToDelete(key)
                    item = ArchiveBatchItem(
                        key: key, op: .delete, changedAtMs: row.changedAtMs, payload: nil,
                        hash: nil, pieceKey: nil)
                }
            case .delete, .expire:
                item = ArchiveBatchItem(
                    key: key, op: row.op, changedAtMs: row.changedAtMs, payload: nil, hash: nil,
                    pieceKey: nil)
            }
            let encoded = try item.encoded()
            if encoded.count + 512 > ArchiveSyncProtocol.maxBatchBytes {
                try await deps.outbox.reject(
                    kind: row.kind, id: row.entityId,
                    reason: "too large to send (\(encoded.count / 1024) KB)")
                continue
            }
            if bytes + encoded.count + 1 > ArchiveSyncProtocol.maxBatchBytes, !items.isEmpty { break }
            bytes += encoded.count + 1
            items.append(encoded)
            sent.append(ArchiveSentItem(key: key, hash: item.hash, pieceKey: item.pieceKey))
        }
        return Batch(id: UUID().uuidString.lowercased(), items: items, sent: sent)
    }

    private func batchFile(_ id: String) -> URL {
        deps.directory.appendingPathComponent("batch-\(id).json")
    }

    private func submit(_ batch: Batch, _ endpoint: ArchiveEndpoint) async -> Bool {
        do {
            let body = try ArchiveBatchBody.encode(
                deviceId: endpoint.deviceId, sentAtMs: deps.clock.nowMs, items: batch.items)
            try body.write(to: batchFile(batch.id), options: .atomic)
            try await deps.outbox.markInFlight(batch.sent)
        } catch {
            note(error: "Could not prepare changes: \(error)")
            return false
        }
        state.inFlightBatchId = batch.id
        state.inFlightSinceMs = deps.clock.nowMs
        save()
        var status = self.status.value
        status.sending = true
        self.status.value = status
        await deps.uploads.upload(
            endpoint.request("PUT", "/sync/batch"), fromFile: batchFile(batch.id),
            description: "batch:\(batch.id)")
        return true
    }

    /// Waits for a batch's answer, up to `answerWaitMs`. False when it has not come yet; it
    /// is applied when it does.
    private func awaitAnswer(_ id: String) async -> Bool {
        guard state.inFlightBatchId == id else { return true }  // already answered
        let clock = deps.clock
        let timeout = Task { [weak self] in
            try? await clock.sleep(ms: Self.answerWaitMs)
            await self?.resumeWaiter(id, answered: false)
        }
        defer { timeout.cancel() }
        return await withCheckedContinuation { continuation in
            waiters[id] = continuation
        }
    }

    private func resumeWaiter(_ id: String, answered: Bool) {
        waiters.removeValue(forKey: id)?.resume(returning: answered)
    }

    private func clearInFlight(_ id: String) {
        try? FileManager.default.removeItem(at: batchFile(id))
        if state.inFlightBatchId == id {
            state.inFlightBatchId = nil
            state.inFlightSinceMs = nil
            save()
        }
    }

    // MARK: - Answers

    func handle(_ outcome: ArchiveUploadOutcome) async {
        if outcome.description.hasPrefix("batch:") {
            let id = String(outcome.description.dropFirst("batch:".count))
            await handleBatchAnswer(id: id, outcome)
            clearInFlight(id)
            var status = self.status.value
            status.sending = false
            self.status.value = status
            resumeWaiter(id, answered: true)
            await publish(refreshCounts: true)
        } else if outcome.description.hasPrefix("clip:") {
            let id = String(outcome.description.dropFirst("clip:".count))
            state.clipsInFlight[id] = nil
            save()
            try? FileManager.default.removeItem(
                at: deps.requests.sources.temporaryDirectory.appendingPathComponent(
                    "clip-\(ArchiveRequestHandler.safe(id)).ogg"))
            if !(200..<300).contains(outcome.status) {
                deps.log.write(
                    "archive sync: clip \(id) not stored (\(outcome.status) \(outcome.error ?? ""))")
            }
        }
    }

    private func handleBatchAnswer(id: String, _ outcome: ArchiveUploadOutcome) async {
        let now = deps.clock.nowMs
        if let error = outcome.error {
            backOff("Could not reach the server: \(error)")
            return
        }
        switch outcome.status {
        case 200:
            guard
                let response = try? JSONDecoder().decode(ArchiveBatchResponse.self, from: outcome.body)
            else {
                backOff("The server's answer could not be read.")
                return
            }
            do {
                let cleared = try await deps.outbox.acknowledge(response.held)
                var parked = 0
                for rejected in response.rejected {
                    guard let kind = ArchiveEntityKind(rawValue: rejected.kind) else { continue }
                    if try await deps.outbox.reject(
                        kind: kind, id: rejected.id, reason: rejected.reason ?? "rejected")
                    {
                        parked += 1
                    }
                    deps.log.write(
                        "archive sync: server rejected \(rejected.kind) \(rejected.id): \(rejected.reason ?? "")")
                }
                deps.log.write(
                    "archive sync: batch \(id.prefix(8)) — \(response.accepted.count) accepted, "
                        + "\(response.ignored.count) already held, \(response.rejected.count) rejected, "
                        + "\(cleared) cleared")
                if parked > 0 { note(error: "Some changes could not be synced.") }
            } catch {
                deps.log.failure("archive sync answer", error)
            }
            state.lastBatchAtMs = now
            state.failures = 0
            state.nextAttemptAtMs = nil
            if response.rejected.isEmpty { state.lastError = nil }
            state.maxItems = min(ArchiveSyncProtocol.maxItemsPerBatch, state.maxItems * 2)
            if response.pendingRequests > 0 { requestsDue = true; rerun = true }
            save()
        case 401:
            state.revokedDeviceId = deps.settings().deviceId
            state.lastError = nil
            save()
            deps.log.write("archive sync: the server no longer accepts this phone (401)")
        case 413:
            state.maxItems = max(1, state.maxItems / 2)
            save()
            rerun = true
        case 426:
            state.appTooOld = true
            save()
        default:
            backOff("The server answered \(outcome.status).")
        }
    }

    private func backOff(_ message: String) {
        state.failures += 1
        let delay = min(Int64(30_000) << Int64(min(state.failures - 1, 6)), 30 * 60_000)
        state.nextAttemptAtMs = deps.clock.nowMs + delay
        state.lastError = message
        save()
        deps.log.write("archive sync: \(message) Next try in \(delay / 1000) s.")
    }

    private func note(error: String) {
        state.lastError = error
        save()
    }

    // MARK: - Wipe

    private func wipe(_ endpoint: ArchiveEndpoint) async -> Bool {
        var request = endpoint.request("POST", "/sync/wipe")
        request.httpBody = Data("{\"confirm\":\"wipe\"}".utf8)
        do {
            let response = try await deps.http.send(request)
            switch response.status {
            case 200..<300:
                state.wipePending = false
                save()
                deps.log.write("archive sync: server wiped")
                await publish(refreshCounts: false)
                return true
            case 401:
                state.revokedDeviceId = endpoint.deviceId
                save()
                await publish(refreshCounts: false)
                return false
            default:
                backOff("The server did not delete its copy (\(response.status)).")
                return false
            }
        } catch {
            backOff("Could not reach the server: \((error as NSError).localizedDescription)")
            return false
        }
    }

    // MARK: - Requests

    private func pullRequests(_ endpoint: ArchiveEndpoint) async {
        lastRequestPullMs = deps.clock.nowMs
        let list: ArchiveRequestsResponse
        do {
            let response = try await deps.http.send(endpoint.request("GET", "/sync/requests", json: false))
            guard response.status == 200 else {
                if response.status == 401 {
                    state.revokedDeviceId = endpoint.deviceId
                    save()
                    await publish(refreshCounts: false)
                }
                return
            }
            list = try JSONDecoder().decode(ArchiveRequestsResponse.self, from: response.body)
        } catch {
            return
        }
        requestsDue = false
        let now = deps.clock.nowMs
        // A clip whose upload has gone quiet for an hour is offered again.
        state.clipsInFlight = state.clipsInFlight.filter { now - $0.value < 60 * 60_000 }
        for request in list.requests where state.clipsInFlight[request.id] == nil {
            switch await deps.requests.handle(request) {
            case .result(let result):
                await post(result, for: request.id, endpoint)
            case .clip(let clip):
                var put = endpoint.request("PUT", "/sync/clips/\(request.id)", json: false)
                put.setValue("audio/ogg", forHTTPHeaderField: "Content-Type")
                put.setValue(ArchiveTime.string(clip.startMs), forHTTPHeaderField: "X-Clip-Start-At")
                put.setValue(ArchiveTime.string(clip.endMs), forHTTPHeaderField: "X-Clip-End-At")
                put.setValue(clip.gapsHeader, forHTTPHeaderField: "X-Clip-Gaps")
                state.clipsInFlight[request.id] = now
                save()
                await deps.uploads.upload(put, fromFile: clip.file, description: "clip:\(request.id)")
            }
        }
    }

    private func post(_ result: ArchiveRequestResult, for id: String, _ endpoint: ArchiveEndpoint) async {
        var request = endpoint.request("POST", "/sync/requests/\(id)/result")
        request.httpBody = try? JSONEncoder().encode(result)
        _ = try? await deps.http.send(request)
    }

    // MARK: - Status

    /// `GET /sync/status`, for the Settings screen while it is on screen.
    public func refreshServerStatus() async {
        await publish(refreshCounts: true)
        guard let endpoint = endpoint() else { return }
        guard
            let response = try? await deps.http.send(endpoint.request("GET", "/sync/status", json: false))
        else { return }
        if response.status == 401 {
            state.revokedDeviceId = endpoint.deviceId
            save()
            await publish(refreshCounts: false)
            return
        }
        guard response.status == 200,
            let server = try? JSONDecoder().decode(ArchiveServerStatus.self, from: response.body)
        else { return }
        var status = self.status.value
        status.server = server
        status.serverStatusAtMs = deps.clock.nowMs
        self.status.value = status
    }

    /// The person tapped "Sync now".
    public func syncNow() async {
        requestsDue = true
        await pass(.userAsked)
        await publish(refreshCounts: true)
    }

    private func publish(refreshCounts: Bool) async {
        var next = status.value
        let settings = deps.settings()
        if let origin = settings.origin, settings.isLinked {
            let host = URL(string: origin)?.host ?? origin
            next.link = state.revokedDeviceId == settings.deviceId ? .revoked(host: host) : .linked(host: host)
        } else {
            next.link = .notLinked
        }
        next.enabled = settings.enabled
        next.lastBatchAtMs = state.lastBatchAtMs
        next.lastError = state.lastError
        next.appTooOld = state.appTooOld
        next.wipePending = state.wipePending
        if refreshCounts, let counts = try? await deps.outbox.counts() {
            next.pending = counts.pending
            next.parked = counts.parked
            if counts.parked > 0, next.lastError == nil { next.lastError = counts.lastParkedError }
        }
        status.value = next
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }
}
