import SwiftUI
import CoreBluetooth
import ImpossiBLE

@main
struct SampleApp: App {
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ScanView()
            }
        }
    }
}

// MARK: - BLE Manager

final class BLEManager: NSObject, ObservableObject {
    @Published var state: CBManagerState = .unknown
    @Published var discovered: [DiscoveredPeripheral] = []
    @Published var connectedPeripheral: CBPeripheral?
    @Published var services: [CBService] = []
    @Published var characteristicValues: [ObjectIdentifier: Data] = [:]
    @Published var descriptorValues: [ObjectIdentifier: Any] = [:]
    @Published var log: [LogEntry] = []
    @Published var isScanning = false

    private var central: CBCentralManager!
    private var peripheralMap: [UUID: CBPeripheral] = [:]

    struct DiscoveredPeripheral: Identifiable {
        let id: UUID
        let peripheral: CBPeripheral
        var name: String
        var rssi: Int
        var advertisementData: [String: Any]
    }

    struct LogEntry: Identifiable {
        let id = UUID()
        let timestamp = Date()
        let message: String
    }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func startScan() {
        guard state == .poweredOn else { return }
        discovered.removeAll()
        peripheralMap.removeAll()
        central.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false,
        ])
        isScanning = true
        appendLog("Scanning started")
    }

    func stopScan() {
        central.stopScan()
        isScanning = false
        appendLog("Scanning stopped")
    }

    func connect(_ peripheral: CBPeripheral) {
        stopScan()
        peripheral.delegate = self
        central.connect(peripheral)
        appendLog("Connecting to \(peripheral.name ?? peripheral.identifier.uuidString)\u{2026}")
    }

    func disconnect() {
        guard let p = connectedPeripheral else { return }
        central.cancelPeripheralConnection(p)
        appendLog("Disconnecting\u{2026}")
    }

    func discoverServices() {
        guard let p = connectedPeripheral else { return }
        p.discoverServices(nil)
        appendLog("Discovering services\u{2026}")
    }

    func discoverCharacteristics(for service: CBService) {
        guard let p = connectedPeripheral else { return }
        p.discoverCharacteristics(nil, for: service)
        appendLog("Discovering characteristics for \(service.uuid.uuidString)\u{2026}")
    }

    func discoverDescriptors(for characteristic: CBCharacteristic) {
        guard let p = connectedPeripheral else { return }
        p.discoverDescriptors(for: characteristic)
        appendLog("Discovering descriptors for \(characteristic.uuid.uuidString)\u{2026}")
    }

    func readValue(for characteristic: CBCharacteristic) {
        guard let p = connectedPeripheral else { return }
        p.readValue(for: characteristic)
        appendLog("Reading \(characteristic.uuid.uuidString)\u{2026}")
    }

    func writeValue(_ data: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType) {
        guard let p = connectedPeripheral else { return }
        p.writeValue(data, for: characteristic, type: type)
        appendLog("Writing \(data.count) bytes to \(characteristic.uuid.uuidString)")
    }

    func setNotify(_ enabled: Bool, for characteristic: CBCharacteristic) {
        guard let p = connectedPeripheral else { return }
        p.setNotifyValue(enabled, for: characteristic)
        appendLog("\(enabled ? "Subscribing to" : "Unsubscribing from") \(characteristic.uuid.uuidString)")
    }

    func readValue(for descriptor: CBDescriptor) {
        guard let p = connectedPeripheral else { return }
        p.readValue(for: descriptor)
        appendLog("Reading descriptor \(descriptor.uuid.uuidString)\u{2026}")
    }

    func readRSSI() {
        connectedPeripheral?.readRSSI()
        appendLog("Reading RSSI\u{2026}")
    }

    func cachedValue(for characteristic: CBCharacteristic) -> Data? {
        characteristicValues[ObjectIdentifier(characteristic)] ?? characteristic.value
    }

    func cachedValue(for descriptor: CBDescriptor) -> Any? {
        descriptorValues[ObjectIdentifier(descriptor)] ?? descriptor.value
    }

    func clearLog() {
        log.removeAll()
    }

    private func appendLog(_ message: String) {
        DispatchQueue.main.async {
            self.log.insert(LogEntry(message: message), at: 0)
            if self.log.count > 200 {
                self.log.removeLast(self.log.count - 200)
            }
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        state = central.state
        appendLog("State: \(central.state.name)")
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let id = peripheral.identifier
        peripheralMap[id] = peripheral
        if let idx = discovered.firstIndex(where: { $0.id == id }) {
            discovered[idx].rssi = RSSI.intValue
            discovered[idx].name = peripheral.name ?? "Unknown"
        } else {
            discovered.append(DiscoveredPeripheral(
                id: id, peripheral: peripheral,
                name: peripheral.name ?? "Unknown",
                rssi: RSSI.intValue,
                advertisementData: advertisementData
            ))
        }
        appendLog("Discovered: \(peripheral.name ?? "?") RSSI=\(RSSI)")
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectedPeripheral = peripheral
        services = []
        characteristicValues = [:]
        descriptorValues = [:]
        appendLog("Connected to \(peripheral.name ?? peripheral.identifier.uuidString)")
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        appendLog("Failed to connect: \(error?.localizedDescription ?? "unknown")")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if connectedPeripheral?.identifier == peripheral.identifier {
            connectedPeripheral = nil
            services = []
        }
        appendLog("Disconnected\(error.map { ": \($0.localizedDescription)" } ?? "")")
    }
}

