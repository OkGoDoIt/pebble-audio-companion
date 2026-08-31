import Foundation

#if canImport(Speech)
    import Speech
#endif

// The Settings "Local model" row's engine (M3 decision: Apple SpeechAnalyzer). The system —
// not the app — owns the language-model assets: `AssetInventory` reports their status and
// hands out `AssetInstallationRequest`s. This file wraps that behind small protocols so the
// Settings UI and tests never touch the live system services.

/// Installation status of the on-device speech assets for one locale.
public enum SpeechAssetStatus: Equatable, Sendable {
    case unsupported
    /// Supported but not installed (a download would be required).
    case supported
    /// A system download is already in flight (possibly started by another app).
    case downloading
    case installed
}

/// One in-flight asset installation: progress fractions (0…1) stream until the install
/// finishes; the stream throws on failure. Deterministic to fake in tests.
public protocol SpeechAssetInstalling: Sendable {
    func install() -> AsyncThrowingStream<Double, Error>
}

/// The `AssetInventory` seam (faked in tests, `SystemSpeechAssetInventory` in production).
public protocol SpeechAssetInventorying: Sendable {
    func status(for locale: Locale) async -> SpeechAssetStatus
    /// Nil when nothing needs downloading (assets already present).
    func installationRequest(for locale: Locale) async throws -> (any SpeechAssetInstalling)?
    /// Releases the locale reservation so the system may reclaim its assets.
    func release(locale: Locale) async
}

/// State shown on the Settings "Local model" row.
public enum LocalModelState: Equatable, Sendable {
    case unsupported
    case notInstalled
    /// Wi-Fi-only downloads are on and the device is not on Wi-Fi; the download is deferred,
    /// not failed.
    case waitingForWiFi
    case downloading(progress: Double)
    case installed
    case failed(message: String)
}

/// Protocol the Settings UI talks to (mockable).
public protocol LocalModelManaging: Sendable {
    func currentState() async -> LocalModelState
    /// Re-reads the system inventory and returns the refreshed state.
    func refresh() async -> LocalModelState
    /// Starts (or re-attempts) the install and returns the terminal state of the attempt.
    func requestInstall() async -> LocalModelState
    func uninstall() async -> LocalModelState
    /// Live state updates for the row (buffered; safe to subscribe before acting).
    func states() async -> AsyncStream<LocalModelState>
}

/// Drives AssetInventory install/uninstall for the transcriber's language assets and reports
/// calm row state. The Wi-Fi-only preference is honored at download START — the system API
/// exposes no network constraint on the download itself, so gating the start is where the
/// preference can be honored.
public actor LocalModelManager: LocalModelManaging {
    private let locale: Locale
    private let inventory: any SpeechAssetInventorying
    private let wifiOnly: @Sendable () -> Bool
    private let isOnWiFi: @Sendable () -> Bool

    private var state: LocalModelState = .notInstalled
    private var observers: [UUID: AsyncStream<LocalModelState>.Continuation] = [:]
    private var installing = false

    public init(
        locale: Locale = .current,
        inventory: any SpeechAssetInventorying,
        wifiOnly: @escaping @Sendable () -> Bool = { false },
        isOnWiFi: @escaping @Sendable () -> Bool = { true }
    ) {
        self.locale = locale
        self.inventory = inventory
        self.wifiOnly = wifiOnly
        self.isOnWiFi = isOnWiFi
    }

    public func currentState() -> LocalModelState { state }

    public func refresh() async -> LocalModelState {
        if installing { return state }
        let mapped = mappedState(await inventory.status(for: locale))
        // Keep a failure message visible until the user retries or the install succeeds.
        if case .failed = state, mapped == .notInstalled { return state }
        setState(mapped)
        return state
    }

    public func requestInstall() async -> LocalModelState {
        if installing { return state }
        switch await inventory.status(for: locale) {
        case .unsupported:
            setState(.unsupported)
            return state
        case .installed:
            setState(.installed)
            return state
        case .supported, .downloading:
            break
        }
        if wifiOnly() && !isOnWiFi() {
            setState(.waitingForWiFi)
            return state
        }
        installing = true
        defer { installing = false }
        setState(.downloading(progress: 0))
        do {
            guard let request = try await inventory.installationRequest(for: locale) else {
                // Nothing to download — the assets are already present.
                setState(.installed)
                return state
            }
            for try await progress in request.install() {
                setState(.downloading(progress: min(max(progress, 0), 1)))
            }
            setState(.installed)
        } catch {
            setState(
                .failed(message: "The download didn't finish. Check your connection and try again.")
            )
        }
        return state
    }

    public func uninstall() async -> LocalModelState {
        await inventory.release(locale: locale)
        setState(.notInstalled)
        return state
    }

    public func states() -> AsyncStream<LocalModelState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<LocalModelState>.makeStream()
        continuation.onTermination = { [weak self] _ in
            Task { [weak self] in await self?.removeObserver(id) }
        }
        observers[id] = continuation
        continuation.yield(state)
        return stream
    }

    private func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    private func setState(_ new: LocalModelState) {
        guard new != state else { return }
        state = new
        for continuation in observers.values {
            continuation.yield(new)
        }
    }

    private func mappedState(_ status: SpeechAssetStatus) -> LocalModelState {
        switch status {
        case .unsupported: return .unsupported
        case .supported: return .notInstalled
        case .downloading: return .downloading(progress: 0)
        case .installed: return .installed
        }
    }
}

