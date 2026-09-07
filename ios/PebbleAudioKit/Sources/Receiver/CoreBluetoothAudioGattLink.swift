#if canImport(CoreBluetooth)
import CoreBluetooth
import Foundation
import WireProtocol

// Port of `adapter/ble-ios/.../IosAudioGattLink.kt` (plan 6.4) onto CoreBluetooth directly.
//
// The app creates this at launch so Core Bluetooth can restore the central. It prefers joining
// an existing system connection over scanning and keeps notification handling append-and-return
// fast: no decode, no transcription, just forwarding whole protocol messages into streams.
// Failure classification uses CBError/CBATTError DOMAINS/CODES, never localized strings.

public enum AudioCompanionGattIds {
    public static let restoreIdentifier = "audio-companion-central"

    public static let pebblePairingServiceUUID = CBUUID(string: "FED9")
    public static let deviceInformationServiceUUID = CBUUID(string: "180A")
    public static let batteryServiceUUID = CBUUID(string: "180F")
    public static let serviceUUID = CBUUID(string: ProtocolConstants.serviceUUID)
    public static let infoCharacteristicUUID = CBUUID(string: ProtocolConstants.infoCharacteristicUUID)
    public static let controlCharacteristicUUID = CBUUID(string: ProtocolConstants.controlCharacteristicUUID)
    public static let dataCharacteristicUUID = CBUUID(string: ProtocolConstants.dataCharacteristicUUID)
}

public final class CoreBluetoothAudioGattLink: NSObject, AudioGattLink, @unchecked Sendable {
    public let connectionState = StateSubject<LinkState>(.disconnected)
    public let lastFailure = StateSubject<ConnectFailure?>(nil)
    public let deviceName = StateSubject<String?>(nil)

    // Bounded so an unconsumed link (receiver stopped, link still subscribed) cannot grow
    // memory without limit; at ~7 data notifications/s the data bound is ~10 minutes.
    private let controlChannel = ByteChannel(capacity: 256)
    private let dataChannel = ByteChannel(capacity: 4096)

    public var controlNotifications: AsyncStream<[UInt8]> { controlChannel.stream() }
    public var dataNotifications: AsyncStream<[UInt8]> { dataChannel.stream() }

    private let defaults: UserDefaults
    private let restoreIdentifier: String?

    private var centralManager: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var infoCharacteristic: CBCharacteristic?
    private var controlCharacteristic: CBCharacteristic?
    private var dataCharacteristic: CBCharacteristic?
    private var pendingInfoRead: PendingOperation<[UInt8]>?
    private var pendingControlWrite: PendingOperation<Void>?
    private var pendingNotifyCharacteristics: [CBCharacteristic] = []

    /// One in-flight GATT operation, and the bookkeeping that makes it ALWAYS terminate.
    ///
    /// LOAD-BEARING, and the second permanent wedge in this file. `readInfo`/`writeControl` park a
    /// `CheckedContinuation` and hand the work to Core Bluetooth, which answers on a delegate
    /// callback — and on an unexpected disconnect that callback simply never comes. Nothing
    /// resumed the continuation (`resetCharacteristics()` cleared the characteristics and left the
    /// waiter parked), and `withCheckedThrowingContinuation` is not cancellation-aware, so
    /// cancelling the session could not free it either.
    ///
    /// The consequences were not "one operation fails". `connectionHandshake` awaits `readInfo`,
    /// so `runConnection` never returned; `run()` then blocked forever on `await handler?.value`
    /// and the whole session loop stopped observing the link. `withReceiverTimeout` could not save
    /// `verifyWatchState` either — a task group awaits its children before returning, and the
    /// child ignoring cancellation meant the group never returned. And every later call hit the
    /// `pendingInfoRead == nil` guard and threw `operationInFlight` for the life of the process.
    /// That is the failure the user has to kill the app to escape.
    ///
    /// The ticket is read and written only on the delegate queue, so the operation body, the
    /// cancellation handler, the delegate callback and the timeout can arrive in any order without
    /// resuming the same continuation twice or losing a cancel that arrived first.
    private final class OperationTicket: @unchecked Sendable {
        var cancelled = false
        var settled = false
    }

    private struct PendingOperation<Value> {
        let ticket: OperationTicket
        let continuation: CheckedContinuation<Value, Error>
    }

    /// Monotonic id for the in-flight connect/handshake attempt. Every transition into
    /// `.connecting` bumps it; a scheduled watchdog only fires if it is still the current
    /// attempt when it wakes, which is how an `asyncAfter` timer is "cancelled" without holding
    /// a timer handle. Reaching `.ready` or `.disconnected` also bumps it so any outstanding
    /// timer becomes a no-op.
    private var connectGeneration = 0

    /// Consecutive watchdog timeouts for the current connect sequence; reset once Ready.
    private var connectAttempts = 0

    /// True while a user-initiated disconnect is in flight, so it is not reported as an error.
    private var intentionalDisconnect = false

    /// True between `connect()` and `disconnect()`: we should (re)establish the link whenever
    /// possible. Lets an unexpected drop or a Bluetooth-off -> on transition reconnect
    /// automatically instead of stranding the link Disconnected.
    private var wantConnected = false

    /// Set after a `.linkRejected` failure (stale GATT cache / needs re-pair). Retrying the same
    /// cached handles can only re-fail, so we stop re-driving connects until a real recovery
    /// signal arrives: a Bluetooth power-cycle (CoreBluetooth re-discovers) or an explicit user
    /// Reconnect. Without this the link re-fails the identical handshake on every app foreground.
    private var awaitingUserRecovery = false

    /// True while the in-flight attempt is an AUTOMATIC recovery (an unexpected drop or a
    /// scheduled retry) rather than one a user is watching. See `enterConnecting`.
    private var automaticConnect = false

    /// Monotonic id for the scheduled-retry timer, cancelled the same way the watchdog is.
    private var retryGeneration = 0

    /// See `setForeground`. Defaults to false: a link built during launch has nobody watching it
    /// yet, and the safe default is the one that never tears down a pending connect.
    private var isForeground = false

    /// True between issuing a `connect()`/scan and Core Bluetooth answering it.
    ///
    /// The guard that keeps `centralManagerDidUpdateState` from stepping on state restoration.
    /// `willRestoreState` runs first on a relaunch and issues the restored connect; `.poweredOn`
    /// then arrived and re-entered `.connecting` for a SECOND attempt — re-arming the give-up
    /// watchdog and potentially dialling a different peripheral, discarding the restored one. The
    /// state alone could not tell the two cases apart, because a launch-time `connect()` before
    /// the radio is up also sits at `.connecting` with nothing outstanding, and that one really
    /// does need `.poweredOn` to drive it.
    private var hasPendingConnect = false

    /// Current backoff delay; doubles per failure, reset on Ready and on any explicit user action.
    private var retryDelayMs: Int64 = CoreBluetoothAudioGattLink.retryBaseDelayMs

