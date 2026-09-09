import Foundation

/// Where a `.pbz` went when it left this app.
public enum FirmwareHandoffDestination: String, Codable, Sendable, Equatable {
    /// An app was chosen from the Open In menu. `FirmwareHandoff.openedIn` names it —
    /// `UIDocumentInteractionControllerDelegate`'s `willBeginSendingToApplication` reports the
    /// chosen bundle id, so for once iOS does tell us where a file went.
    case openedInApp
    /// Saved to Files, to be opened from there. The route that survives every share-sheet
    /// change Apple has made since iOS 16.
    case savedToFiles
}

/// One firmware this app handed over.
///
/// A record of a hand-off, **not** of an install. iOS reports which app the person chose, and
/// nothing after that: not whether the Pebble app accepted the board, not whether the watch was
/// in range, not whether the transfer finished. So this is the weakest claim that is still
/// useful — "this build was sent to this app on this date" — and every surface that shows it
/// says exactly that.
public struct FirmwareHandoff: Codable, Sendable, Equatable {
    public let releaseId: String
    public let version: String
    public let board: String
    public let handedOffAt: Date
    public let destination: FirmwareHandoffDestination
    /// Bundle id of the app the person picked, when there was one.
    public let openedIn: String?

    public init(
        releaseId: String,
        version: String,
        board: String,
        handedOffAt: Date,
        destination: FirmwareHandoffDestination = .openedInApp,
        openedIn: String? = nil
    ) {
        self.releaseId = releaseId
        self.version = version
        self.board = board
        self.handedOffAt = handedOffAt
        self.destination = destination
        self.openedIn = openedIn
    }

    public init(
        release: FirmwareRelease,
        at date: Date = Date(),
        destination: FirmwareHandoffDestination = .openedInApp,
        openedIn: String? = nil
    ) {
        self.init(
            releaseId: release.id,
            version: release.version.raw,
            board: release.board.id,
            handedOffAt: date,
            destination: destination,
            openedIn: openedIn
        )
    }

    // Older records predate `destination`/`openedIn`; they decode as an app hand-off with an
    // unknown app, which is what they meant.
    private enum CodingKeys: String, CodingKey {
        case releaseId, version, board, handedOffAt, destination, openedIn
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        releaseId = try c.decode(String.self, forKey: .releaseId)
        version = try c.decode(String.self, forKey: .version)
        board = try c.decode(String.self, forKey: .board)
        handedOffAt = try c.decode(Date.self, forKey: .handedOffAt)
        destination = try c.decodeIfPresent(FirmwareHandoffDestination.self, forKey: .destination)
            ?? .openedInApp
        openedIn = try c.decodeIfPresent(String.self, forKey: .openedIn)
    }

    /// The hand-off as a belief about what is installed, tagged with where the belief came from
    /// so nothing downstream can mistake it for the watch's own word.
    ///
    /// Only an app hand-off forms a belief. Saving a `.pbz` to Files says nothing whatsoever
    /// about the watch — the person may never open it — and treating it as an install would
    /// make the screen stop offering the very update they were part-way through getting.
    public var known: KnownFirmware? {
        guard destination == .openedInApp else { return nil }
        return FirmwareVersion(version).map {
            KnownFirmware(version: $0, source: .handedOff(handedOffAt))
        }
    }
}

public protocol FirmwareHandoffLogging: Sendable {
    var last: FirmwareHandoff? { get }
    func record(_ handoff: FirmwareHandoff)
    func forget()
}

/// `UserDefaults`, because this is a single small fact that has to survive a relaunch and is
/// worthless if it survives an app reinstall.
///
/// `@unchecked Sendable` because `UserDefaults` is documented as thread-safe but is not marked
/// `Sendable`; nothing else is stored here.
public final class UserDefaultsFirmwareHandoffLog: FirmwareHandoffLogging, @unchecked Sendable {
    public static let defaultsKey = "firmwareLastHandoff"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var last: FirmwareHandoff? {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return nil }
        return try? JSONDecoder().decode(FirmwareHandoff.self, from: data)
    }

    public func record(_ handoff: FirmwareHandoff) {
        guard let data = try? JSONEncoder().encode(handoff) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    public func forget() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }
}

/// Tests and previews.
public final class InMemoryFirmwareHandoffLog: FirmwareHandoffLogging, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: FirmwareHandoff?

    public init(_ initial: FirmwareHandoff? = nil) { stored = initial }

    public var last: FirmwareHandoff? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    public func record(_ handoff: FirmwareHandoff) {
        lock.lock(); stored = handoff; lock.unlock()
    }

    public func forget() {
        lock.lock(); stored = nil; lock.unlock()
    }
}
