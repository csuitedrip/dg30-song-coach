import Foundation
import CoreBluetooth
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Bluetooth MIDI (BLE-MIDI) for pianos like the Kawai DG30, done directly with CoreBluetooth.
/// (Apple's ready-made pairing screen, CABTMIDICentralViewController, crashes on iOS 27.)
final class BluetoothMIDI: NSObject {

    static let midiService = CBUUID(string: "03B80E5A-EDE8-4B33-A751-6CE34EC4C700")
    static let midiCharacteristic = CBUUID(string: "7772E5DB-3868-4112-A1A9-F2669D106BF3")

    /// Called with (state, name, id) — the same states the page's window.__scBle understands.
    var onStatus: ((String, String, String) -> Void)?
    /// MIDI bytes from the piano (status + data, timestamps removed).
    var onMIDI: ((String, [UInt8]) -> Void)?
    /// The list of connected Bluetooth pianos changed.
    var onDevicesChanged: (() -> Void)?
    /// Ask the UI to let the person pick one of several pianos.
    var choose: (([(name: String, id: UUID)], @escaping (UUID?) -> Void) -> Void)?

    private var central: CBCentralManager?
    private var pendingAction: (() -> Void)?
    private var found: [UUID: CBPeripheral] = [:]
    private var scanning = false
    private var filter = ""
    private var connected: [UUID: (peripheral: CBPeripheral, characteristic: CBCharacteristic?)] = [:]
    private var quietAttempt: UUID?

    struct Device { let id: String; let name: String }

    var devices: [Device] {
        connected.values.compactMap { entry in
            guard entry.characteristic != nil else { return nil }
            return Device(id: "ble-" + entry.peripheral.identifier.uuidString, name: entry.peripheral.name ?? "Bluetooth piano")
        }
    }

    private func withCentral(_ action: @escaping () -> Void) {
        if central == nil {
            pendingAction = action
            central = CBCentralManager(delegate: self, queue: .main)
            return
        }
        guard let c = central else { return }
        switch c.state {
        case .poweredOn: action()
        case .unknown, .resetting: pendingAction = action
        case .poweredOff: onStatus?("bt-off", "", "")
        case .unauthorized: onStatus?("denied", "", "")
        default: onStatus?("unsupported", "", "")
        }
    }

    // MARK: Find my piano

    func find(filter: String, showAll: Bool) {
        withCentral { [weak self] in self?.startScan(filter: filter, showAll: showAll) }
    }

    private func startScan(filter: String, showAll: Bool) {
        guard let c = central, !scanning else { return }
        self.filter = filter.lowercased()
        found = [:]
        scanning = true
        // Pianos already connected to this phone for MIDI don't advertise, so include those too.
        for p in c.retrieveConnectedPeripherals(withServices: [Self.midiService]) { found[p.identifier] = p }
        c.scanForPeripherals(withServices: showAll ? nil : [Self.midiService], options: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.finishScan() }
    }

    private func matches(_ p: CBPeripheral) -> Bool {
        guard !filter.isEmpty else { return true }
        return (p.name ?? "").lowercased().contains(filter)
    }

    private func finishScan() {
        guard scanning else { return }
        scanning = false
        central?.stopScan()
        let list = found.values.filter(matches).map { (name: $0.name ?? "Unnamed device", id: $0.identifier) }
            .sorted { $0.name < $1.name }
        if list.isEmpty { onStatus?("none", "", ""); return }
        if list.count == 1 { connect(list[0].id, quiet: false); return }
        choose?(list) { [weak self] picked in
            if let picked { self?.connect(picked, quiet: false) } else { self?.onStatus?("quiet-fail", "", "") }
        }
    }

    // MARK: Connect / reconnect

    /// The page asks to reconnect to the piano used last time ("ble-<uuid>").
    func reconnect(id: String) {
        guard id.hasPrefix("ble-"), let uuid = UUID(uuidString: String(id.dropFirst(4))) else {
            onStatus?("quiet-fail", "", ""); return
        }
        if let entry = connected[uuid], entry.characteristic != nil {
            onStatus?("connected", entry.peripheral.name ?? "Bluetooth piano", id); return
        }
        withCentral { [weak self] in self?.connect(uuid, quiet: true) }
    }

    private func connect(_ uuid: UUID, quiet: Bool) {
        guard let c = central else { return }
        guard let p = found[uuid] ?? c.retrievePeripherals(withIdentifiers: [uuid]).first else {
            onStatus?(quiet ? "quiet-fail" : "failed", "", ""); return
        }
        if quiet { quietAttempt = uuid } else { onStatus?("connecting", p.name ?? "", "") }
        p.delegate = self
        connected[uuid] = (p, nil)
        c.connect(p, options: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self, let entry = self.connected[uuid], entry.characteristic == nil else { return }
            c.cancelPeripheralConnection(p)
            self.connected[uuid] = nil
            self.onStatus?(self.quietAttempt == uuid ? "quiet-fail" : "failed", p.name ?? "", "")
            if self.quietAttempt == uuid { self.quietAttempt = nil }
        }
    }