    /// State restoration is opt-in via `restoreIdentifier` (pass nil to disable, e.g. for tools).
    public init(
        restoreIdentifier: String? = AudioCompanionGattIds.restoreIdentifier,
        defaults: UserDefaults = .standard
    ) {
        self.restoreIdentifier = restoreIdentifier
        self.defaults = defaults
        super.init()
        deviceName.value = defaults.string(forKey: Self.keyPeripheralName)
    }

    /// Creates the central manager without dialling anything.
    ///
    /// LOAD-BEARING for state restoration. iOS delivers `willRestoreState` only to a
    /// `CBCentralManager` created with the matching restore identifier **during the launch
    /// cycle**. This link built its manager lazily inside `connect()`, and `connect()` is reached
    /// only from an explicit user gesture — so on a relaunch no manager existed when iOS wanted to
    /// hand back its state, `willRestoreState` was never called, and the restoration path was dead
    /// code. Call this from the composition root, synchronously, at launch.
    ///
    /// `wantConnected` stays false, so this cannot start dialling on its own and cannot prompt the
    /// watch (plan 4.2): only `connect()`/`resync()` express intent.
    ///
    /// Synchronous, as belt-and-braces rather than as a bug fix. The `async` this replaces was
    /// almost certainly fine — `delegateQueue` is a private serial queue with nothing else on it
    /// at launch, so the block ran microseconds later, and Core Bluetooth does not push
    /// `willRestoreState` at a single missable instant: it delivers it as the first delegate
    /// callback to whichever manager is instantiated with the matching restore identifier, with no
    /// documented deadline tied to `didFinishLaunchingWithOptions` returning. But this method's
    /// whole reason to exist is an ordering guarantee, and `sync` is the version that states the
    /// guarantee instead of relying on a queue happening to be idle. Safe here because it is
    /// called once, from the composition root, before any delegate callback can exist.
    public func prepareForRestoration() {
        delegateQueue.sync { [self] in
            guard centralManager == nil else { return }
            _ = makeCentralManager()
            log("prepared central for state restoration")
        }
    }

    /// Whether a person is currently looking at the app.
    ///
    /// Drives ONE decision: whether a connect attempt gets the give-up watchdog. That watchdog
    /// exists so a user staring at a spinner is not left there forever — it tears a stalled
    /// attempt down and, after three, surfaces a failure. In the background it is actively
    /// harmful: the thing it tears down is the outstanding pending connect, which is the ONLY
    /// recovery mechanism that survives suspension (Core Bluetooth resolves it whenever the watch
    /// returns, waking us through `bluetooth-central`). A relaunched-in-background app that armed
    /// it therefore gave up on the one thing that was going to work, three stalls later, with
    /// nobody there to see the failure it surfaced.
    public func setForeground(_ value: Bool) {
        onDelegateQueue { [self] in
            guard isForeground != value else { return }
            isForeground = value
            log("foreground=\(value)")
        }
    }

    /// Where the adapter narrates itself, in addition to NSLog.
    ///
    /// NSLog alone needs a cable and Xcode, which is no use to the person actually holding the
    /// phone in the failure. Set this from the composition root so the same transitions land in
    /// Settings > Diagnostics > Detailed Logs, where they can be read and shared from the device.
    public var logSink: ReceiverLog = .silent

    /// Called on the delegate queue for every inbound notification, before it is handed on.
    ///
    /// The seam for the background-activity assertion, which lives above this module. It has to be
    /// taken HERE, synchronously inside the Core Bluetooth callback: everything downstream is
    /// asynchronous, and the whole risk is being suspended in the gap between this delegate
    /// returning and the cooperative pool getting round to persisting the frame.
    public var onInboundNotification: @Sendable () -> Void = {}

    /// Every Core Bluetooth transition, with a stable, greppable tag. This is the only place the
    /// adapter logs; it stays out of the data hot path (notifications are not logged per-frame).
    private func log(_ message: String) {
        NSLog(
            "%@ state=%@ gen=%d attempt=%d %@",
            Self.logTag, String(describing: connectionState.value), connectGeneration,
            connectAttempts, message
        )
        logSink("link \(describe(connectionState.value)): \(message)")
    }

    /// The adapter's own serial queue: Core Bluetooth delivers every delegate callback here, and
    /// all link state mutation funnels through it. It used to be `DispatchQueue.main`, which put
    /// every notification, connect dance and watchdog on the UI thread — free serialization, paid
    /// for in scroll hitches whenever the watch was streaming.
    private let delegateQueue = DispatchQueue(label: "audio-companion.gatt-link")

    /// Runs `block` on the delegate serial queue, serializing lifecycle calls from arbitrary
    /// threads with the manager's delegate callbacks (delivered on this queue).
    private func onDelegateQueue(_ block: @escaping @Sendable () -> Void) {
        delegateQueue.async(execute: block)
    }

    /// Joins the existing system link when possible:
    /// retrieveConnectedPeripherals(withServices:) -> connect(); otherwise a pending connect()
    /// on the stored peripheral identifier. Scanning is a foreground-only onboarding fallback.
    public func connect() {
        onDelegateQueue { [self] in
            // Single CBCentralManager for the process; creating it here on the delegate queue
            // guarantees exactly one even when connect() races in from several places at launch.
            let manager = centralManager ?? makeCentralManager()
            wantConnected = true
            log("connect() requested, manager.state=\(manager.state.rawValue)")
            // Idempotent: a live or in-progress link must not be bounced. connect() is called on
            // every app foreground/launch, so restarting it here would drop a working connection
            // (and lose audio) each time the app comes to the foreground.
            if connectionState.value != .disconnected {
                log("connect() ignored; already \(connectionState.value)")
                return
            }
            // A LinkRejected failure won't clear by re-running the identical (stale-cache)
            // handshake, so stay put until a Bluetooth power-cycle or explicit user Reconnect
            // clears the latch. This is what stops the app re-failing on every foreground.
            if awaitingUserRecovery {
                log("connect() suppressed; awaiting user recovery (Bluetooth off/on or re-pair)")
                return
            }
            connectAttempts = 0
            cancelScheduledRetry()
            // Read the radio as a LEVEL, not only as an edge.
            //
            // The whole CBManagerState machine hangs off `centralManagerDidUpdateState`, and every
            // branch of it is gated on `wantConnected`. But the manager is created by
            // `prepareForRestoration()` with `wantConnected == false`, and Core Bluetooth delivers
            // its one initial state within milliseconds of that — long before anything calls
            // `connect()`. So if Bluetooth was off, or permission had been revoked, that single
            // report was discarded, and the state is never re-delivered for an unchanged value.
            // `connect()` then entered `.connecting`, cleared `lastFailure`, and dialled nothing,
            // because the radio was not powered on. The user got a silent, permanent
            // "Connecting…" with the actual, actionable reason thrown away — and it is the one
            // case where the app has something genuinely useful to say.
            guard manager.state == .poweredOn else {
                applyPowerState(manager.state)
                return
            }
            enterConnecting("connect()")
            connectWhenPoweredOn(manager)
        }
    }