#if canImport(Speech)
    /// Production inventory over `Speech.AssetInventory` + `SpeechTranscriber` (iOS 26).
    @available(iOS 26.0, macOS 26.0, *)
    public final class SystemSpeechAssetInventory: SpeechAssetInventorying {
        public init() {}

        public func status(for locale: Locale) async -> SpeechAssetStatus {
            guard let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
            else { return .unsupported }
            let transcriber = SpeechTranscriber(locale: resolved, preset: .transcription)
            switch await AssetInventory.status(forModules: [transcriber]) {
            case .unsupported: return .unsupported
            case .supported: return .supported
            case .downloading: return .downloading
            case .installed: return .installed
            @unknown default: return .unsupported
            }
        }

        public func installationRequest(
            for locale: Locale
        ) async throws -> (any SpeechAssetInstalling)? {
            guard let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
            else { return nil }
            // Reserve the locale so the system keeps its assets for this app.
            _ = try await AssetInventory.reserve(locale: resolved)
            let transcriber = SpeechTranscriber(locale: resolved, preset: .transcription)
            guard
                let request = try await AssetInventory.assetInstallationRequest(
                    supporting: [transcriber]
                )
            else { return nil }
            return SystemAssetInstall(request: request)
        }

        public func release(locale: Locale) async {
            let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale) ?? locale
            _ = await AssetInventory.release(reservedLocale: resolved)
        }
    }

    /// Bridges `AssetInstallationRequest` (`downloadAndInstall()` + a Foundation `Progress`)
    /// into the deterministic progress-stream seam.
    @available(iOS 26.0, macOS 26.0, *)
    final class SystemAssetInstall: SpeechAssetInstalling {
        private let request: AssetInstallationRequest

        init(request: AssetInstallationRequest) {
            self.request = request
        }

        func install() -> AsyncThrowingStream<Double, Error> {
            let request = self.request
            return AsyncThrowingStream { continuation in
                let progressTask = Task {
                    let progress = request.progress
                    while !Task.isCancelled {
                        continuation.yield(progress.fractionCompleted)
                        if progress.isFinished { break }
                        try? await Task.sleep(nanoseconds: 200_000_000)
                    }
                }
                let installTask = Task {
                    do {
                        try await request.downloadAndInstall()
                        progressTask.cancel()
                        continuation.yield(1)
                        continuation.finish()
                    } catch {
                        progressTask.cancel()
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in
                    progressTask.cancel()
                    installTask.cancel()
                }
            }
        }
    }
#endif
