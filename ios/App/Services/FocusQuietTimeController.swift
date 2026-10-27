import AppIntents
import CompanionRuntime
import Foundation
import Observation
import Receiver
import UIKit
import WireProtocol

/// One serialized writer. The extension owns Focus state; the app alone owns BLE.
@MainActor @Observable
final class FocusQuietTimeController {
    static let shared = FocusQuietTimeController()

    enum Status: Equatable {
        case off, checking, waitingForWatch, needsFirmware, syncing, following, ready, retry
    }
    enum Delivery { case applied, retry }
    private(set) var enabled: Bool
    private(set) var status: Status = .off
    private(set) var filterQuiet = false
    private let defaults: UserDefaults
    private let readSystem: @Sendable () async throws -> Bool
    private var send: (@Sendable (Bool) async -> Delivery)?
    private var updateLink: (@Sendable (Bool) async -> Void)?
    private var connected = false
    private var supported = false
    private var known = false
    private var generation = 0
    private var lastApplied: Bool?
    private var lastRevision: UUID?
    private var writing = false
    private var reading = false
    private var needsRelease = false
    private var observer: FocusQuietTimeObserver?
    private var foregroundObserver: NSObjectProtocol?
    private var stateTask: Task<Void, Never>?

    init(defaults: UserDefaults = SharedAppGroup.defaults,
         readSystem: @escaping @Sendable () async throws -> Bool = {
             do { return try await QuietTimeFocusFilter.current.quietTime }
             catch SetFocusFilterIntentError.notFound { return false }
         }, send: (@Sendable (Bool) async -> Delivery)? = nil) {
        self.defaults = defaults
        self.readSystem = readSystem
        self.send = send
        enabled = defaults.bool(forKey: FocusQuietTimeBridge.enabledKey)
        status = enabled ? .checking : .off
        lastRevision = FocusQuietTimeBridge.state(in: defaults)?.revision
    }

    func start(receiver: ReceiverService) {
        guard stateTask == nil else { return }
        updateLink = { await receiver.setFocusQuietLink($0) }
        Task { await updateLink?(enabled) }
        send = { quiet in
            let reply = await receiver.sendControlRequest {
                PhoneFocusState(requestToken: $0, enabled: quiet).encode()
            }
            return reply == .ok ? .applied : .retry
        }
        observer = FocusQuietTimeObserver { [weak self] in
            Task { @MainActor in self?.refreshFromBridge() }
        }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refreshSystem() }
        }
        stateTask = Task { [weak self] in
            for await state in receiver.state.stream() {
                guard let self, !Task.isCancelled else { return }
                let ready = state == .authorized || state.isStreaming
                let capable = (receiver.watchInfo.value?.watchCapabilities ?? 0)
                    & ProtocolConstants.capabilityPhoneFocus != 0
                self.connectionChanged(connected: ready, supported: capable)
            }
        }
        Task { await refreshSystem() }
    }

    func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        enabled = value
        if value { known = false }
        defaults.set(value, forKey: FocusQuietTimeBridge.enabledKey)
        Task { await updateLink?(enabled) }
        if !value { needsRelease = connected }
        reconcile()
        if value { Task { await refreshSystem() } }
    }

    func connectionChanged(connected: Bool, supported: Bool) {
        guard self.connected != connected || self.supported != supported else { return }
        generation += 1
        self.connected = connected
        self.supported = supported
        lastApplied = nil
        if !connected { needsRelease = false }
        // Re-read the system before reconnecting: the extension may have changed while the
        // app was suspended, or its event may have been missed.
        if connected && enabled {
            known = false
            Task { await refreshSystem() }
        }
        reconcile()
    }

    /// Called by Darwin delivery and the existing one-minute liveness pulse (no new timer).
    /// Darwin notifications do not launch an app that iOS has suspended or terminated.
    func refreshFromBridge() {
        if let state = FocusQuietTimeBridge.state(in: defaults), state.revision != lastRevision {
            lastRevision = state.revision
            filterQuiet = state.quiet
            known = true
        }
        reconcile()
    }

    func refreshSystem() async {
        guard enabled, !reading else { return }
        reading = true
        let revision = FocusQuietTimeBridge.state(in: defaults)?.revision
        let queryGeneration = generation
        do {
            let quiet = try await readSystem()
            guard queryGeneration == generation else {
                reading = false
                await refreshSystem()
                return
            }
            if FocusQuietTimeBridge.state(in: defaults)?.revision == revision {
                lastRevision = revision
                filterQuiet = quiet
                known = true
            } else if let latest = FocusQuietTimeBridge.state(in: defaults) {
                lastRevision = latest.revision
                filterQuiet = latest.quiet
                known = true
            }
        } catch {
            // Unknown is not Off. Preserve an already-known state after a transient query
            // failure, but never replay an old persisted On merely because lookup failed.
            AppRuntimeLog.shared.record("focus: current filter unavailable")
        }
        reading = false
        reconcile()
    }

    private func reconcile() {
        if !enabled && !needsRelease { status = .off; return }
        guard connected else { status = enabled ? .waitingForWatch : .off; return }
        guard supported else { status = enabled ? .needsFirmware : .off; return }
        guard !enabled || known else { status = .checking; return }
        let desired = enabled && filterQuiet
        if lastApplied == desired {
            needsRelease = false
            status = enabled ? (desired ? .following : .ready) : .off
            return
        }
        status = .syncing
        guard !writing, let send else { return }
        writing = true
        let sentGeneration = generation
        Task {
            let result = await send(desired)
            writing = false
            if generation != sentGeneration {
                // A late ACK belongs to the old connection, never the current watch.
                reconcile()
                return
            }
            switch result {
            case .applied:
                lastApplied = desired
                reconcile() // also drains a newer On/Off value that arrived during the write
            case .retry:
                status = .retry
                // A superseding value should not wait for the next reconnect/heartbeat.
                if (enabled && filterQuiet) != desired { reconcile() }
            }
        }
    }
}