    /// Maps a non-`poweredOn` radio state onto an honest failure. Shared by the delegate callback
    /// and by `connect()`, so a fault reported before we were listening reads the same as one
    /// reported after.
    private func applyPowerState(_ state: CBManagerState) {
        switch state {
        case .poweredOff:
            failAndReset(.bluetoothOff, "Bluetooth is turned off")
        case .unauthorized:
            failAndReset(
                .bluetoothUnauthorized,
                "Bluetooth access is off for this app. Turn it on in Settings."
            )
        case .unsupported:
            failAndReset(.bluetoothUnavailable, "Bluetooth is unavailable to this app right now.")
        case .unknown, .resetting:
            // Genuinely transient: Core Bluetooth is still starting, or briefly restarted its
            // system service. `didUpdateState` owns the recovery, and the connecting floor keeps
            // this from being a place to sit forever.
            awaitingUserRecovery = false
            enterConnecting("Bluetooth \(state == .resetting ? "resetting" : "starting up")")
        case .poweredOn:
            break
        @unknown default:
            break
        }
    }

    private func makeCentralManager() -> CBCentralManager {
        var options: [String: Any] = [:]
        #if os(iOS)
        if let restoreIdentifier {
            options[CBCentralManagerOptionRestoreIdentifierKey] = restoreIdentifier
        }
        #endif
        let manager = CBCentralManager(delegate: self, queue: delegateQueue, options: options)
        centralManager = manager
        return manager
    }

    public func disconnect() {
        onDelegateQueue { [self] in
            log("disconnect() requested")
            wantConnected = false
            awaitingUserRecovery = false
            hasPendingConnect = false
            connectGeneration += 1 // invalidate any pending watchdog
            cancelScheduledRetry()
            guard let manager = centralManager else { return }
            manager.stopScan()
            if let current = peripheral {
                intentionalDisconnect = true
                manager.cancelPeripheralConnection(current)
            } else {
                resetCharacteristics()
                connectionState.value = .disconnected
            }
        }
    }

    /// Forces a fresh GATT session without giving up the link: cancel this app's connection to
    /// the peripheral and reconnect. On a shared ACL link (the official app is also connected)
    /// this re-runs service discovery, CCCD subscription and AUTH without disturbing the other
    /// app — the recovery for a half-dead connection CoreBluetooth still reports as connected.
    public func resync() {
        resync(clearingUserRecoveryLatch: true, "resync()")
    }

    /// The session's own escalations land here. Everything about the rebuild is the same; the one
    /// difference is that a `.linkRejected` latch survives it, because retrying the identical
    /// cached handles can only re-fail and would spin the radio indefinitely.
    public func resyncAutomatically() {
        resync(clearingUserRecoveryLatch: false, "automatic resync")
    }

    private func resync(clearingUserRecoveryLatch: Bool, _ reason: String) {
        onDelegateQueue { [self] in
            log("\(reason) requested")
            if clearingUserRecoveryLatch {
                // Explicit "Reconnect": honor it even if we had latched off automatic retries.
                awaitingUserRecovery = false
            } else if awaitingUserRecovery {
                log("\(reason) suppressed; awaiting user recovery (Bluetooth off/on or re-pair)")
                return
            }
            guard let manager = centralManager else {
                connect()
                return
            }
            wantConnected = true
            connectAttempts = 0
            cancelScheduledRetry()
            manager.stopScan()
            if let current = peripheral {
                // Not an intentional (user) disconnect: didDisconnect re-issues the connect
                // because wantConnected stays true, so the link rebuilds itself.
                intentionalDisconnect = false
                hasPendingConnect = false
                enterConnecting("resync (cancel + reconnect)")
                manager.cancelPeripheralConnection(current)
            } else if manager.state == .poweredOn {
                enterConnecting("resync (fresh)")
                connectWhenPoweredOn(manager)
            }
        }
    }

