import SwiftUI
import CoreBluetooth
import ImpossiBLE

@main
struct SampleApp: App {
    var body: some Scene {
        WindowGroup {
            ScanView()
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
    @Published var secondaryState: CBManagerState = .unknown
    @Published var secondaryDiscovered: [DiscoveredPeripheral] = []
    @Published var secondaryIsScanning = false
    @Published var retrievedPeripherals: [CBPeripheral] = []
    @Published var retrievedConnectedPeripherals: [CBPeripheral] = []
    @Published var l2capStatus = "No channel"
    @Published var l2capReceived: [Data] = []

    private var central: CBCentralManager!
    private var secondaryCentral: CBCentralManager?
    private var peripheralMap: [UUID: CBPeripheral] = [:]
    private var secondaryPeripheralMap: [UUID: CBPeripheral] = [:]
    private var l2capChannel: CBL2CAPChannel?

    struct DiscoveredPeripheral: Identifiable {
        let id: UUID
        let peripheral: CBPeripheral
        var name: String
        var rssi: Int
        var advertisementData: [String: Any]

        var hasDisplayName: Bool {
            if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name != "Unknown" {
                return true
            }
            if let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String {
                return !localName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return false
        }

        var isConnectable: Bool {
            if let connectable = advertisementData[CBAdvertisementDataIsConnectable] as? Bool {
                return connectable
            }
            if let connectable = advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber {
                return connectable.boolValue
            }
            return false
        }
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

    func startScan(serviceUUIDs: [CBUUID]? = nil, allowDuplicates: Bool = false) {
        guard state == .poweredOn else { return }
        discovered.removeAll()
        peripheralMap.removeAll()
        let options = [
            CBCentralManagerScanOptionAllowDuplicatesKey: allowDuplicates,
        ]
        central.scanForPeripherals(withServices: serviceUUIDs, options: options)
        isScanning = true
        let filter = serviceUUIDs?.map(\.uuidString).joined(separator: ", ") ?? "Any"
        appendLog("Scanning started (services: \(filter), duplicates: \(allowDuplicates ? "on" : "off"))")
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
        closeL2CAPChannel()
        central.cancelPeripheralConnection(p)
        appendLog("Disconnecting\u{2026}")
    }

    func discoverServices() {
        guard let p = connectedPeripheral else { return }
        p.discoverServices(nil)
        appendLog("Discovering services\u{2026}")
    }

    func discoverServices(_ services: [CBUUID]) {
        guard let p = connectedPeripheral else { return }
        p.discoverServices(services)
        appendLog("Discovering filtered services: \(services.map(\.uuidString).joined(separator: ", "))\u{2026}")
    }

    func discoverIncludedServices(for service: CBService) {
        guard let p = connectedPeripheral else { return }
        p.discoverIncludedServices(nil, for: service)
        appendLog("Discovering included services for \(service.uuid.uuidString)\u{2026}")
    }

    func discoverCharacteristics(for service: CBService) {
        guard let p = connectedPeripheral else { return }
        p.discoverCharacteristics(nil, for: service)
        appendLog("Discovering characteristics for \(service.uuid.uuidString)\u{2026}")
    }

    func discoverCharacteristics(_ characteristics: [CBUUID], for service: CBService) {
        guard let p = connectedPeripheral else { return }
        p.discoverCharacteristics(characteristics, for: service)
        appendLog("Discovering filtered characteristics for \(service.uuid.uuidString): \(characteristics.map(\.uuidString).joined(separator: ", "))\u{2026}")
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

    func writeValue(_ data: Data, for descriptor: CBDescriptor) {
        guard let p = connectedPeripheral else { return }
        p.writeValue(data, for: descriptor)
        appendLog("Writing \(data.count) bytes to descriptor \(descriptor.uuid.uuidString)")
    }

    func readRSSI() {
        connectedPeripheral?.readRSSI()
        appendLog("Reading RSSI\u{2026}")
    }

    func registerForConnectionEvents() {
        central.registerForConnectionEvents(options: nil)
        appendLog("Registered for connection events")
    }

    func retrieveDiscoveredPeripherals() {
        let identifiers = discovered.map(\.id)
        retrievedPeripherals = central.retrievePeripherals(withIdentifiers: identifiers)
        appendLog("retrievePeripherals returned \(retrievedPeripherals.count) peripheral(s)")
    }

    func retrieveConnectedPeripherals(services: [CBUUID]) {
        guard !services.isEmpty else {
            retrievedConnectedPeripherals = []
            appendLog("retrieveConnectedPeripherals needs at least one service UUID")
            return
        }
        retrievedConnectedPeripherals = central.retrieveConnectedPeripherals(withServices: services)
        appendLog("retrieveConnectedPeripherals returned \(retrievedConnectedPeripherals.count) peripheral(s)")
    }

    func startSecondaryScan(serviceUUIDs: [CBUUID]? = nil) {
        if secondaryCentral == nil {
            secondaryCentral = CBCentralManager(delegate: self, queue: nil)
        }
        guard secondaryCentral?.state == .poweredOn else {
            appendLog("Secondary central waiting for poweredOn")
            return
        }
        secondaryDiscovered.removeAll()
        secondaryPeripheralMap.removeAll()
        secondaryCentral?.scanForPeripherals(withServices: serviceUUIDs, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false,
        ])
        secondaryIsScanning = true
        let filter = serviceUUIDs?.map(\.uuidString).joined(separator: ", ") ?? "Any"
        appendLog("Secondary scan started (services: \(filter))")
    }

    func stopSecondaryScan() {
        secondaryCentral?.stopScan()
        secondaryIsScanning = false
        appendLog("Secondary scan stopped")
    }

    func openL2CAPChannel(psm: CBL2CAPPSM) {
        guard let p = connectedPeripheral else { return }
        closeL2CAPChannel()
        l2capStatus = "Opening PSM \(psm)\u{2026}"
        l2capReceived = []
        p.openL2CAPChannel(psm)
        appendLog("Opening L2CAP channel PSM \(psm)\u{2026}")
    }

    func writeL2CAP(_ data: Data) {
        guard let stream = l2capChannel?.outputStream else {
            appendLog("No L2CAP output stream")
            return
        }
        let written = data.withUnsafeBytes { ptr -> Int in
            guard let base = ptr.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return stream.write(base, maxLength: data.count)
        }
        appendLog("L2CAP wrote \(written) of \(data.count) bytes")
    }

    func closeL2CAPChannel() {
        guard let channel = l2capChannel else { return }
        channel.inputStream.delegate = nil
        channel.outputStream.delegate = nil
        channel.inputStream.close()
        channel.outputStream.close()
        l2capChannel = nil
        l2capStatus = "Closed"
        appendLog("L2CAP channel closed")
    }

    var canSendWriteWithoutResponse: Bool {
        connectedPeripheral?.canSendWriteWithoutResponse ?? false
    }

    func maximumWriteValueLength(for type: CBCharacteristicWriteType) -> Int {
        connectedPeripheral?.maximumWriteValueLength(for: type) ?? 0
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
        if central === secondaryCentral {
            secondaryState = central.state
            appendLog("Secondary state: \(central.state.name)")
            if central.state != .poweredOn {
                secondaryIsScanning = false
                secondaryDiscovered.removeAll()
                secondaryPeripheralMap.removeAll()
            }
            return
        }

        state = central.state
        appendLog("State: \(central.state.name); authorization: \(CBManager.authorization.name)")
        if central.state == .poweredOn {
            startScan()
        } else {
            isScanning = false
            connectedPeripheral = nil
            services = []
            discovered.removeAll()
            peripheralMap.removeAll()
            retrievedPeripherals = []
            retrievedConnectedPeripherals = []
            closeL2CAPChannel()
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        if central === secondaryCentral {
            let id = peripheral.identifier
            secondaryPeripheralMap[id] = peripheral
            if let idx = secondaryDiscovered.firstIndex(where: { $0.id == id }) {
                secondaryDiscovered[idx].rssi = RSSI.intValue
                secondaryDiscovered[idx].name = peripheral.name ?? "Unknown"
                secondaryDiscovered[idx].advertisementData = advertisementData
            } else {
                secondaryDiscovered.append(DiscoveredPeripheral(
                    id: id, peripheral: peripheral,
                    name: peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "Unknown",
                    rssi: RSSI.intValue,
                    advertisementData: advertisementData
                ))
            }
            appendLog("Secondary discovered: \(peripheral.name ?? "?") RSSI=\(RSSI)")
            return
        }

        let id = peripheral.identifier
        peripheralMap[id] = peripheral
        if let idx = discovered.firstIndex(where: { $0.id == id }) {
            discovered[idx].rssi = RSSI.intValue
            discovered[idx].name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "Unknown"
            discovered[idx].advertisementData = advertisementData
        } else {
            discovered.append(DiscoveredPeripheral(
                id: id, peripheral: peripheral,
                name: peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "Unknown",
                rssi: RSSI.intValue,
                advertisementData: advertisementData
            ))
        }
        appendLog("Discovered: \(peripheral.name ?? "?") RSSI=\(RSSI), adv=\(advertisementSummary(advertisementData))")
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectedPeripheral = peripheral
        services = []
        characteristicValues = [:]
        descriptorValues = [:]
        retrievedConnectedPeripherals = []
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

    func centralManager(_ central: CBCentralManager, connectionEventDidOccur event: CBConnectionEvent, for peripheral: CBPeripheral) {
        appendLog("Connection event: \(event.name) for \(peripheral.name ?? peripheral.identifier.uuidString)")
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

    func peripheral(_ peripheral: CBPeripheral, didDiscoverIncludedServicesFor service: CBService, error: Error?) {
        if let error {
            appendLog("Included service discovery error: \(error.localizedDescription)")
            return
        }
        let included = service.includedServices ?? []
        appendLog("Found \(included.count) included service(s) in \(service.uuid.uuidString)")
        objectWillChange.send()
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
        appendLog("Descriptor[\(key)] = \(valueSummary(descriptor.value))")
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor descriptor: CBDescriptor, error: Error?) {
        if let error {
            appendLog("Descriptor write error: \(error.localizedDescription)")
        } else {
            appendLog("Descriptor write confirmed for \(descriptor.uuid.uuidString)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        if let error {
            appendLog("RSSI error: \(error.localizedDescription)")
        } else {
            appendLog("RSSI = \(RSSI) dBm")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        if let error {
            l2capChannel = nil
            l2capStatus = "Open failed: \(error.localizedDescription)"
            appendLog("L2CAP open error: \(error.localizedDescription)")
            return
        }
        guard let channel else {
            l2capChannel = nil
            l2capStatus = "Open failed: no channel"
            appendLog("L2CAP open callback without channel")
            return
        }
        l2capChannel = channel
        channel.inputStream.delegate = self
        channel.outputStream.delegate = self
        channel.inputStream.schedule(in: .main, forMode: .default)
        channel.outputStream.schedule(in: .main, forMode: .default)
        l2capStatus = "Open PSM \(channel.psm)"
        appendLog("L2CAP open PSM \(channel.psm)")
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        appendLog("Modified services: \(invalidatedServices.map(\.uuid.uuidString).joined(separator: ", "))")
        services.removeAll { service in
            invalidatedServices.contains { $0.uuid == service.uuid }
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        appendLog("Peripheral ready for write without response")
        objectWillChange.send()
    }
}

// MARK: - StreamDelegate

extension BLEManager: StreamDelegate {
    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        if eventCode.contains(.hasBytesAvailable), let input = aStream as? InputStream {
            var buffer = [UInt8](repeating: 0, count: 1024)
            let count = input.read(&buffer, maxLength: buffer.count)
            if count > 0 {
                let data = Data(buffer.prefix(count))
                l2capReceived.insert(data, at: 0)
                appendLog("L2CAP received \(count) bytes: \(dataSummary(data))")
            }
        }

        if eventCode.contains(.hasSpaceAvailable) {
            appendLog("L2CAP output stream ready")
        }

        if eventCode.contains(.errorOccurred) {
            l2capStatus = "Stream error"
            appendLog("L2CAP stream error: \(aStream.streamError?.localizedDescription ?? "unknown")")
        }

        if eventCode.contains(.endEncountered) {
            l2capStatus = "Stream ended"
            appendLog("L2CAP stream ended")
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
    @State private var path = NavigationPath()
    @State private var isLogPresented = false
    @State private var scanFilter = ""
    @State private var retrieveConnectedFilter = "180D 180F 180A"
    @State private var allowDuplicates = false

    var body: some View {
        NavigationStack(path: $path) {
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

                Section("Scan") {
                    TextField("Service filter, e.g. 180D 180F", text: $scanFilter)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Toggle("Allow duplicate advertisements", isOn: $allowDuplicates)
                    HStack {
                        Button(ble.isScanning ? "Stop Primary" : "Start Primary") {
                            if ble.isScanning {
                                ble.stopScan()
                            } else {
                                ble.startScan(serviceUUIDs: cbUUIDs(from: scanFilter), allowDuplicates: allowDuplicates)
                            }
                        }
                        .disabled(ble.state != .poweredOn)

                        Button(ble.secondaryIsScanning ? "Stop Secondary" : "Start Secondary") {
                            if ble.secondaryIsScanning {
                                ble.stopSecondaryScan()
                            } else {
                                ble.startSecondaryScan(serviceUUIDs: cbUUIDs(from: scanFilter))
                            }
                        }
                        .disabled(ble.secondaryState != .poweredOn && ble.secondaryIsScanning)
                    }
                    Text("Secondary central: \(ble.secondaryState.name), \(ble.secondaryDiscovered.count) discovered")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Central APIs") {
                    Button("Register for Connection Events") {
                        ble.registerForConnectionEvents()
                    }
                    .disabled(ble.state != .poweredOn)

                    Button("Retrieve Discovered Peripherals") {
                        ble.retrieveDiscoveredPeripherals()
                    }
                    .disabled(ble.discovered.isEmpty)

                    TextField("Connected service UUIDs", text: $retrieveConnectedFilter)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    Button("Retrieve Connected Peripherals") {
                        ble.retrieveConnectedPeripherals(services: cbUUIDs(from: retrieveConnectedFilter) ?? [])
                    }
                    .disabled(ble.state != .poweredOn || (cbUUIDs(from: retrieveConnectedFilter) ?? []).isEmpty)

                    if !ble.retrievedPeripherals.isEmpty || !ble.retrievedConnectedPeripherals.isEmpty {
                        RetrievedPeripheralsView(
                            retrieved: ble.retrievedPeripherals,
                            connected: ble.retrievedConnectedPeripherals
                        )
                    }
                }

                if let connected = ble.connectedPeripheral {
                    Section("Connected") {
                        NavigationLink {
                            PeripheralDetailView(ble: ble, isLogPresented: $isLogPresented)
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
                        ForEach(sortedDiscoveredDevices) { device in
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
                                        Text(advertisementSummary(device.advertisementData))
                                            .font(.caption2)
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
            }
            .navigationTitle("ImpossiBLE Sample")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                LogToolbarItem(isLogPresented: $isLogPresented)
                ToolbarItem(placement: .topBarLeading) {
                    Button(ble.isScanning ? "Stop" : "Scan") {
                        ble.isScanning ? ble.stopScan() : ble.startScan(serviceUUIDs: cbUUIDs(from: scanFilter), allowDuplicates: allowDuplicates)
                    }
                    .disabled(ble.state != .poweredOn)
                }
            }
            .onChange(of: ble.state) { _, newState in
                if newState != .poweredOn {
                    path = NavigationPath()
                }
            }
        }
        .fullScreenCover(isPresented: $isLogPresented) {
            LogSheetView(ble: ble)
        }
    }

    private var sortedDiscoveredDevices: [BLEManager.DiscoveredPeripheral] {
        ble.discovered.sorted { lhs, rhs in
            if lhs.hasDisplayName != rhs.hasDisplayName {
                return lhs.hasDisplayName
            }
            if lhs.isConnectable != rhs.isConnectable {
                return lhs.isConnectable
            }
            if lhs.rssi != rhs.rssi {
                return lhs.rssi > rhs.rssi
            }
            if lhs.name != rhs.name {
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}

// MARK: - Peripheral Detail

struct PeripheralDetailView: View {
    @ObservedObject var ble: BLEManager
    @Binding var isLogPresented: Bool
    @State private var serviceFilter = ""
    @State private var characteristicFilter = ""
    @State private var l2capPSM = "25"
    @State private var l2capHex = ""

    var body: some View {
        List {
            Section {
                Button("Discover Services") { ble.discoverServices() }
                TextField("Filtered service UUIDs", text: $serviceFilter)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Discover Filtered Services") {
                    ble.discoverServices(cbUUIDs(from: serviceFilter) ?? [])
                }
                .disabled((cbUUIDs(from: serviceFilter) ?? []).isEmpty)
                Button("Read RSSI") { ble.readRSSI() }
                Text("Max write: \(ble.maximumWriteValueLength(for: .withResponse)) response / \(ble.maximumWriteValueLength(for: .withoutResponse)) no-response bytes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Can send write without response: \(ble.canSendWriteWithoutResponse ? "Yes" : "No")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("L2CAP") {
                TextField("PSM", text: $l2capPSM)
                    .font(.system(.body, design: .monospaced))
                    .keyboardType(.numberPad)
                Button("Open Channel") {
                    if let psm = UInt16(l2capPSM.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        ble.openL2CAPChannel(psm: psm)
                    }
                }
                .disabled(UInt16(l2capPSM.trimmingCharacters(in: .whitespacesAndNewlines)) == nil)

                TextField("L2CAP write hex", text: $l2capHex)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                HStack {
                    Button("Write") {
                        guard let data = hexToData(l2capHex) else { return }
                        ble.writeL2CAP(data)
                    }
                    .disabled(!isL2CAPHexValid)
                    Button("Close") { ble.closeL2CAPChannel() }
                }
                Text(ble.l2capStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(Array(ble.l2capReceived.enumerated()), id: \.offset) { _, data in
                    Text(dataSummary(data))
                        .font(.caption2.monospaced())
                }
            }

            ForEach(servicesByUUID, id: \.uuid) { service in
                Section {
                    serviceHeader(service)
                    Button("Discover Included Services") {
                        ble.discoverIncludedServices(for: service)
                    }
                    .font(.caption)

                    let characteristics = characteristicsByUUID(for: service)
                    if !characteristics.isEmpty {
                        TextField("Characteristic filter", text: $characteristicFilter)
                            .font(.system(.caption, design: .monospaced))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Button("Discover Filtered Characteristics") {
                            ble.discoverCharacteristics(cbUUIDs(from: characteristicFilter) ?? [], for: service)
                        }
                        .font(.caption)
                        .disabled((cbUUIDs(from: characteristicFilter) ?? []).isEmpty)

                        ForEach(characteristics, id: \.uuid) { ch in
                            NavigationLink {
                                CharacteristicDetailView(
                                    ble: ble,
                                    characteristic: ch,
                                    isLogPresented: $isLogPresented
                                )
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
        }
        .navigationTitle(ble.connectedPeripheral?.name ?? "Peripheral")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            LogToolbarItem(isLogPresented: $isLogPresented)
        }
    }

    private var servicesByUUID: [CBService] {
        ble.services.sortedByUUID()
    }

    private func characteristicsByUUID(for service: CBService) -> [CBCharacteristic] {
        (service.characteristics ?? []).sortedByUUID()
    }

    private var isL2CAPHexValid: Bool {
        hexToData(l2capHex) != nil
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
                Text("\(service.includedServices?.count ?? 0) included")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let included = service.includedServices, !included.isEmpty {
                Text("Included: \(included.map(\.uuid.uuidString).joined(separator: ", "))")
                    .font(.caption2.monospaced())
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
    @Binding var isLogPresented: Bool
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

                    if !writeHex.isEmpty && !isWriteHexValid {
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

            let descriptors = descriptorsByUUID
            if !descriptors.isEmpty {
                Section("Descriptors") {
                    ForEach(descriptors, id: \.uuid) { desc in
                        NavigationLink {
                            DescriptorDetailView(ble: ble, descriptor: desc, isLogPresented: $isLogPresented)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(desc.uuid.uuidString)
                                    .font(.caption.monospaced())
                                if let val = ble.cachedValue(for: desc) {
                                    Text(valueSummary(val))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(characteristic.uuid.uuidString)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            LogToolbarItem(isLogPresented: $isLogPresented)
        }
    }

    private var isWriteHexValid: Bool {
        hexToData(writeHex) != nil
    }

    private var descriptorsByUUID: [CBDescriptor] {
        (characteristic.descriptors ?? []).sortedByUUID()
    }
}

// MARK: - Descriptor Detail

struct DescriptorDetailView: View {
    @ObservedObject var ble: BLEManager
    let descriptor: CBDescriptor
    @Binding var isLogPresented: Bool
    @State private var writeHex = ""

    var body: some View {
        List {
            Section("Descriptor") {
                Text(descriptor.uuid.uuidString)
                    .font(.system(.body, design: .monospaced))
                if let characteristic = descriptor.characteristic {
                    Text("Characteristic: \(characteristic.uuid.uuidString)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Actions") {
                Button("Read Descriptor") {
                    ble.readValue(for: descriptor)
                }

                TextField("Hex value", text: $writeHex)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                Button("Write Descriptor") {
                    guard let data = hexToData(writeHex) else { return }
                    ble.writeValue(data, for: descriptor)
                }
                .disabled(!isWriteHexValid)

                if !writeHex.isEmpty && !isWriteHexValid {
                    Text("Enter an even number of hex digits.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            if let value = ble.cachedValue(for: descriptor) {
                Section("Current Value") {
                    Text(valueSummary(value))
                        .font(.caption.monospaced())
                }
            }
        }
        .navigationTitle(descriptor.uuid.uuidString)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            LogToolbarItem(isLogPresented: $isLogPresented)
        }
    }

    private var isWriteHexValid: Bool {
        hexToData(writeHex) != nil
    }
}

// MARK: - Log Sheet

struct LogSheetView: View {
    @ObservedObject var ble: BLEManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if ble.log.isEmpty {
                    ContentUnavailableView(
                        "No Log Entries",
                        systemImage: "doc.text",
                        description: Text("Bluetooth events will appear here.")
                    )
                } else {
                    ForEach(ble.log) { entry in
                        LogEntryRow(entry: entry)
                    }
                }
            }
            .navigationTitle("Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Clear") {
                        ble.clearLog()
                    }
                    .disabled(ble.log.isEmpty)
                }
            }
        }
    }
}

struct LogEntryRow: View {
    let entry: BLEManager.LogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(entry.timestamp, format: .dateTime.hour().minute().second().secondFraction(.fractional(2)))
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
            Text(entry.message)
                .font(.caption)
        }
    }
}

struct LogToolbarItem: ToolbarContent {
    @Binding var isLogPresented: Bool

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                isLogPresented = true
            } label: {
                Label("Log", systemImage: "doc.text")
            }
            .accessibilityLabel("Show Log")
        }
    }
}

struct RetrievedPeripheralsView: View {
    let retrieved: [CBPeripheral]
    let connected: [CBPeripheral]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !retrieved.isEmpty {
                Text("Retrieved: \(names(retrieved))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !connected.isEmpty {
                Text("Connected: \(names(connected))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func names(_ peripherals: [CBPeripheral]) -> String {
        peripherals
            .map { $0.name ?? $0.identifier.uuidString }
            .joined(separator: ", ")
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

extension CBManagerAuthorization {
    var name: String {
        switch self {
            case .notDetermined: "Not Determined"
            case .restricted:    "Restricted"
            case .denied:        "Denied"
            case .allowedAlways: "Allowed Always"
            @unknown default:    "Authorization(\(rawValue))"
        }
    }
}

extension CBConnectionEvent {
    var name: String {
        switch self {
            case .peerDisconnected: "Peer Disconnected"
            case .peerConnected:    "Peer Connected"
            @unknown default:       "ConnectionEvent(\(rawValue))"
        }
    }
}

private protocol CBUUIDSortable {
    var uuid: CBUUID { get }
}

extension CBService: CBUUIDSortable {}
extension CBCharacteristic: CBUUIDSortable {}
extension CBDescriptor: CBUUIDSortable {}

private extension Array where Element: CBUUIDSortable {
    func sortedByUUID() -> [Element] {
        sorted { lhs, rhs in
            lhs.uuid.uuidString.localizedStandardCompare(rhs.uuid.uuidString) == .orderedAscending
        }
    }
}

func cbUUIDs(from text: String) -> [CBUUID]? {
    let tokens = text
        .split { $0 == "," || $0 == " " || $0 == "\n" || $0 == "\t" || $0 == ";" }
        .map(String.init)
    guard !tokens.isEmpty else { return nil }
    return tokens.map { CBUUID(string: $0) }
}

func hexToData(_ hex: String) -> Data? {
    let clean = hex.filter { !$0.isWhitespace && $0 != "," && $0 != ":" && $0 != "-" }
    guard !clean.isEmpty else { return nil }
    guard clean.allSatisfy(\.isHexDigit) else { return nil }
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

func dataSummary(_ data: Data) -> String {
    let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
    if let utf8 = String(data: data, encoding: .utf8), !utf8.isEmpty {
        return "\(hex) (\(utf8))"
    }
    return hex.isEmpty ? "empty" : hex
}

func valueSummary(_ value: Any?) -> String {
    guard let value else { return "nil" }
    if let data = value as? Data {
        return dataSummary(data)
    }
    return String(describing: value)
}

func advertisementSummary(_ advertisementData: [String: Any]) -> String {
    var parts: [String] = []
    if let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String, !name.isEmpty {
        parts.append("name=\(name)")
    }
    if let connectable = advertisementData[CBAdvertisementDataIsConnectable] as? Bool {
        parts.append(connectable ? "connectable" : "not connectable")
    } else if let connectable = advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber {
        parts.append(connectable.boolValue ? "connectable" : "not connectable")
    }
    if let uuids = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID], !uuids.isEmpty {
        parts.append("services=\(uuids.map(\.uuidString).joined(separator: ","))")
    } else if let uuids = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [String], !uuids.isEmpty {
        parts.append("services=\(uuids.joined(separator: ","))")
    }
    if let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data {
        parts.append("mfg=\(manufacturerData.count)b")
    }
    if let txPower = advertisementData[CBAdvertisementDataTxPowerLevelKey] {
        parts.append("tx=\(txPower)")
    }
    return parts.isEmpty ? "No advertisement fields" : parts.joined(separator: " | ")
}
