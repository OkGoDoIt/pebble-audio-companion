import Foundation
import MuseLink
import Receiver

/// Serializes token rotation, including durable storage. Cancelling a question must not cancel a
/// refresh after the server may have consumed its old token. Forget/re-pair invalidate late results.
public actor MuseCredentialStore: MuseCredentialProvider {
    public enum Failure: Error, Equatable, Sendable {
        case notPaired
        case pairingRejected
        case couldNotSave
    }

    public nonisolated let pairedName: StateSubject<String?>
    public nonisolated let reconnectRequired = StateSubject(false)
    private let secrets: any MuseSecrets
    private let api: MuseDeviceAPI
    private let log: @Sendable (String) -> Void
    private var generation = 0
    private var refreshing: (id: UUID, task: Task<MuseGadgetCredentials, Error>)?
    /// Keep a successful rotation if Keychain temporarily refuses the write. Never consume the
    /// previous refresh token again; retry this write before opening another session.
    private var unsaved: MuseGadgetCredentials?

    public init(secrets: any MuseSecrets, api: MuseDeviceAPI, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.secrets = secrets
        self.api = api
        self.log = log
        pairedName = StateSubject(secrets.credentials()?.identity.bleName)
    }

    public func current() async throws -> MuseGadgetCredentials {
        guard !reconnectRequired.value else { throw Failure.pairingRejected }
        let credentials = try savedCredentials()
        guard credentials.isRefreshDue() else { return credentials }
        return try await rotate(credentials)
    }

    public func refresh(rejected: MuseGadgetCredentials) async throws -> MuseGadgetCredentials {
        guard !reconnectRequired.value else { throw Failure.pairingRejected }
        let current = try savedCredentials()
        guard current == rejected else { return current }
        return try await rotate(current)
    }

    public func rejected(_ credentials: MuseGadgetCredentials) {
        guard (unsaved ?? secrets.credentials()) == credentials else { return }
        reconnectRequired.value = true
        pairedName.value = nil
        log("Muse auth: saved pairing rejected; reconnect required")
    }

    public func replace(with credentials: MuseGadgetCredentials) -> Bool {
        guard secrets.save(credentials: credentials) else { return false }
        generation += 1
        refreshing = nil
        unsaved = nil
        reconnectRequired.value = false
        pairedName.value = credentials.identity.bleName
        return true
    }

    public func forget() -> Bool {
        guard secrets.removeCredentials() else { return false }
        generation += 1
        refreshing = nil
        unsaved = nil
        reconnectRequired.value = false
        pairedName.value = nil
        return true
    }

    private func savedCredentials() throws -> MuseGadgetCredentials {
        if let unsaved {
            guard secrets.save(credentials: unsaved) else { throw Failure.couldNotSave }
            self.unsaved = nil
            log("Muse auth: rotated credentials saved after retry")
        }
        guard let credentials = secrets.credentials() else { throw Failure.notPaired }
        return credentials
    }

    private func rotate(_ credentials: MuseGadgetCredentials) async throws -> MuseGadgetCredentials {
        if let refreshing { return try await refreshing.task.value }
        let id = UUID()
        let generation = self.generation
        let api = self.api
        let sdkToken = secrets.sdkToken()
        let ageMinutes = Int(max(0, Date().timeIntervalSince(credentials.accessTokenSavedAt)) / 60)
        log("Muse auth: refreshing credentials age=\(ageMinutes)m sdkToken=\(sdkToken != nil)")
        // An unstructured task deliberately survives cancellation of an individual connection.
        let task = Task {
            do {
                let tokens = try await api.refreshDeviceToken(
                    refreshToken: credentials.refreshToken, nodeID: credentials.identity.nodeID,
                    sdkToken: sdkToken, apiRoot: credentials.apiRoot)
                return try self.commit(credentials.rotated(to: tokens), generation: generation)
            } catch {
                guard self.generation == generation else { throw CancellationError() }
                if let failure = error as? MuseDeviceAPI.Failure, case .http(401) = failure {
                    self.rejected(credentials)
                }
                self.log("Muse auth: refresh failed: \(error)")
                throw error
            }
        }
        refreshing = (id, task)
        defer { if refreshing?.id == id { refreshing = nil } }
        return try await task.value
    }

    private func commit(_ credentials: MuseGadgetCredentials, generation: Int) throws -> MuseGadgetCredentials {
        guard self.generation == generation else { throw CancellationError() }
        guard secrets.save(credentials: credentials) else {
            unsaved = credentials
            log("Muse auth: rotated credentials could not be saved; retaining them for a write retry")
            throw Failure.couldNotSave
        }
        log("Muse auth: refreshed credentials saved")
        return credentials
    }
}