    public func readInfo() async throws -> [UInt8] {
        let ticket = OperationTicket()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<[UInt8], Error>) in
                self.onDelegateQueue { [self] in
                    if ticket.cancelled {
                        ticket.settled = true
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    guard let localPeripheral = peripheral else {
                        ticket.settled = true
                        continuation.resume(throwing: LinkOperationError.notConnected)
                        return
                    }
                    guard let characteristic = infoCharacteristic else {
                        ticket.settled = true
                        continuation.resume(throwing: LinkOperationError.characteristicNotReady)
                        return
                    }
                    guard pendingInfoRead == nil else {
                        ticket.settled = true
                        continuation.resume(throwing: LinkOperationError.operationInFlight)
                        return
                    }
                    pendingInfoRead = PendingOperation(ticket: ticket, continuation: continuation)
                    armOperationTimeout(ticket)
                    localPeripheral.readValue(for: characteristic)
                }
            }
        } onCancel: {
            self.onDelegateQueue { [self] in
                ticket.cancelled = true
                guard let pending = pendingInfoRead, pending.ticket === ticket else { return }
                pendingInfoRead = nil
                ticket.settled = true
                pending.continuation.resume(throwing: CancellationError())
            }
        }
    }

    public func writeControl(_ message: [UInt8]) async throws {
        let ticket = OperationTicket()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                self.onDelegateQueue { [self] in
                    if ticket.cancelled {
                        ticket.settled = true
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    guard let localPeripheral = peripheral else {
                        ticket.settled = true
                        continuation.resume(throwing: LinkOperationError.notConnected)
                        return
                    }
                    guard let characteristic = controlCharacteristic else {
                        ticket.settled = true
                        continuation.resume(throwing: LinkOperationError.characteristicNotReady)
                        return
                    }
                    guard pendingControlWrite == nil else {
                        ticket.settled = true
                        continuation.resume(throwing: LinkOperationError.operationInFlight)
                        return
                    }
                    pendingControlWrite = PendingOperation(ticket: ticket, continuation: continuation)
                    armOperationTimeout(ticket)
                    localPeripheral.writeValue(
                        Data(message), for: characteristic, type: .withResponse
                    )
                }
            }
        } onCancel: {
            self.onDelegateQueue { [self] in
                ticket.cancelled = true
                guard let pending = pendingControlWrite, pending.ticket === ticket else { return }
                pendingControlWrite = nil
                ticket.settled = true
                pending.continuation.resume(throwing: CancellationError())
            }
        }
    }

    /// A GATT read or write that Core Bluetooth never answers must still end. A half-dead link the
    /// platform still reports as connected produces exactly that — no callback, no disconnect, no
    /// error — and one such operation used to stop the session's keepalive (and with it the only
    /// escalation that would have rebuilt the link) for as long as the app lived.
    private func armOperationTimeout(_ ticket: OperationTicket) {
        delegateQueue.asyncAfter(
            deadline: .now() + .milliseconds(Int(Self.operationTimeoutMs))
        ) { [weak self] in
            guard let self, !ticket.settled else { return }
            self.failPendingOperations(matching: ticket, "the watch did not answer in time")
        }
    }

    /// Frees whichever parked GATT operations `ticket` selects (nil = all of them), resuming their
    /// waiters with an error instead of leaving them parked forever.
    ///
    /// Called from every path that invalidates the connection — an unexpected disconnect, the
    /// connect watchdog, a terminal failure, a user disconnect — so "the link went away" always
    /// reaches the code awaiting on it.
    private func failPendingOperations(
        matching ticket: OperationTicket? = nil,
        _ reason: String
    ) {
        if let pending = pendingInfoRead, ticket == nil || pending.ticket === ticket {
            pendingInfoRead = nil
            pending.ticket.settled = true
            pending.continuation.resume(throwing: LinkOperationError.failed(reason))
        }
        if let pending = pendingControlWrite, ticket == nil || pending.ticket === ticket {
            pendingControlWrite = nil
            pending.ticket.settled = true
            pending.continuation.resume(throwing: LinkOperationError.failed(reason))
        }
    }

    // --- connect path --------------------------------------------------------------------------

    private func connectWhenPoweredOn(_ manager: CBCentralManager) {
        // Prefer a peripheral CoreBluetooth reports as *currently connected* (system already
        // holds the ACL, e.g. the official Pebble app is connected) over a stored identifier. A
        // stored identifier resolves to a CBPeripheral even when the watch is unreachable, and
        // connecting to it pends forever with no error — the most likely cause of a stuck
        // "Connecting".
        let connected = connectedPeripherals(
            manager,
            serviceUUIDs: [
                AudioCompanionGattIds.serviceUUID,
                AudioCompanionGattIds.pebblePairingServiceUUID,
            ]
        )
        if let existing = connected.first(where: { $0.isLikelyPebble }) ?? connected.first {
            log("connectWhenPoweredOn: using currently-connected peripheral \(existing.name ?? existing.identifier.uuidString)")
            connectPeripheral(manager, existing)
            return
        }

        if let stored = restoredPeripheral(manager) {
            log("connectWhenPoweredOn: using stored peripheral \(stored.identifier.uuidString)")
            connectPeripheral(manager, stored)
            return
        }

        // Device Information and Battery are too generic to pick blindly: AirPods, keyboards,
        // and other nearby devices may expose them. Use them only when iOS gives us a
        // Pebble-looking name, otherwise fall back to the explicit foreground scan below.
        let namedPebble = connectedPeripherals(
            manager,
            serviceUUIDs: [
                AudioCompanionGattIds.deviceInformationServiceUUID,
                AudioCompanionGattIds.batteryServiceUUID,
            ]
        ).first { $0.isLikelyPebble }
        if let namedPebble {
            log("connectWhenPoweredOn: using named Pebble \(namedPebble.name ?? "?")")
            connectPeripheral(manager, namedPebble)
        } else {
            log("connectWhenPoweredOn: no known peripheral; scanning")
            hasPendingConnect = true
            manager.scanForPeripherals(
                withServices: [
                    AudioCompanionGattIds.serviceUUID,
                    AudioCompanionGattIds.pebblePairingServiceUUID,
                ],
                options: nil
            )
        }
    }

    private func connectedPeripherals(
        _ manager: CBCentralManager,
        serviceUUIDs: [CBUUID]
    ) -> [CBPeripheral] {
        var seen = Set<UUID>()
        var result: [CBPeripheral] = []
        for serviceUUID in serviceUUIDs {
            for peripheral in manager.retrieveConnectedPeripherals(withServices: [serviceUUID])
            where seen.insert(peripheral.identifier).inserted {
                result.append(peripheral)
            }
        }
        return result
    }

    private func restoredPeripheral(_ manager: CBCentralManager) -> CBPeripheral? {
        guard let uuidString = defaults.string(forKey: Self.keyPeripheralIdentifier),
              let uuid = UUID(uuidString: uuidString)
        else { return nil }
        return manager.retrievePeripherals(withIdentifiers: [uuid]).first
    }

    private func connectPeripheral(_ manager: CBCentralManager, _ target: CBPeripheral) {
        peripheral = target
        target.delegate = self
        rememberPeripheral(target)
        hasPendingConnect = true
        manager.connect(target, options: nil)
    }

    /// Remembers the peer so a later launch can reconnect without scanning — and remembers its
    /// NAME so Settings can say which watch is bound before the radio is up. Core Bluetooth
    /// leaves `name` nil on a peripheral it has only just retrieved by identifier, so the last
    /// name we saw is kept rather than overwritten with nil.
    private func rememberPeripheral(_ target: CBPeripheral) {
        defaults.set(target.identifier.uuidString, forKey: Self.keyPeripheralIdentifier)
        publishName(target.name)
    }

    private func publishName(_ name: String?) {
        guard let name, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        guard name != deviceName.value else { return }
        defaults.set(name, forKey: Self.keyPeripheralName)
        deviceName.value = name
    }

    /// Moves into `.connecting` and (re)arms the handshake watchdog. Every step that keeps us
    /// mid-handshake (issuing a connect, a discovery callback, a CCCD subscription) calls this
    /// so the watchdog window restarts on real progress and only fires when a step truly stalls.
    ///
    /// `automatic` marks an attempt nobody is watching (drop recovery, a scheduled retry). Those
    /// deliberately run WITHOUT the give-up watchdog — see `armWatchdog`.
    private func enterConnecting(_ reason: String, automatic requested: Bool = false) {
        // Backgrounded attempts are ALWAYS automatic, whatever the caller asked for. The give-up
        // watchdog exists to spare a user an endless spinner; with nobody looking there is no
        // spinner, and the only thing it can accomplish is tearing down the pending connect that
        // is the sole recovery surviving suspension. That is how a background relaunch used to
        // give up for good, three stalls after it started, with no one there to see it.
        let automatic = requested || !isForeground
        lastFailure.value = nil
        connectGeneration += 1
        automaticConnect = automatic
        connectionState.value = .connecting
        log("-> Connecting (\(reason))\(automatic ? " [automatic]" : "")")
        if !automatic { armWatchdog(connectGeneration) }
        // ALWAYS, automatic or not. See `armConnectingFloor`.
        armConnectingFloor(connectGeneration)
    }

    /// A floor under `.connecting`, so it can never be a terminal state.
    ///
    /// An automatic attempt deliberately gets no give-up watchdog — tearing down the pending
    /// connect would destroy the only recovery that survives suspension. But "no watchdog" had
    /// become "no timer of any kind", and `.connecting` is reached automatically by three of the
    /// four re-dial paths (an unexpected drop, a scheduled retry, `willRestoreState`). None of
    /// them goes through `failAndReset`, so `scheduleReconnect` never runs; the session treats
    /// `.connecting` by tearing its per-connection children down and waiting; and `connect()`
    /// returns early because the state is not `.disconnected`. The result was a link sitting in
    /// `.connecting` with nothing scheduled anywhere — not even a foreground visit could break it
    /// out — which is the same permanent park this file has already been fixed for twice.
    ///
    /// This is a FLOOR, not a deadline: it never fails the link and never counts an attempt. If
    /// we are still on the same attempt when it fires, it re-issues the connect (Core Bluetooth
    /// coalesces a duplicate `connect` for a peripheral it is already pending on, so this is
    /// cheap) and re-arms. The interval is long enough to be invisible on a healthy connect and
    /// short enough that a wedged one costs minutes, not a day.
    private func armConnectingFloor(_ generation: Int) {
        delegateQueue.asyncAfter(
            deadline: .now() + .milliseconds(Int(Self.connectingFloorMs))
        ) { [weak self] in
            guard let self,
                generation == self.connectGeneration,
                self.connectionState.value == .connecting,
                self.wantConnected,
                let manager = self.centralManager
            else { return }
            guard manager.state == .poweredOn else {
                // Still waiting for the radio; `didUpdateState` owns that transition. Keep the
                // floor alive so we do not leave `.connecting` uncovered.
                self.armConnectingFloor(generation)
                return
            }
            self.log("still connecting after \(Self.connectingFloorMs)ms; re-driving")
            self.hasPendingConnect = false
            self.connectWhenPoweredOn(manager)
            self.armConnectingFloor(generation)
        }
    }

    /// Reached the fully-subscribed, usable link. Cancels the watchdog and resets retry counters.
    private func reachReady() {
        connectGeneration += 1 // invalidate any pending watchdog
        connectAttempts = 0
        awaitingUserRecovery = false
        automaticConnect = false
        cancelScheduledRetry() // also resets the backoff to its base delay
        lastFailure.value = nil
        connectionState.value = .ready
        log("-> Ready")
    }

    // --- automatic reconnection ------------------------------------------------------------------

    private func cancelScheduledRetry() {
        retryGeneration += 1
        retryDelayMs = Self.retryBaseDelayMs
    }

    /// Schedules another connect attempt with exponential backoff.
    ///
    /// LOAD-BEARING. Before this existed, every terminal `failAndReset` left the link
    /// `.disconnected` with `wantConnected == true` and NOTHING that would ever try again — no
    /// timer, no pending connect, no observer. `didFailToConnect`, "companion service not found",
    /// and the watchdog's give-up after three stalls all landed there. The only ways out were a
    /// Bluetooth power-cycle or the user opening the app and tapping Reconnect, which is exactly
    /// the shape of a blackout that ends when the user next picks up the phone.
    ///
    /// Honest about its limit: a `DispatchQueue` timer does not fire while iOS has the process
    /// suspended. This recovers an app that is alive (foreground, or awake on a Bluetooth wake);
    /// the suspension-proof half is the outstanding pending connect in `didDisconnectPeripheral`.
    private func scheduleReconnect(after failure: ConnectFailureKind) {
        guard wantConnected, !awaitingUserRecovery, Self.isRetryable(failure) else { return }
        retryGeneration += 1
        let generation = retryGeneration
        let delay = retryDelayMs
        retryDelayMs = min(retryDelayMs * 2, Self.retryMaxDelayMs)
        log("scheduling automatic reconnect in \(delay)ms")
        delegateQueue.asyncAfter(deadline: .now() + .milliseconds(Int(delay))) { [weak self] in
            guard let self else { return }
            guard generation == self.retryGeneration,
                  self.wantConnected,
                  !self.awaitingUserRecovery,
                  self.connectionState.value == .disconnected,
                  let manager = self.centralManager,
                  manager.state == .poweredOn
            else { return }
            self.connectAttempts = 0
            // Automatic: no give-up watchdog, so a retry that pends is left pending rather than
            // being torn down and counted towards another dead end.
            self.enterConnecting("scheduled reconnect", automatic: true)
            self.connectWhenPoweredOn(manager)
        }
    }

    /// Bluetooth-off/unauthorized/unavailable have their own recovery signal (`didUpdateState`),
    /// and `linkRejected` cannot clear by retrying the same cached handles — retrying either just
    /// burns battery. Everything else is a transient the app should heal from on its own.
    private static func isRetryable(_ kind: ConnectFailureKind) -> Bool {
        switch kind {
        case .watchUnreachable, .unknown:
            return true
        case .bluetoothOff, .bluetoothUnauthorized, .bluetoothUnavailable, .linkRejected:
            return false
        }
    }

    /// Schedules a one-shot timeout for `generation`. The block re-checks that its generation is
    /// still current and we are still Connecting before acting; a completed/superseded attempt
    /// makes it a no-op. Runs on the delegate queue, so it is serialized with every Core
    /// Bluetooth callback.
    private func armWatchdog(_ generation: Int) {
        delegateQueue.asyncAfter(
            deadline: .now() + .milliseconds(Int(Self.connectWatchdogMs))
        ) { [weak self] in
            guard let self else { return }
            if generation == self.connectGeneration && self.connectionState.value == .connecting {
                self.onConnectTimeout()
            }
        }
    }

    /// The connect/handshake stalled (classic Core Bluetooth trap: `connect()` has no timeout
    /// and a stale or unreachable peripheral handle pends forever with no error). Tear the
    /// stalled attempt down and re-evaluate the connect path from scratch; after
    /// `connectMaxAttempts` surface an actionable failure so the UI leaves "Connecting" and the
    /// user gets a retry affordance instead of an indefinite spinner.
    private func onConnectTimeout() {
        guard let manager = centralManager else { return }
        // Belt and braces: an automatic attempt never arms this watchdog, and must never be torn
        // down by one — its outstanding pending connect is the only recovery a suspended app has.
        if automaticConnect {
            log("watchdog ignored for an automatic connect; leaving it pending")
            return
        }
        // Bluetooth not ready yet (still powering on / resetting): this isn't a stalled connect,
        // so don't burn a retry. didUpdateState drives the real attempt once it powers on; just
        // re-arm so we keep watching.
        if manager.state != .poweredOn {
            log("watchdog: Bluetooth not powered on (state=\(manager.state.rawValue)); re-arming")
            armWatchdog(connectGeneration)
            return
        }
        connectAttempts += 1
        log("watchdog timeout after \(Self.connectWatchdogMs)ms")
        manager.stopScan()
        // Cancel the stalled attempt. For a pending (never-connected) connect this fires no
        // delegate callback; for a connected-but-stuck-in-discovery peripheral it triggers a
        // disconnect we intentionally swallow here, since we re-drive the connect ourselves.
        if let current = peripheral {
            intentionalDisconnect = true
            manager.cancelPeripheralConnection(current)
        }
        peripheral = nil
        hasPendingConnect = false
        resetCharacteristics()
        if connectAttempts >= Self.connectMaxAttempts {
            log("giving up after \(connectAttempts) attempts")
            failAndReset(
                .watchUnreachable,
                "Couldn't reach your Pebble. Make sure it's nearby, then try again."
            )
            return
        }
        if manager.state == .poweredOn {
            enterConnecting("watchdog retry \(connectAttempts)")
            connectWhenPoweredOn(manager)
        }
    }

    private func failAndReset(_ kind: ConnectFailureKind, _ detail: String?) {
        failAndReset(ConnectFailure(kind: kind, detail: detail))
    }

    private func failAndReset(_ failure: ConnectFailure) {
        connectGeneration += 1 // invalidate any pending watchdog
        hasPendingConnect = false
        let message = failure.detail ?? "connection failed"
        failPendingOperations(message)
        centralManager?.stopScan()
        resetCharacteristics()
        // A stale-cache / re-pair failure won't clear by retrying the same handles, so latch off
        // the automatic reconnects (connect() on foreground, unexpected-drop reconnect) until
        // Bluetooth is power-cycled or the user taps Reconnect. Any other failure keeps the
        // normal auto-retry.
        awaitingUserRecovery = failure.kind == .linkRejected
        automaticConnect = false
        lastFailure.value = failure
        connectionState.value = .disconnected
        log("-> Disconnected (\(failure.kind): \(message))")
        // The UI still gets its honest, actionable failure — and the app quietly keeps trying
        // instead of waiting for the user to notice hours later.
        if awaitingUserRecovery {
            scheduleStaleCacheRetry()
        } else {
            scheduleReconnect(after: failure.kind)
        }
    }

    /// The slow way out of a `.linkRejected` latch, for the case nobody is there to tap Reconnect.
    ///
    /// The latch is right about the short term: re-running the identical handshake against the
    /// same stale handles can only re-fail, and doing it on every foreground burns the radio. It
    /// was wrong about the long term. "Wait for a Bluetooth power-cycle or an explicit user
    /// Reconnect" assumes a user who is looking at the app, and this app spends nearly all its
    /// life in the background — so a firmware flash at breakfast meant no audio until the user
    /// happened to open Settings and tap a button, with the status card the only clue.
    ///
    /// The cache does clear on its own: bluetoothd re-reads the database on a fresh ACL
    /// connection, on a Service Changed indication, and whenever it restarts. So retry on a slow
    /// cadence rather than never. Five minutes is far too long to be a hot loop and far shorter
    /// than "until someone notices".
    private func scheduleStaleCacheRetry() {
        guard wantConnected else { return }
        retryGeneration += 1
        let generation = retryGeneration
        log("scheduling a stale-cache retry in \(Self.staleCacheRetryDelayMs)ms")
        delegateQueue.asyncAfter(
            deadline: .now() + .milliseconds(Int(Self.staleCacheRetryDelayMs))
        ) { [weak self] in
            guard let self,
                generation == self.retryGeneration,
                self.wantConnected,
                self.connectionState.value == .disconnected,
                let manager = self.centralManager,
                manager.state == .poweredOn
            else { return }
            // Drop the latch for this one attempt. If the handles are still stale the handshake
            // fails again, re-latches, and schedules the next one — a bounded, quiet retry rather
            // than a dead end.
            self.awaitingUserRecovery = false
            self.connectAttempts = 0
            self.enterConnecting("stale-cache retry", automatic: true)
            self.connectWhenPoweredOn(manager)
        }
    }

    /// Classifies a Core Bluetooth error by its error DOMAIN and CODE — never its localized
    /// message. `CBErrorDomain` covers link-level trouble; `CBATTErrorDomain` means the watch's
    /// ATT server refused the operation, and there the CODE matters.
    ///
    /// The domain alone is too blunt. `.linkRejected` latches off the fast automatic retries, so
    /// treating every ATT error as one meant a single `.unlikelyError` or `.insufficientResources`
    /// — both ordinary transients from a busy watch — stopped the app reconnecting until a human
    /// power-cycled Bluetooth. Only the codes below actually describe a link whose cached handles
    /// are wrong or whose security state will not permit us: retrying THOSE against the same cache
    /// really can only re-fail. Everything else in the domain is a transient and gets the normal
    /// backoff.
    private func classifyFailure(_ error: Error?, fallback: ConnectFailureKind) -> ConnectFailure {
        let nsError = error as NSError?
        let kind: ConnectFailureKind
        switch nsError?.domain {
        case CBATTErrorDomain:
            kind = Self.isStaleCacheOrSecurity(CBATTError.Code(rawValue: nsError?.code ?? -1))
                ? .linkRejected : .watchUnreachable
        case CBErrorDomain:
            kind = .watchUnreachable
        default:
            kind = fallback
        }
        return ConnectFailure(kind: kind, detail: nsError?.localizedDescription)
    }

    /// The ATT codes that mean "these handles are stale, or this link's security will not do",
    /// i.e. the ones a plain retry cannot fix. The signature of a stale iOS GATT cache after a
    /// firmware flash is `.writeNotPermitted` on the CCCD ("Writing is not permitted."), with
    /// `.invalidHandle` / `.attributeNotFound` when the handle moved outright.
    private static func isStaleCacheOrSecurity(_ code: CBATTError.Code?) -> Bool {
        switch code {
        case .invalidHandle, .readNotPermitted, .writeNotPermitted, .insufficientAuthentication,
            .insufficientAuthorization, .insufficientEncryption, .insufficientEncryptionKeySize,
            .attributeNotFound:
            return true
        default:
            return false
        }
    }

    /// Invalidates everything bound to the current GATT session.
    ///
    /// Freeing the parked operations belongs HERE, not only in `failAndReset`: the unexpected-drop
    /// path in `didDisconnectPeripheral` reconnects without ever going through `failAndReset`, and
    /// it was leaving `readInfo`/`writeControl` waiters parked on a connection that no longer
    /// exists. Every caller of this function has, by definition, just made those operations
    /// unanswerable.
    private func resetCharacteristics(
        reason: String = "the connection to the watch went away"
    ) {
        infoCharacteristic = nil
        controlCharacteristic = nil
        dataCharacteristic = nil
        pendingNotifyCharacteristics.removeAll()
        failPendingOperations(reason)
    }

    /// Domain and CODE, then the localized string.
    ///
    /// The code is the part that identifies the fault. `localizedDescription` alone gave us
    /// "The connection has timed out unexpectedly." for `CBError.connectionTimeout`,
    /// `.peripheralDisconnected` and `.connectionFailed` alike, and it is translated — so a log
    /// from a non-English phone was unmatchable against anything. Every classification decision in
    /// this file is already made on domain+code; the log should say the same thing.
    private func describeError(_ error: Error?) -> String {
        guard let error = error as NSError? else { return "none" }
        return "\(error.domain)#\(error.code) (\(error.localizedDescription))"
    }

    private enum LinkOperationError: Error {
        case notConnected
        case characteristicNotReady
        case operationInFlight
        case failed(String)
    }

    private static let keyPeripheralIdentifier = "ios_audio_companion_peripheral_identifier"
    private static let keyPeripheralName = "ios_audio_companion_peripheral_name"

    /// Stable, greppable prefix for the live device log.
    private static let logTag = "[AudioGattLink]"

    /// How long a single connect/handshake step may stall before the watchdog re-drives it.
    /// CoreBluetooth `connect()` itself never times out, so this is the only bound on a pended
    /// connection. Sized to comfortably cover a healthy connect + discovery + CCCD round trip
    /// to a Pebble (a few seconds) without making a genuine stall feel indefinite.
    private static let connectWatchdogMs: Int64 = 10_000

    /// Consecutive stalls before we stop retrying and surface an actionable error.
    private static let connectMaxAttempts = 3

    /// Hard bound on a single GATT read or write. Core Bluetooth gives none: a half-dead link it
    /// still calls connected can leave an operation outstanding for the life of the process.
    private static let operationTimeoutMs: Int64 = 10_000

    /// First automatic-retry delay after a recoverable failure; doubles up to `retryMaxDelayMs`.
    private static let retryBaseDelayMs: Int64 = 2_000

    /// Backoff ceiling. Two minutes keeps a watch that comes back into range while the app is
    /// awake picked up quickly, without a hot retry loop when it is genuinely gone.
    private static let retryMaxDelayMs: Int64 = 120_000

    /// How long a `.linkRejected` latch holds before trying once more. See
    /// `scheduleStaleCacheRetry` — long enough not to spin the radio on handles that cannot work,
    /// short enough that a firmware flash does not cost the user their whole day.
    private static let staleCacheRetryDelayMs: Int64 = 5 * 60_000

    /// How long `.connecting` may go without progress before the floor re-drives it. Comfortably
    /// longer than a healthy connect + discovery + subscribe (a few seconds), so it never fires in
    /// normal use; short enough that a wedged automatic attempt costs a minute rather than a day.
    private static let connectingFloorMs: Int64 = 90_000
}

