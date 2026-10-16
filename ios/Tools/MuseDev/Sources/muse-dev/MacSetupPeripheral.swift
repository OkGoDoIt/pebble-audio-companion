import CoreBluetooth
import Foundation
import MuseLink

/// This Mac as the BLE side of a Muse gadget's setup: the setup service with its RX (write) and TX
/// (read + notify) characteristics, advertised as `MuseGadgetXXXXXX`. Every write goes to the
/// `MuseSetupController`; every packet it sends is notified on TX, waiting out CoreBluetooth's
/// queue when it is full.
///
/// Differences from Meta's Linux gadget that the Muse app might notice (unknown until tried):
/// macOS can't advertise manufacturer data (the "paired" byte), and the GAP device name is the
/// Mac's own name. If the app won't list or accept this Mac, the watch — which can do both — is
/// the real fix.
final class MacSetupPeripheral: NSObject, CBPeripheralManagerDelegate, MuseSetupTransport, @unchecked Sendable {
    static let serviceUUID = CBUUID(string: "7fdd3d1c-38ea-46cf-8b46-314ecf5f240c")
    static let rxUUID = CBUUID(string: "4d593029-28a2-4a6e-a1f0-3c2d5e8f9b01")
    static let txUUID = CBUUID(string: "d75dc4ca-7b2b-4e9c-8f0a-1d2e3f4a5b6c")

    private let queue = DispatchQueue(label: "muse-dev.peripheral")
    private let localName: String
    private var manager: CBPeripheralManager!
    private var tx: CBMutableCharacteristic?
    private var lastValue = Data()
    private var subscribers: [CBCentral] = []
    private var readyWaiters: [CheckedContinuation<Void, Never>] = []
    weak var controller: MuseSetupController?
    var onEvent: (String) -> Void = { print($0) }

    init(localName: String) {
        self.localName = localName
        super.init()
        manager = CBPeripheralManager(delegate: self, queue: queue)
    }

    func stop() {
        queue.sync {
            manager.stopAdvertising()
            manager.removeAllServices()
        }
    }

    // MARK: MuseSetupTransport

    func send(_ packet: Data) async {
        while true {
            let sent: Bool = queue.sync {
                lastValue = packet
                guard let tx, !subscribers.isEmpty else { return true }  // nobody to notify; drop
                return manager.updateValue(packet, for: tx, onSubscribedCentrals: nil)
            }
            if sent { return }
            await withCheckedContinuation { continuation in
                queue.async { self.readyWaiters.append(continuation) }
            }
        }
    }

    func disconnect(after delay: Duration) async {
        // CoreBluetooth gives a peripheral no way to drop a central; the app times out instead.
        onEvent("(would disconnect the Muse app now; macOS can't, it will time out)")
    }

    // MARK: CBPeripheralManagerDelegate (on `queue`)

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            let service = CBMutableService(type: Self.serviceUUID, primary: true)
            let rx = CBMutableCharacteristic(
                type: Self.rxUUID, properties: [.write, .writeWithoutResponse], value: nil,
                permissions: [.writeable])
            let tx = CBMutableCharacteristic(
                type: Self.txUUID, properties: [.read, .notify], value: nil, permissions: [.readable])
            service.characteristics = [rx, tx]
            self.tx = tx
            peripheral.add(service)
        case .unauthorized:
            onEvent("Bluetooth permission was denied. Allow it in System Settings › Privacy & Security › Bluetooth, then run again.")
        case .poweredOff:
            onEvent("Bluetooth is off on this Mac.")
        default:
            break
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            onEvent("couldn't add the setup service: \(error.localizedDescription)")
            return
        }
        peripheral.startAdvertising([
            CBAdvertisementDataLocalNameKey: localName,
            CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID],
        ])
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error {
            onEvent("advertising failed: \(error.localizedDescription)")
        } else {
            onEvent("advertising as \(localName)")
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        guard characteristic.uuid == Self.txUUID else { return }
        if !subscribers.contains(where: { $0.identifier == central.identifier }) { subscribers.append(central) }
        let mtu = central.maximumUpdateValueLength + 3
        onEvent("Muse app subscribed (notify payload \(central.maximumUpdateValueLength) bytes)")
        Task { await controller?.updateMTU(mtu) }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        guard characteristic.uuid == Self.txUUID else { return }
        subscribers.removeAll { $0.identifier == central.identifier }
        onEvent("Muse app unsubscribed")
        controller?.clientDisconnected()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests where request.characteristic.uuid == Self.rxUUID {
            if let value = request.value { controller?.receive(value) }
        }
        if let first = requests.first { peripheral.respond(to: first, withResult: .success) }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard request.characteristic.uuid == Self.txUUID else {
            peripheral.respond(to: request, withResult: .requestNotSupported)
            return
        }
        guard request.offset <= lastValue.count else {
            peripheral.respond(to: request, withResult: .invalidOffset)
            return
        }
        request.value = lastValue.subdata(in: request.offset..<lastValue.count)
        peripheral.respond(to: request, withResult: .success)
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        let waiters = readyWaiters
        readyWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
