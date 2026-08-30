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
    private var pendingInfoRead: CheckedContinuation<[UInt8], Error>?
    private var pendingControlWrite: CheckedContinuation<Void, Error>?
    private var pendingNotifyCharacteristics: [CBCharacteristic] = []

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

    /// State restoration is opt-in via `restoreIdentifier` (pass nil to disable, e.g. for tools).
    public init(
        restoreIdentifier: String? = AudioCompanionGattIds.restoreIdentifier,
        defaults: UserDefaults = .standard
    ) {
        self.restoreIdentifier = restoreIdentifier
        self.defaults = defaults
        super.init()
    }

    /// NSLog so the live device log shows every Core Bluetooth transition with a stable,
    /// greppable tag. This is the only place the adapter logs; it stays out of the data hot path
    /// (notifications are not logged per-frame).
    private func log(_ message: String) {
        NSLog(
            "%@ state=%@ gen=%d attempt=%d %@",
            Self.logTag, String(describing: connectionState.value), connectGeneration,
            connectAttempts, message
        )
    }

    /// Runs `block` on the main (delegate) serial queue. All Core Bluetooth interaction and link
    /// state mutation funnels through here so lifecycle calls from arbitrary threads are
    /// serialized with the manager's delegate callbacks (delivered on this queue).
    private func onMainQueue(_ block: @escaping @Sendable () -> Void) {
        DispatchQueue.main.async(execute: block)
    }

    /// Joins the existing system link when possible:
    /// retrieveConnectedPeripherals(withServices:) -> connect(); otherwise a pending connect()
    /// on the stored peripheral identifier. Scanning is a foreground-only onboarding fallback.
    public func connect() {
        onMainQueue { [self] in
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
            enterConnecting("connect()")
            if manager.state == .poweredOn {
                connectWhenPoweredOn(manager)
            }
        }
    }

    private func makeCentralManager() -> CBCentralManager {
        var options: [String: Any] = [:]
        #if os(iOS)
        if let restoreIdentifier {
            options[CBCentralManagerOptionRestoreIdentifierKey] = restoreIdentifier
        }
        #endif
        let manager = CBCentralManager(delegate: self, queue: .main, options: options)
        centralManager = manager
        return manager
    }

    public func disconnect() {
        onMainQueue { [self] in
            log("disconnect() requested")
            wantConnected = false
            awaitingUserRecovery = false
            connectGeneration += 1 // invalidate any pending watchdog
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
        onMainQueue { [self] in
            log("resync() requested")
            // Explicit "Reconnect": honor the request even if we had latched off automatic retries.
            awaitingUserRecovery = false
            guard let manager = centralManager else {
                connect()
                return
            }
            wantConnected = true
            connectAttempts = 0
            manager.stopScan()
            if let current = peripheral {
                // Not an intentional (user) disconnect: didDisconnect re-issues the connect
                // because wantConnected stays true, so the link rebuilds itself.
                intentionalDisconnect = false
                enterConnecting("resync (cancel + reconnect)")
                manager.cancelPeripheralConnection(current)
            } else if manager.state == .poweredOn {
                enterConnecting("resync (fresh)")
                connectWhenPoweredOn(manager)
            }
        }
    }

    public func readInfo() async throws -> [UInt8] {
        try await withCheckedThrowingContinuation { continuation in
            self.onMainQueue { [self] in
                guard let localPeripheral = peripheral else {
                    continuation.resume(throwing: LinkOperationError.notConnected)
                    return
                }
                guard let characteristic = infoCharacteristic else {
                    continuation.resume(throwing: LinkOperationError.characteristicNotReady)
                    return
                }
                guard pendingInfoRead == nil else {
                    continuation.resume(throwing: LinkOperationError.operationInFlight)
                    return
                }
                pendingInfoRead = continuation
                localPeripheral.readValue(for: characteristic)
            }
        }
    }

    public func writeControl(_ message: [UInt8]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.onMainQueue { [self] in
                guard let localPeripheral = peripheral else {
                    continuation.resume(throwing: LinkOperationError.notConnected)
                    return
                }
                guard let characteristic = controlCharacteristic else {
                    continuation.resume(throwing: LinkOperationError.characteristicNotReady)
                    return
                }
                guard pendingControlWrite == nil else {
                    continuation.resume(throwing: LinkOperationError.operationInFlight)
                    return
                }
                pendingControlWrite = continuation
                localPeripheral.writeValue(Data(message), for: characteristic, type: .withResponse)
            }
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
        manager.connect(target, options: nil)
    }

    private func rememberPeripheral(_ target: CBPeripheral) {
        defaults.set(target.identifier.uuidString, forKey: Self.keyPeripheralIdentifier)
    }

    /// Moves into `.connecting` and (re)arms the handshake watchdog. Every step that keeps us
    /// mid-handshake (issuing a connect, a discovery callback, a CCCD subscription) calls this
    /// so the watchdog window restarts on real progress and only fires when a step truly stalls.
    private func enterConnecting(_ reason: String) {
        lastFailure.value = nil
        connectGeneration += 1
        connectionState.value = .connecting
        log("-> Connecting (\(reason))")
        armWatchdog(connectGeneration)
    }

    /// Reached the fully-subscribed, usable link. Cancels the watchdog and resets retry counters.
    private func reachReady() {
        connectGeneration += 1 // invalidate any pending watchdog
        connectAttempts = 0
        awaitingUserRecovery = false
        lastFailure.value = nil
        connectionState.value = .ready
        log("-> Ready")
    }

    /// Schedules a one-shot timeout for `generation`. The block re-checks that its generation is
    /// still current and we are still Connecting before acting; a completed/superseded attempt
    /// makes it a no-op. Runs on the main (delegate) queue, so it is serialized with every Core
    /// Bluetooth callback.
    private func armWatchdog(_ generation: Int) {
        DispatchQueue.main.asyncAfter(
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
        let message = failure.detail ?? "connection failed"
        pendingInfoRead?.resume(throwing: LinkOperationError.failed(message))
        pendingInfoRead = nil
        pendingControlWrite?.resume(throwing: LinkOperationError.failed(message))
        pendingControlWrite = nil
        centralManager?.stopScan()
        resetCharacteristics()
        // A stale-cache / re-pair failure won't clear by retrying the same handles, so latch off
        // the automatic reconnects (connect() on foreground, unexpected-drop reconnect) until
        // Bluetooth is power-cycled or the user taps Reconnect. Any other failure keeps the
        // normal auto-retry.
        awaitingUserRecovery = failure.kind == .linkRejected
        lastFailure.value = failure
        connectionState.value = .disconnected
        log("-> Disconnected (\(failure.kind): \(message))")
    }

    /// Classifies a Core Bluetooth error by its error DOMAIN — never its localized message.
    /// `CBATTErrorDomain` means the watch's ATT server refused the operation (write/read not
    /// permitted, insufficient encryption/authentication) — the stale-GATT-cache signature;
    /// `CBErrorDomain` covers link-level trouble.
    private func classifyFailure(_ error: Error?, fallback: ConnectFailureKind) -> ConnectFailure {
        let nsError = error as NSError?
        let kind: ConnectFailureKind
        switch nsError?.domain {
        case CBATTErrorDomain:
            kind = .linkRejected
        case CBErrorDomain:
            kind = .watchUnreachable
        default:
            kind = fallback
        }
        return ConnectFailure(kind: kind, detail: nsError?.localizedDescription)
    }

    private func resetCharacteristics() {
        infoCharacteristic = nil
        controlCharacteristic = nil
        dataCharacteristic = nil
        pendingNotifyCharacteristics.removeAll()
    }

    private enum LinkOperationError: Error {
        case notConnected
        case characteristicNotReady
        case operationInFlight
        case failed(String)
    }

    private static let keyPeripheralIdentifier = "ios_audio_companion_peripheral_identifier"

    /// Stable, greppable prefix for the live device log.
    private static let logTag = "[AudioGattLink]"

    /// How long a single connect/handshake step may stall before the watchdog re-drives it.
    /// CoreBluetooth `connect()` itself never times out, so this is the only bound on a pended
    /// connection. Sized to comfortably cover a healthy connect + discovery + CCCD round trip
    /// to a Pebble (a few seconds) without making a genuine stall feel indefinite.
    private static let connectWatchdogMs: Int64 = 10_000

    /// Consecutive stalls before we stop retrying and surface an actionable error.
    private static let connectMaxAttempts = 3
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
            if wantConnected && connectionState.value != .ready {
                // A Bluetooth power-cycle is exactly the recovery signal a LinkRejected failure
                // needs: CoreBluetooth re-discovers, so a stale-cache handshake now succeeds.
                awaitingUserRecovery = false
                connectAttempts = 0
                enterConnecting("Bluetooth powered on")
                connectWhenPoweredOn(central)
            }
        // Surface an actionable reason instead of hanging in "Connecting". wantConnected is
        // kept set, so the link reconnects automatically once Bluetooth comes back.
        case .poweredOff:
            if wantConnected {
                failAndReset(.bluetoothOff, "Bluetooth is turned off")
            }
        case .unauthorized:
            if wantConnected {
                failAndReset(
                    .bluetoothUnauthorized,
                    "Bluetooth access is off for this app. Turn it on in Settings."
                )
            }
        case .unsupported:
            if wantConnected {
                failAndReset(
                    .bluetoothUnavailable,
                    "Bluetooth is unavailable to this app right now."
                )
            }
        case .unknown, .resetting:
            if wantConnected {
                // Core Bluetooth is still starting or briefly restarted its system service.
                // Clear stale failures (and the retry latch) so the main status does not keep
                // showing an old error.
                awaitingUserRecovery = false
                enterConnecting("Bluetooth resetting/unknown")
            }
        @unknown default:
            break
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
        enterConnecting("restore")
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
        central.connect(peripheral, options: nil)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
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
        log("didFailToConnectPeripheral error=\(error?.localizedDescription ?? "nil")")
        failAndReset(classifyFailure(error, fallback: .watchUnreachable))
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        log("didDisconnectPeripheral intentional=\(intentionalDisconnect) wantConnected=\(wantConnected) error=\(error?.localizedDescription ?? "nil")")
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
        // even in the background, so the receiver reconnects on its own (the watch buffers the
        // gap). The watchdog still guards this re-issued connect so it cannot pend forever.
        enterConnecting("unexpected drop, reconnecting")
        central.connect(peripheral, options: nil)
    }
}

extension CoreBluetoothAudioGattLink: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            log("didDiscoverServices error=\(error.localizedDescription)")
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
            log("didDiscoverCharacteristics error=\(error.localizedDescription)")
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
            log("didUpdateNotificationState error=\(error.localizedDescription)")
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
            guard let continuation = pendingInfoRead else { return }
            pendingInfoRead = nil
            if let error {
                continuation.resume(throwing: LinkOperationError.failed(error.localizedDescription))
            } else {
                continuation.resume(returning: value)
            }
        case AudioCompanionGattIds.controlCharacteristicUUID:
            if error == nil { controlChannel.send(value) }
        case AudioCompanionGattIds.dataCharacteristicUUID:
            if error == nil { dataChannel.send(value) }
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
        guard let continuation = pendingControlWrite else { return }
        pendingControlWrite = nil
        if let error {
            continuation.resume(throwing: LinkOperationError.failed(error.localizedDescription))
        } else {
            continuation.resume(returning: ())
        }
    }
}

private extension CBPeripheral {
    var isLikelyPebble: Bool {
        name?.range(of: "Pebble", options: .caseInsensitive) != nil
    }
}
#endif