extension CoreBluetoothAudioGattLink: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        // Defense in depth: bind to the first manager we see and ignore any stray callback from
        // a different instance, so a transient/orphaned manager cannot tear down a healthy link.
        if centralManager == nil { centralManager = central }
        guard central === centralManager else {
            log("ignoring state \(central.state.rawValue) from non-current central")
            return
        }
        log("centralManagerDidUpdateState -> \(central.state.rawValue), wantConnected=\(wantConnected)")
        switch central.state {
        case .poweredOn:
            // `hasPendingConnect` is the guard that protects state restoration. On a relaunch
            // `willRestoreState` runs FIRST and issues the restored connect; this callback then
            // arrived and started a second attempt over the top of it, re-arming the give-up
            // watchdog and possibly dialling a different peripheral than the one iOS handed back.
            // A launch-time `connect()` that ran before the radio was up also sits at
            // `.connecting`, and that one genuinely needs driving here — the pending flag is what
            // tells the two apart.
            if wantConnected && connectionState.value != .ready && !hasPendingConnect {
                // A Bluetooth power-cycle is exactly the recovery signal a LinkRejected failure
                // needs: CoreBluetooth re-discovers, so a stale-cache handshake now succeeds.
                awaitingUserRecovery = false
                connectAttempts = 0
                enterConnecting("Bluetooth powered on")
                connectWhenPoweredOn(central)
            } else if hasPendingConnect {
                log("Bluetooth powered on; leaving the outstanding connect alone")
            }
        // Surface an actionable reason instead of hanging in "Connecting". wantConnected is kept
        // set, so the link reconnects automatically once Bluetooth comes back. Shared with
        // `connect()`, which reads the same state as a LEVEL — see `applyPowerState`, and the
        // reason it must: the manager is created before `wantConnected` is ever true, so the one
        // initial report a powered-off radio produces used to be dropped on the floor here.
        default:
            if wantConnected { applyPowerState(central.state) }
        }
    }

    #if os(iOS)
    public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        if centralManager == nil { centralManager = central }
        guard central === centralManager else { return }
        let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral]
        guard let restored = peripherals?.first else { return }
        log("willRestoreState restored peripheral \(restored.identifier.uuidString) (\(peripherals?.count ?? 0) total)")
        wantConnected = true
        peripheral = restored
        restored.delegate = self
        rememberPeripheral(restored)
        // A restoration relaunch is a background wake with nobody watching, so the connect is left
        // pending rather than watchdogged into a dead end.
        enterConnecting("restore", automatic: true)
        hasPendingConnect = true
        central.connect(restored, options: nil)
    }
    #endif

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        log("didDiscoverPeripheral \(peripheral.name ?? "?") rssi=\(RSSI); connecting")
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        rememberPeripheral(peripheral)
        // The advertisement carries a name even when the peripheral object has not resolved one
        // yet, which is the usual case on the very first pairing — exactly when Settings most
        // needs to name the watch it just found.
        publishName(advertisementData[CBAdvertisementDataLocalNameKey] as? String)
        hasPendingConnect = true
        central.connect(peripheral, options: nil)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        hasPendingConnect = false
        log("didConnectPeripheral \(peripheral.name ?? "?"); discovering services")
        // A successful connect clears any lingering watchdog-cancel flag (a cancelled *pending*
        // connect fires no disconnect callback to clear it), so a later real drop still
        // reconnects.
        intentionalDisconnect = false
        self.peripheral = peripheral
        peripheral.delegate = self
        rememberPeripheral(peripheral)
        enterConnecting("connected, discovering services")
        peripheral.discoverServices([AudioCompanionGattIds.serviceUUID])
    }

    public func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        hasPendingConnect = false
        log("didFailToConnectPeripheral error=\(describeError(error))")
        failAndReset(classifyFailure(error, fallback: .watchUnreachable))
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        hasPendingConnect = false
        log("didDisconnectPeripheral intentional=\(intentionalDisconnect) wantConnected=\(wantConnected) error=\(describeError(error))")
        resetCharacteristics()
        if intentionalDisconnect || !wantConnected {
            intentionalDisconnect = false
            lastFailure.value = nil
            // A watchdog-driven cancel sets intentionalDisconnect to suppress this path; it
            // re-drives the connect itself, so leaving the state at Connecting (not
            // Disconnected) here is correct. Only a genuine user disconnect
            // (wantConnected == false) settles to idle.
            if !wantConnected {
                connectGeneration += 1
                connectionState.value = .disconnected
                log("-> Disconnected (intentional)")
            }
            return
        }
        // A LinkRejected failure latched off automatic retries: reconnecting to the same stale
        // cache just re-fails, so stay Disconnected until a Bluetooth power-cycle or user
        // Reconnect.
        if awaitingUserRecovery {
            log("unexpected drop; not reconnecting (awaiting user recovery)")
            connectionState.value = .disconnected
            return
        }
        // Unexpected drop while we still want the link (watch out of range or reset). Re-issue a
        // pending connect: CoreBluetooth resolves it with no timeout when the watch returns,
        // even from a SUSPENDED app, waking us through `bluetooth-central`.
        //
        // TRAP: this attempt must NOT get the give-up watchdog. That watchdog exists so a user
        // staring at the screen is not left on an indefinite spinner — but here it was cancelling
        // the one mechanism that survives suspension, and after three cancels it gave up for good.
        // A backgrounded app then sat Disconnected with nothing left to try, which is how a drop
        // at 14:12 was still a drop at 17:58. The pending connect costs nothing while it waits.
        enterConnecting("unexpected drop, reconnecting", automatic: true)
        hasPendingConnect = true
        central.connect(peripheral, options: nil)
    }
}

