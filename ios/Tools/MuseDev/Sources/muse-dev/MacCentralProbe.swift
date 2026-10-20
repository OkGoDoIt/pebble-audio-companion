import CoreBluetooth
import Foundation

/// This Mac as a BLE *central* against a Muse gadget setup advertiser: finds a `MuseGadget…`
/// advertisement (by the setup service UUID), connects, discovers the service, subscribes to TX,
/// writes a test payload to RX and prints what comes back, with timings.
///
/// It exists to answer one question about the watch: does its radio accept a second connection
/// (from this Mac) while the iPhone's connection is up? If this works and the iPhone's connect
/// attempt doesn't, the fault is on the iPhone side, not the watch's.
final class MacCentralProbe: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    static let serviceUUID = CBUUID(string: "7fdd3d1c-38ea-46cf-8b46-314ecf5f240c")
    static let rxUUID = CBUUID(string: "4d593029-28a2-4a6e-a1f0-3c2d5e8f9b01")
    static let txUUID = CBUUID(string: "d75dc4ca-7b2b-4e9c-8f0a-1d2e3f4a5b6c")

    private let queue = DispatchQueue(label: "muse-dev.central")
    private var manager: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rx: CBCharacteristic?
    private var tx: CBCharacteristic?
    private let started = ContinuousClock.now
    private var connectStarted: ContinuousClock.Instant?
    private var writeStarted: ContinuousClock.Instant?
    private let payload = Data("muse-dev probe \(Int.random(in: 1000...9999))".utf8)
    private let done: (Bool) -> Void
    private let nameFilter: String?
    private var seen: Set<UUID> = []

    init(nameFilter: String?, done: @escaping (Bool) -> Void) {
        self.nameFilter = nameFilter
        self.done = done
        super.init()
        manager = CBCentralManager(delegate: self, queue: queue)
    }

    private func t() -> String {
        (ContinuousClock.now - started).formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow))
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            say("[\(t())] scanning for the Muse setup service\(nameFilter.map { " (\($0))" } ?? "")…")
            // Not filtered by UUID on purpose: the watch puts the 128-bit UUID in the main
            // advertisement, but a wildcard scan also shows how it looks next to everything else.
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        case .unauthorized:
            say("Bluetooth permission denied for Muse Dev; allow it in System Settings › Privacy & Security › Bluetooth.")
            done(false)
        case .poweredOff:
            say("Bluetooth is off on this Mac.")
            done(false)
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "(no name)"
        let uuids = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let mfg = (advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data).map { $0.map { String(format: "%02X", $0) }.joined() }
        let isMuse = uuids.contains(Self.serviceUUID) || name.hasPrefix("MuseGadget")
        if isMuse, !seen.contains(peripheral.identifier) {
            seen.insert(peripheral.identifier)
            say("[\(t())] found \(name) rssi \(RSSI) services \(uuids.map(\.uuidString)) mfg \(mfg ?? "-")")
        }
        guard isMuse, self.peripheral == nil else { return }
        if let nameFilter, !name.hasSuffix(nameFilter) { return }
        self.peripheral = peripheral
        peripheral.delegate = self
        central.stopScan()
        connectStarted = .now
        say("[\(t())] connecting to \(name)…")
        central.connect(peripheral, options: nil)
        queue.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.peripheral?.state != .connected else { return }
            say("[\(self.t())] still not connected after 20 s; giving up (state \(self.peripheral?.state.rawValue ?? -1))")
            if let p = self.peripheral { central.cancelPeripheralConnection(p) }
            self.done(false)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let took = connectStarted.map { (ContinuousClock.now - $0).formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow)) } ?? "?"
        say("[\(t())] connected in \(took); discovering services…")
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        say("[\(t())] connect FAILED: \(error?.localizedDescription ?? "no error given")")
        done(false)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        say("[\(t())] disconnected\(error.map { ": \($0.localizedDescription)" } ?? "")")
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            say("[\(t())] setup service not found: \(error?.localizedDescription ?? "absent")")
            done(false)
            return
        }
        peripheral.discoverCharacteristics([Self.rxUUID, Self.txUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        rx = service.characteristics?.first { $0.uuid == Self.rxUUID }
        tx = service.characteristics?.first { $0.uuid == Self.txUUID }
        guard let tx, rx != nil else {
            say("[\(t())] characteristics missing (rx \(rx != nil), tx \(tx != nil))")
            done(false)
            return
        }
        say("[\(t())] service ok; MTU \(peripheral.maximumWriteValueLength(for: .withoutResponse) + 3); subscribing to TX…")
        peripheral.setNotifyValue(true, for: tx)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, characteristic.isNotifying, let rx else {
            say("[\(t())] subscribe failed: \(error?.localizedDescription ?? "not notifying")")
            done(false)
            return
        }
        say("[\(t())] subscribed; writing \(payload.count) bytes to RX (expecting the watch to echo them)…")
        writeStarted = .now
        peripheral.writeValue(payload, for: rx, type: .withResponse)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { say("[\(t())] write failed: \(error.localizedDescription)") }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.txUUID, let value = characteristic.value else { return }
        let took = writeStarted.map { (ContinuousClock.now - $0).formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow)) } ?? "?"
        let text = String(decoding: value, as: UTF8.self)
        if value == payload {
            say("[\(t())] ECHO OK in \(took): \"\(text)\"")
            manager.cancelPeripheralConnection(peripheral)
            done(true)
        } else {
            say("[\(t())] TX notified \(value.count) bytes: \"\(text)\"")
        }
    }
}