// MARK: - CBPeripheralDelegate

extension BLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            appendLog("Service discovery error: \(error.localizedDescription)")
            return
        }
        services = peripheral.services ?? []
        appendLog("Found \(services.count) service(s)")
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            appendLog("Characteristic discovery error: \(error.localizedDescription)")
            return
        }
        let chars = service.characteristics ?? []
        appendLog("Found \(chars.count) characteristic(s) in \(service.uuid.uuidString)")
        objectWillChange.send()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverDescriptorsFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            appendLog("Descriptor discovery error: \(error.localizedDescription)")
            return
        }
        let descs = characteristic.descriptors ?? []
        appendLog("Found \(descs.count) descriptor(s) for \(characteristic.uuid.uuidString)")
        objectWillChange.send()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            appendLog("Read error for \(characteristic.uuid.uuidString): \(error.localizedDescription)")
            return
        }
        if let v = characteristic.value {
            characteristicValues[ObjectIdentifier(characteristic)] = v
            let hex = v.map { String(format: "%02X", $0) }.joined()
            let utf8 = String(data: v, encoding: .utf8)
            appendLog("Value[\(characteristic.uuid.uuidString)] = \(hex)\(utf8.map { " (\($0))" } ?? "")")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            appendLog("Write error: \(error.localizedDescription)")
        } else {
            appendLog("Write confirmed for \(characteristic.uuid.uuidString)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            appendLog("Notify error: \(error.localizedDescription)")
        } else {
            appendLog("Notify \(characteristic.isNotifying ? "enabled" : "disabled") for \(characteristic.uuid.uuidString)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor descriptor: CBDescriptor, error: Error?) {
        if let error {
            appendLog("Descriptor read error: \(error.localizedDescription)")
            return
        }
        descriptorValues[ObjectIdentifier(descriptor)] = descriptor.value
        let key = "\(descriptor.characteristic?.uuid.uuidString ?? "?"):\(descriptor.uuid.uuidString)"
        appendLog("Descriptor[\(key)] = \(descriptor.value ?? "nil")")
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        if let error {
            appendLog("RSSI error: \(error.localizedDescription)")
        } else {
            appendLog("RSSI = \(RSSI) dBm")
        }
    }
}

extension CBManagerState {
    var name: String {
        switch self {
            case .unknown:      "Unknown"
            case .resetting:    "Resetting"
            case .unsupported:  "Unsupported"
            case .unauthorized: "Unauthorized"
            case .poweredOff:   "Powered Off"
            case .poweredOn:    "Powered On"
            @unknown default:   "State(\(rawValue))"
        }
    }
}

// MARK: - Scan View

struct ScanView: View {
    @StateObject private var ble = BLEManager()

    var body: some View {
        List {
            Section {
                HStack {
                    Circle()
                        .fill(ble.state == .poweredOn ? .green : .red)
                        .frame(width: 8, height: 8)
                    Text("Bluetooth: \(ble.state.name)")
                    Spacer()
                    if ble.isScanning {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }

            if let connected = ble.connectedPeripheral {
                Section("Connected") {
                    NavigationLink {
                        PeripheralDetailView(ble: ble)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(connected.name ?? connected.identifier.uuidString)
                                .font(.headline)
                            Text(connected.identifier.uuidString)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button("Disconnect", role: .destructive) {
                        ble.disconnect()
                    }
                }
            }

            Section("Discovered (\(ble.discovered.count))") {
                if ble.discovered.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: ble.isScanning ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text(ble.isScanning ? "Scanning" : "No Peripherals")
                            .font(.subheadline.weight(.medium))
                        Text(ble.isScanning ? "Nearby peripherals will appear here." : "Start a scan after the mock server is listening.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                } else {
                    ForEach(ble.discovered) { device in
                        Button {
                            ble.connect(device.peripheral)
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(device.name)
                                        .font(.subheadline.weight(.medium))
                                    Text(device.id.uuidString)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(device.rssi) dBm")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tint(.primary)
                    }
                }
            }

            Section("Log") {
                ForEach(ble.log) { entry in
                    HStack(alignment: .top, spacing: 6) {
                        Text(entry.timestamp, format: .dateTime.hour().minute().second().secondFraction(.fractional(2)))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                        Text(entry.message)
                            .font(.caption)
                    }
                }
            }
        }
        .navigationTitle("ImpossiBLE Sample")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(ble.isScanning ? "Stop" : "Scan") {
                    ble.isScanning ? ble.stopScan() : ble.startScan()
                }
                .disabled(ble.state != .poweredOn)
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("Clear Log") {
                    ble.clearLog()
                }
                .disabled(ble.log.isEmpty)
            }
        }
    }
}

// MARK: - Peripheral Detail

struct PeripheralDetailView: View {
    @ObservedObject var ble: BLEManager

    var body: some View {
        List {
            Section {
                Button("Discover Services") { ble.discoverServices() }
                Button("Read RSSI") { ble.readRSSI() }
            }

            ForEach(ble.services, id: \.uuid) { service in
                Section {
                    serviceHeader(service)

                    if let chars = service.characteristics, !chars.isEmpty {
                        ForEach(chars, id: \.uuid) { ch in
                            NavigationLink {
                                CharacteristicDetailView(ble: ble, characteristic: ch)
                            } label: {
                                characteristicRow(ch)
                            }
                        }
                    } else {
                        Button("Discover Characteristics") {
                            ble.discoverCharacteristics(for: service)
                        }
                        .font(.caption)
                    }
                }
            }

            Section("Log") {
                ForEach(ble.log.prefix(50)) { entry in
                    HStack(alignment: .top, spacing: 6) {
                        Text(entry.timestamp, format: .dateTime.hour().minute().second().secondFraction(.fractional(2)))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                        Text(entry.message)
                            .font(.caption)
                    }
                }
            }
        }
        .navigationTitle(ble.connectedPeripheral?.name ?? "Peripheral")
    }

    @ViewBuilder
    private func serviceHeader(_ service: CBService) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(service.uuid.uuidString)
                .font(.subheadline.monospaced().bold())
            HStack {
                Text(service.isPrimary ? "Primary" : "Secondary")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(service.characteristics?.count ?? 0) characteristics")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func characteristicRow(_ ch: CBCharacteristic) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(ch.uuid.uuidString)
                .font(.caption.monospaced())
            Text(propertiesString(ch.properties))
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let data = ble.cachedValue(for: ch) {
                Text(data.map { String(format: "%02X", $0) }.joined(separator: " "))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.blue)
            }
        }
    }
}

// MARK: - Characteristic Detail

struct CharacteristicDetailView: View {
    @ObservedObject var ble: BLEManager
    let characteristic: CBCharacteristic
    @State private var writeHex = ""

    var body: some View {
        List {
            Section("Properties") {
                Text(propertiesString(characteristic.properties))
                    .font(.caption.monospaced())
            }

            Section("Actions") {
                if characteristic.properties.contains(.read) {
                    Button("Read Value") {
                        ble.readValue(for: characteristic)
                    }
                }
                if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                    Button(characteristic.isNotifying ? "Unsubscribe" : "Subscribe") {
                        ble.setNotify(!characteristic.isNotifying, for: characteristic)
                    }
                }
                Button("Discover Descriptors") {
                    ble.discoverDescriptors(for: characteristic)
                }
            }

            if characteristic.properties.contains(.write) || characteristic.properties.contains(.writeWithoutResponse) {
                Section("Write") {
                    TextField("Hex value (e.g. 48656C6C6F)", text: $writeHex)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    if characteristic.properties.contains(.write) {
                        Button("Write with Response") {
                            guard let data = hexToData(writeHex) else { return }
                            ble.writeValue(data, for: characteristic, type: .withResponse)
                        }
                        .disabled(!isWriteHexValid)
                    }
                    if characteristic.properties.contains(.writeWithoutResponse) {
                        Button("Write without Response") {
                            guard let data = hexToData(writeHex) else { return }
                            ble.writeValue(data, for: characteristic, type: .withoutResponse)
                        }
                        .disabled(!isWriteHexValid)
                    }

                    if !isWriteHexValid {
                        Text("Enter an even number of hex digits.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }

            if let value = ble.cachedValue(for: characteristic) {
                Section("Current Value") {
                    Text(value.map { String(format: "%02X", $0) }.joined(separator: " "))
                        .font(.system(.body, design: .monospaced))
                    if let str = String(data: value, encoding: .utf8) {
                        Text("UTF-8: \(str)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("\(value.count) bytes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let descriptors = characteristic.descriptors, !descriptors.isEmpty {
                Section("Descriptors") {
                    ForEach(descriptors, id: \.uuid) { desc in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(desc.uuid.uuidString)
                                .font(.caption.monospaced())
                            Button("Read") {
                                ble.readValue(for: desc)
                            }
                            .font(.caption)
                            if let val = ble.cachedValue(for: desc) {
                                Text("Value: \(String(describing: val))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section("Log") {
                ForEach(ble.log.prefix(30)) { entry in
                    HStack(alignment: .top, spacing: 6) {
                        Text(entry.timestamp, format: .dateTime.hour().minute().second().secondFraction(.fractional(2)))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                        Text(entry.message)
                            .font(.caption)
                    }
                }
            }
        }
        .navigationTitle(characteristic.uuid.uuidString)
    }

    private var isWriteHexValid: Bool {
        hexToData(writeHex) != nil
    }
}

// MARK: - Helpers

func propertiesString(_ props: CBCharacteristicProperties) -> String {
    var parts: [String] = []
    if props.contains(.broadcast)              { parts.append("Broadcast") }
    if props.contains(.read)                   { parts.append("Read") }
    if props.contains(.writeWithoutResponse)   { parts.append("WriteNoResp") }
    if props.contains(.write)                  { parts.append("Write") }
    if props.contains(.notify)                 { parts.append("Notify") }
    if props.contains(.indicate)               { parts.append("Indicate") }
    if props.contains(.authenticatedSignedWrites) { parts.append("SignedWrite") }
    if props.contains(.extendedProperties)     { parts.append("ExtProps") }
    return parts.isEmpty ? "None" : parts.joined(separator: ", ")
}

func hexToData(_ hex: String) -> Data? {
    let clean = hex.filter { $0.isHexDigit }
    guard clean.count % 2 == 0 else { return nil }
    var data = Data()
    var i = clean.startIndex
    while i < clean.endIndex {
        let next = clean.index(i, offsetBy: 2)
        guard let byte = UInt8(clean[i..<next], radix: 16) else { return nil }
        data.append(byte)
        i = next
    }
    return data
}