    // MARK: Sending MIDI to the piano

    func send(id: String, bytes: [UInt8]) {
        guard id.hasPrefix("ble-"), let uuid = UUID(uuidString: String(id.dropFirst(4))),
              let entry = connected[uuid], let ch = entry.characteristic, !bytes.isEmpty else { return }
        let ms = UInt16(truncatingIfNeeded: Int(Date().timeIntervalSince1970 * 1000)) & 0x1FFF
        var packet: [UInt8] = [0x80 | UInt8((ms >> 7) & 0x3F), 0x80 | UInt8(ms & 0x7F)]
        packet.append(contentsOf: bytes)
        let type: CBCharacteristicWriteType = ch.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        entry.peripheral.writeValue(Data(packet), for: ch, type: type)
    }

    // MARK: BLE-MIDI packet → plain MIDI bytes

    private var runningStatus: UInt8 = 0
    private var inSysEx = false

    private func parse(_ data: Data) -> [UInt8] {
        let b = [UInt8](data)
        guard b.count > 1, b[0] & 0x80 != 0 else { return [] }
        var out: [UInt8] = []
        var i = 1
        func dataLength(_ s: UInt8) -> Int {
            switch s & 0xF0 {
            case 0xC0, 0xD0: return 1
            case 0xF0: return s == 0xF2 ? 2 : (s == 0xF1 || s == 0xF3) ? 1 : 0
            default: return 2
            }
        }
        while i < b.count {
            if inSysEx {
                // SysEx continues until 0xF7 (which follows its own timestamp byte)
                if b[i] & 0x80 == 0 { i += 1; continue }
                if i + 1 < b.count, b[i + 1] == 0xF7 { inSysEx = false; i += 2; continue }
                inSysEx = false
            }
            // a byte with the top bit set at a message boundary is a timestamp
            if b[i] & 0x80 != 0 { i += 1; if i >= b.count { break } }
            // then either a status byte, or data bytes reusing the last status ("running status")
            if b[i] & 0x80 != 0 {
                let s = b[i]; i += 1
                if s == 0xF0 { inSysEx = true; continue }
                if s == 0xF7 { continue }
                if s >= 0xF8 { out.append(s); continue } // real-time
                runningStatus = s
            }
            guard runningStatus != 0 else { i += 1; continue }
            let n = dataLength(runningStatus)
            guard i + n <= b.count else { break }
            let payload = Array(b[i..<(i + n)])
            if payload.allSatisfy({ $0 < 0x80 }) {
                out.append(runningStatus); out.append(contentsOf: payload)
            }
            i += n
        }
        return out
    }
}

extension BluetoothMIDI: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn:
            let action = pendingAction; pendingAction = nil; action?()
        case .poweredOff:
            if pendingAction != nil { pendingAction = nil; onStatus?("bt-off", "", "") }
            connected = [:]; onDevicesChanged?()
        case .unauthorized:
            pendingAction = nil; onStatus?("denied", "", "")
        case .unsupported:
            pendingAction = nil; onStatus?("unsupported", "", "")
        default: break
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        found[p.identifier] = p
        // Typed a name and it matches: connect right away
        if !filter.isEmpty, matches(p), scanning {
            scanning = false; c.stopScan(); connect(p.identifier, quiet: false)
        }
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        p.discoverServices([Self.midiService])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        connected[p.identifier] = nil
        let quiet = quietAttempt == p.identifier; quietAttempt = nil
        onStatus?(quiet ? "quiet-fail" : "failed", p.name ?? "", "")
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        connected[p.identifier] = nil
        onDevicesChanged?()
    }
}

extension BluetoothMIDI: CBPeripheralDelegate {
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svc = p.services?.first(where: { $0.uuid == Self.midiService }) else {
            central?.cancelPeripheralConnection(p)
            connected[p.identifier] = nil
            onStatus?("failed", p.name ?? "", ""); return
        }
        p.discoverCharacteristics([Self.midiCharacteristic], for: svc)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let ch = service.characteristics?.first(where: { $0.uuid == Self.midiCharacteristic }) else {
            central?.cancelPeripheralConnection(p)
            connected[p.identifier] = nil
            onStatus?("failed", p.name ?? "", ""); return
        }
        p.setNotifyValue(true, for: ch)
        connected[p.identifier] = (p, ch)
        if quietAttempt == p.identifier { quietAttempt = nil }
        onDevicesChanged?()
        onStatus?("connected", p.name ?? "Bluetooth piano", "ble-" + p.identifier.uuidString)
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let data = ch.value else { return }
        let bytes = parse(data)
        if !bytes.isEmpty { onMIDI?("ble-" + p.identifier.uuidString, bytes) }
    }
}
