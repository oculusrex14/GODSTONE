import Foundation
import CoreBluetooth

/// BLE control plane. Always on, duty-cycled, background-capable (with the
/// caveats documented below and surfaced in the UI).
///
/// Every device is simultaneously a central and a peripheral. There are no
/// clients and no servers in a survival mesh — the topology must survive any
/// single device walking away.
public final class BleTransport: NSObject {

    public static let serviceUuid = CBUUID(string: "6F0D0001-9A5E-4C7B-B0A1-3E5D8C2F7A10")
    public static let inboxCharacteristicUuid = CBUUID(string: "6F0D0002-9A5E-4C7B-B0A1-3E5D8C2F7A10")
    public static let digestCharacteristicUuid = CBUUID(string: "6F0D0003-9A5E-4C7B-B0A1-3E5D8C2F7A10")

    private var central: CBCentralManager!
    private var peripheral: CBPeripheralManager!

    private var connected: [UUID: CBPeripheral] = [:]
    private var inboxCharacteristics: [UUID: CBCharacteristic] = [:]
    private var subscribers: [CBCentral] = []

    public weak var delegate: TransportDelegate?

    /// iOS truncates advertisement data heavily in the background: the service
    /// UUID moves to the "overflow area", which is only visible to other iOS
    /// devices explicitly scanning for that exact UUID. Android scanners cannot
    /// see a backgrounded iPhone at all. This is a platform fact, not a bug we
    /// can fix, and the UI tells the user so rather than pretending otherwise.
    public private(set) var isBackgrounded = false

    public override init() {
        super.init()
        // Restoration identifiers let iOS relaunch us into the background when a
        // peer appears — the only way to get any background mesh behaviour at all.
        central = CBCentralManager(
            delegate: self, queue: .global(qos: .utility),
            options: [CBCentralManagerOptionRestoreIdentifierKey: "io.godstone.central"])
        peripheral = CBPeripheralManager(
            delegate: self, queue: .global(qos: .utility),
            options: [CBPeripheralManagerOptionRestoreIdentifierKey: "io.godstone.peripheral"])
    }

    public func start() {
        startAdvertising()
        startScanning()
    }

    public func stop() {
        central.stopScan()
        peripheral.stopAdvertising()
    }

    private func startScanning() {
        guard central.state == .poweredOn else { return }
        central.scanForPeripherals(
            withServices: [BleTransport.serviceUuid],
            // Duplicates ON in foreground so we track RSSI and liveness; OFF in
            // background because iOS coalesces them anyway and it saves battery.
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: !isBackgrounded])
    }

    private func startAdvertising() {
        guard peripheral.state == .poweredOn else { return }
        peripheral.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [BleTransport.serviceUuid],
            CBAdvertisementDataLocalNameKey: "GS"
        ])
    }

    public func setBackgrounded(_ backgrounded: Bool) {
        isBackgrounded = backgrounded
        central.stopScan()
        startScanning()
    }

    public func send(_ frame: Frame, to peerId: UUID) {
        guard let p = connected[peerId],
              let ch = inboxCharacteristics[peerId] else { return }
        let data = frame.encode()

        // Fragment to the negotiated ATT MTU. iOS reports the usable payload
        // directly, so we never have to guess at the 3-byte ATT header.
        let mtu = p.maximumWriteValueLength(for: .withoutResponse)
        for chunk in data.chunked(into: mtu) {
            p.writeValue(chunk, for: ch, type: .withoutResponse)
        }
    }
}

extension BleTransport: CBCentralManagerDelegate, CBPeripheralDelegate {

    public func centralManagerDidUpdateState(_ c: CBCentralManager) {
        if c.state == .poweredOn { startScanning() }
    }

    public func centralManager(_ c: CBCentralManager,
                               willRestoreState dict: [String: Any]) {
        if let peers = dict[CBCentralManagerRestoredStatePeripheralsKey]
            as? [CBPeripheral] {
            for p in peers {
                p.delegate = self
                connected[p.identifier] = p
            }
        }
    }

    public func centralManager(_ c: CBCentralManager,
                               didDiscover p: CBPeripheral,
                               advertisementData: [String: Any],
                               rssi RSSI: NSNumber) {
        // Ignore anything we can barely hear: connecting to a -95 dBm peer wastes
        // far more energy than the link is ever worth.
        guard RSSI.intValue > -90 else { return }

        connected[p.identifier] = p
        p.delegate = self
        c.connect(p, options: nil)
    }

    public func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        p.discoverServices([BleTransport.serviceUuid])
        delegate?.transportDidConnect(peerId: p.identifier)
    }

    public func centralManager(_ c: CBCentralManager,
                               didDisconnectPeripheral p: CBPeripheral,
                               error: Error?) {
        inboxCharacteristics.removeValue(forKey: p.identifier)
        delegate?.transportDidDisconnect(peerId: p.identifier)
        // Always reconnect. In a survival mesh, a dropped link is the normal
        // state, not an error condition.
        c.connect(p, options: nil)
    }

    public func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        p.services?.forEach {
            p.discoverCharacteristics(
                [BleTransport.inboxCharacteristicUuid,
                 BleTransport.digestCharacteristicUuid], for: $0)
        }
    }

    public func peripheral(_ p: CBPeripheral,
                           didDiscoverCharacteristicsFor service: CBService,
                           error: Error?) {
        for ch in service.characteristics ?? [] {
            if ch.uuid == BleTransport.inboxCharacteristicUuid {
                inboxCharacteristics[p.identifier] = ch
                p.setNotifyValue(true, for: ch)
            }
        }
        delegate?.transportReady(peerId: p.identifier)
    }

    public func peripheral(_ p: CBPeripheral,
                           didUpdateValueFor ch: CBCharacteristic,
                           error: Error?) {
        guard let data = ch.value else { return }
        delegate?.transportDidReceive(data: data, peerId: p.identifier)
    }
}

extension BleTransport: CBPeripheralManagerDelegate {

    public func peripheralManagerDidUpdateState(_ pm: CBPeripheralManager) {
        guard pm.state == .poweredOn else { return }

        let inbox = CBMutableCharacteristic(
            type: BleTransport.inboxCharacteristicUuid,
            properties: [.writeWithoutResponse, .notify],
            value: nil,
            permissions: [.writeable])

        let digest = CBMutableCharacteristic(
            type: BleTransport.digestCharacteristicUuid,
            properties: [.read, .notify],
            value: nil,
            permissions: [.readable])

        let service = CBMutableService(type: BleTransport.serviceUuid, primary: true)
        service.characteristics = [inbox, digest]
        pm.add(service)

        startAdvertising()
    }

    public func peripheralManager(_ pm: CBPeripheralManager,
                                  didReceiveWrite requests: [CBATTRequest]) {
        for r in requests {
            if let v = r.value {
                delegate?.transportDidReceive(data: v, peerId: r.central.identifier)
            }
        }
        pm.respond(to: requests[0], withResult: .success)
    }

    public func peripheralManager(_ pm: CBPeripheralManager,
                                  central: CBCentral,
                                  didSubscribeTo ch: CBCharacteristic) {
        subscribers.append(central)
    }
}

public protocol TransportDelegate: AnyObject {
    func transportDidConnect(peerId: UUID)
    func transportReady(peerId: UUID)
    func transportDidDisconnect(peerId: UUID)
    func transportDidReceive(data: Data, peerId: UUID)
}

extension Data {
    func chunked(into size: Int) -> [Data] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            subdata(in: $0..<Swift.min($0 + size, count))
        }
    }
}
