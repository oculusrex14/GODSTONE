import Foundation
import CoreBluetooth

/// BLE control plane. Always on, duty-cycled, background-capable (with the
/// caveats documented below and surfaced in the UI).
///
/// Every device is simultaneously a central and a peripheral. There are no
/// clients and no servers in a survival mesh — the topology must survive any
/// single device walking away.
public final class BleTransport: NSObject {

    // GENERATED-SPEC UUIDs. These previously read 6F0D0001-… while Android read
    // 67640001-… -- the two platforms could not see each other at all, so the
    // header-size and type-code defects were never even reached. The values now
    // come from wire/wire_v2.yaml via FrameV2 and cannot drift: Invariant G
    // fails the build if a literal UUID reappears here.
    public static let serviceUuid = CBUUID(string: FrameV2.serviceUuidString)
    public static let inboxCharacteristicUuid = CBUUID(string: FrameV2.inboxUuidString)
    public static let digestCharacteristicUuid = CBUUID(string: FrameV2.digestUuidString)

    private let central: CBCentralManager
    private let peripheral: CBPeripheralManager

    private var connected: [UUID: CBPeripheral] = [:]
    private var inboxCharacteristics: [UUID: CBCharacteristic] = [:]
    private var subscribers: [CBCentral] = []

    public weak var delegate: TransportDelegate?

    /// Noise sessions. Without this the transport cannot send -- by design.
    public var sessions: SessionManager?

    /// iOS truncates advertisement data heavily in the background: the service
    /// UUID moves to the "overflow area", which is only visible to other iOS
    /// devices explicitly scanning for that exact UUID. Android scanners cannot
    /// see a backgrounded iPhone at all. This is a platform fact, not a bug we
    /// can fix, and the UI tells the user so rather than pretending otherwise.
    public private(set) var isBackgrounded = false

    public override init() {
        // Both managers are constructed with a nil delegate and stored BEFORE
        // super.init(), then wired to self. CoreBluetooth dispatches state
        // callbacks on a global queue and could otherwise fire into a partly
        // initialised object (audit A-18). The restoration identifiers let iOS
        // relaunch us into the background when a peer appears.
        central = CBCentralManager(delegate: nil, queue: .global(qos: .utility), options: [CBCentralManagerOptionRestoreIdentifierKey: "io.godstone.central"])
        peripheral = CBPeripheralManager(delegate: nil, queue: .global(qos: .utility), options: [CBPeripheralManagerOptionRestoreIdentifierKey: "io.godstone.peripheral"])
        super.init()
        central.delegate = self
        peripheral.delegate = self
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

    /// Send [frame] to [peerId] THROUGH THE NOISE SESSION.
    ///
    /// This previously wrote `frame.encode()` directly to the characteristic.
    /// NoiseSession existed but nothing constructed it, so the "encrypted mesh"
    /// transmitted plaintext. There is no plaintext fallback here on purpose.
    @discardableResult
    public func send(_ frame: FrameV2, to peerId: UUID) -> Bool {
        guard let p = connected[peerId],
              let ch = inboxCharacteristics[peerId] else { return false }
        guard let data = sessions?.seal(peerId, frame.encode()) else { return false }

        // ADR-002/M2-link owns authenticated record fragmentation. Until that
        // layer exists, never split one Noise ciphertext into independent ATT
        // writes: the receiver would try to authenticate each fragment.
        let mtu = p.maximumWriteValueLength(for: .withoutResponse)
        guard data.count <= mtu else { return false }
        p.writeValue(data, for: ch, type: .withoutResponse)
        return true
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
        guard let raw = ch.value else { return }
        // Decrypt before anything downstream sees it. A frame that fails
        // authentication is corruption or an attacker: drop it silently.
        guard let clear = sessions?.open(p.identifier, raw) else { return }
        delegate?.transportDidReceive(data: clear, peerId: p.identifier)
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
        guard let first = requests.first else { return }
        for r in requests {
            if let v = r.value,
               let clear = sessions?.open(r.central.identifier, v) {
                delegate?.transportDidReceive(data: clear, peerId: r.central.identifier)
            }
        }
        pm.respond(to: first, withResult: .success)
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