extension CoreBluetoothAudioGattLink: CBPeripheralDelegate {
    /// A watch renamed on the watch (or a name that only resolves after connecting) updates the
    /// name Settings shows without waiting for a relaunch.
    public func peripheralDidUpdateName(_ peripheral: CBPeripheral) {
        publishName(peripheral.name)
    }

    /// The watch's GATT database changed under us. THE signal this app was missing.
    ///
    /// iOS delivers this when the peer sends a Service Changed indication — a firmware flash, or a
    /// watch reboot that rebuilt its attribute table. Every `CBService` and `CBCharacteristic`
    /// object we hold for the invalidated services is now a dangling handle: reads and writes
    /// against them fail with ATT errors, and notifications simply stop. Ignoring it left the link
    /// sitting at `.ready`, fully "connected", silently receiving nothing — and the first write
    /// afterwards came back `.writeNotPermitted`, which the app read as a stale cache and latched
    /// off automatic recovery for. The watch reboot the user did not think twice about therefore
    /// ended recording until they opened the app and tapped Reconnect.
    ///
    /// Rediscovery is the whole fix, and it is cheap: our handles are already gone, so this cannot
    /// disturb a link that was working. The latch is cleared because a Service Changed indication
    /// is proof the OS has fresh handles — the exact condition `.linkRejected` was waiting for.
    public func peripheral(
        _ peripheral: CBPeripheral,
        didModifyServices invalidatedServices: [CBService]
    ) {
        let ours = invalidatedServices.contains { $0.uuid == AudioCompanionGattIds.serviceUUID }
        log("didModifyServices invalidated=\(invalidatedServices.map { $0.uuid.uuidString }) ours=\(ours)")
        guard ours || invalidatedServices.isEmpty else { return }
        awaitingUserRecovery = false
        resetCharacteristics(reason: "the watch's services changed")
        guard peripheral === self.peripheral, wantConnected else { return }
        // Re-run the handshake on the SAME connection: the ACL is fine, only the attribute table
        // moved. `enterConnecting` re-arms the watchdog so a rediscovery that stalls is not a new
        // way to sit at "Connecting" forever.
        enterConnecting("services changed, rediscovering", automatic: automaticConnect)
        peripheral.discoverServices([AudioCompanionGattIds.serviceUUID])
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            log("didDiscoverServices error=\(describeError(error))")
            failAndReset(classifyFailure(error, fallback: .unknown))
            return
        }
        guard let service = peripheral.services?.first(where: {
            $0.uuid == AudioCompanionGattIds.serviceUUID
        }) else {
            let found = peripheral.services?.map { $0.uuid.uuidString } ?? []
            log("didDiscoverServices: companion service missing; found=\(found)")
            failAndReset(.unknown, "Audio Companion service not found")
            return
        }
        log("didDiscoverServices ok; discovering characteristics")
        peripheral.discoverCharacteristics(
            [
                AudioCompanionGattIds.infoCharacteristicUUID,
                AudioCompanionGattIds.controlCharacteristicUUID,
                AudioCompanionGattIds.dataCharacteristicUUID,
            ],
            for: service
        )
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error {
            log("didDiscoverCharacteristics error=\(describeError(error))")
            failAndReset(classifyFailure(error, fallback: .unknown))
            return
        }
        let characteristics = service.characteristics ?? []
        infoCharacteristic = characteristics.first {
            $0.uuid == AudioCompanionGattIds.infoCharacteristicUUID
        }
        controlCharacteristic = characteristics.first {
            $0.uuid == AudioCompanionGattIds.controlCharacteristicUUID
        }
        dataCharacteristic = characteristics.first {
            $0.uuid == AudioCompanionGattIds.dataCharacteristicUUID
        }
        guard infoCharacteristic != nil,
              let control = controlCharacteristic,
              let data = dataCharacteristic
        else {
            log("didDiscoverCharacteristics: missing one of info/control/data")
            failAndReset(.unknown, "Audio Companion characteristics not found")
            return
        }
        log("didDiscoverCharacteristics ok; subscribing notifications")
        pendingNotifyCharacteristics = [control, data]
        // Keep arming the watchdog: CCCD subscription is the last handshake step that can stall.
        enterConnecting("subscribing notifications")
        peripheral.setNotifyValue(true, for: pendingNotifyCharacteristics.removeFirst())
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            // Subscribing writes the characteristic's CCCD. A rejection here is an ATT-level
            // refusal (CBATTErrorDomain) — in practice a stale iOS GATT cache after a firmware
            // update, where the cached handle no longer points at a writable descriptor
            // ("Writing is not permitted."). Classify it as LinkRejected so the UI tells the
            // user to power-cycle Bluetooth instead of showing the raw Core Bluetooth string.
            log("didUpdateNotificationState error=\(describeError(error))")
            failAndReset(classifyFailure(error, fallback: .linkRejected))
            return
        }
        if pendingNotifyCharacteristics.isEmpty {
            reachReady()
        } else {
            peripheral.setNotifyValue(true, for: pendingNotifyCharacteristics.removeFirst())
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        let value: [UInt8] = characteristic.value.map { Array($0) } ?? []
        switch characteristic.uuid {
        case AudioCompanionGattIds.infoCharacteristicUUID:
            guard let pending = pendingInfoRead else { return }
            pendingInfoRead = nil
            pending.ticket.settled = true
            if let error {
                pending.continuation.resume(
                    throwing: LinkOperationError.failed(error.localizedDescription)
                )
            } else {
                pending.continuation.resume(returning: value)
            }
        case AudioCompanionGattIds.controlCharacteristicUUID:
            if error == nil {
                onInboundNotification()
                controlChannel.send(value)
            } else {
                // Previously dropped in silence. A run of these is the signature of a link the
                // platform still calls connected while nothing gets through, and without a line
                // in the log there was no way to tell that from an idle watch.
                log("control notification error: \(describeError(error))")
            }
        case AudioCompanionGattIds.dataCharacteristicUUID:
            if error == nil {
                onInboundNotification()
                dataChannel.send(value)
            } else {
                log("data notification error: \(describeError(error))")
            }
        default:
            break
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == AudioCompanionGattIds.controlCharacteristicUUID else { return }
        guard let pending = pendingControlWrite else { return }
        pendingControlWrite = nil
        pending.ticket.settled = true
        if let error {
            pending.continuation.resume(
                throwing: LinkOperationError.failed(error.localizedDescription)
            )
        } else {
            pending.continuation.resume(returning: ())
        }
    }
}

private extension CBPeripheral {
    var isLikelyPebble: Bool {
        name?.range(of: "Pebble", options: .caseInsensitive) != nil
    }
}

/// Short, stable words for a link state — for the log, never for the screen.
private func describe(_ state: LinkState) -> String {
    switch state {
    case .disconnected: return "disconnected"
    case .connecting: return "connecting"
    case .ready: return "ready"
    }
}
#endif
