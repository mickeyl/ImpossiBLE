import Foundation
import ImpossiBLEPassthroughCore
import SimBridgeServer

private let kSocketPath = "/tmp/impossible.sock"

/// A configuration handed over by the connected app, shown in place of the
/// user's selection while it is active.
struct ClientSuppliedConfiguration: Equatable {
    let name: String
    let devices: [MockDevice]
    let client: SocketClientInfo?

    var sourceDescription: String { client?.displayText ?? "connected app" }
}

/// The domain layer behind `/tmp/impossible.sock`, serving the ImpossiBLE wire
/// protocol in one of two modes: answering from mock data, or forwarding to
/// real Mac Bluetooth hardware through the in-process `CBSPassthroughBridge`.
///
/// The transport itself — socket lifecycle, NDJSON framing, hello handshake,
/// last-connection-wins takeover, client-socket hardening, and the
/// socket-ownership guard — lives in SimBridgeKit's `ProtocolServer`. Every
/// handler here runs on the transport's I/O queue, which also guards all
/// mutable state; UI-facing state is published on the main thread.
final class MockServer: ObservableObject {
    enum ServeMode: Sendable {
        case mock
        case passthrough
    }

    /// Socket lifecycle, connection status, client identity, and the activity
    /// line are published by the transport; observe it directly.
    let transport: ProtocolServer

    @Published var connectedDeviceIDs: Set<String> = []
    /// Set while the connected client supplies its own devices. Published in
    /// full — not just the name — because the device list would otherwise show
    /// the user's configuration while a different one is being served.
    @Published private(set) var clientSuppliedConfiguration: ClientSuppliedConfiguration?
    @Published var pairedDeviceIDs: Set<String> = []

    weak var store: MockStore?
    let passthroughActivity = PassthroughActivityMonitor()

    // Guarded by the transport's I/O queue
    private var serveMode: ServeMode = .mock
    private var currentClient: SocketClientInfo?
    private var connectedPeripherals = Set<String>()
    private var pairedPeripherals = Set<String>()
    private var scanActive = false
    private var scanTimer: DispatchSourceTimer?
    private var writtenCharValues: [String: Data] = [:]
    private var writtenDescValues: [String: Data] = [:]
    private var notifyingCharacteristics = Set<String>()
    /// A configuration uploaded by the connected client. Deliberately kept in
    /// memory only: it must never overwrite the user's saved configurations,
    /// and it dies with the connection that supplied it.
    private var clientSuppliedDevices: [MockDevice]?
    /// Created on first Passthrough start and kept for the process lifetime;
    /// instantiating it triggers the one-time macOS Bluetooth consent prompt.
    private var passthroughBridge: CBSPassthroughBridge?

    private static let serverEnabledKey = "ServerEnabled"

    init(autoStart: Bool = true) {
        transport = ProtocolServer(
            socketPath: kSocketPath,
            name: "ImpossiBLE-Mock",
            appVersion: AppVersion.current
        )
        transport.onMessage = { [weak self] message in
            self?.handleMessage(message)
        }
        transport.onClientConnected = { [weak self] client in
            self?.handleClientConnected(client)
        }
        transport.onClientTeardown = { [weak self] _ in
            self?.tearDownClientState()
        }

        if autoStart, UserDefaults.standard.bool(forKey: Self.serverEnabledKey) {
            start(mode: .mock)
        }
    }

    func start(mode: ServeMode, completion: (() -> Void)? = nil) {
        UserDefaults.standard.set(true, forKey: Self.serverEnabledKey)
        transport.performOnIOQueue { [self] in
            serveMode = mode
            if mode == .passthrough {
                preparePassthroughBridge()
            }
        }
        transport.start(completion: completion)
    }

    func stop(completion: (() -> Void)? = nil) {
        UserDefaults.standard.set(false, forKey: Self.serverEnabledKey)
        transport.stop(completion: completion)
    }

    func terminateConnectedClient() {
        transport.terminateConnectedClient()
    }

    // MARK: - Connection lifecycle (called on the transport's I/O queue)

    private func handleClientConnected(_ client: SocketClientInfo?) {
        currentClient = client
        tearDownClientState()
    }

    /// Everything the previous client owned, in both modes. Runs on connect,
    /// disconnect, takeover, and stop alike.
    private func tearDownClientState() {
        connectedPeripherals.removeAll()
        pairedPeripherals.removeAll()
        writtenCharValues.removeAll()
        writtenDescValues.removeAll()
        notifyingCharacteristics.removeAll()
        scanTimer?.cancel()
        scanTimer = nil
        scanActive = false
        clearClientSuppliedConfiguration()
        passthroughBridge?.reset()
        clearPassthroughActivity()
        publishDeviceState()
    }

    private func preparePassthroughBridge() {
        guard passthroughBridge == nil else { return }
        let bridge = CBSPassthroughBridge()
        bridge.messageHandler = { [weak self] message in
            guard let self else { return }
            self.transport.performOnIOQueue {
                guard self.serveMode == .passthrough else { return }
                self.transport.send(message)
            }
        }
        bridge.activityHandler = { [weak self] peripheralId, name, operation, detail in
            guard let self else { return }
            DispatchQueue.main.async {
                self.passthroughActivity.record(id: peripheralId, name: name, operation: operation, detail: detail)
            }
            self.transport.note("\(name.isEmpty ? peripheralId.prefix(8) : Substring(name)): \(operation)")
        }
        passthroughBridge = bridge
    }

    private func clearPassthroughActivity() {
        DispatchQueue.main.async { [passthroughActivity] in
            passthroughActivity.clear()
        }
    }

    // MARK: - Protocol Handler (called on the transport's I/O queue)

    private func handleMessage(_ msg: [String: Any]) {
        guard let type = msg["type"] as? String else { return }

        if serveMode == .passthrough {
            passthroughBridge?.handleMessage(msg)
            return
        }

        switch type {
        case "scan":            handleScan(msg)
        case "stopScan":        handleStopScan()
        case "connect":         handleConnect(msg)
        case "cancel":          handleCancel(msg)
        case "discoverServices":           handleDiscoverServices(msg)
        case "discoverIncludedServices":   handleDiscoverIncludedServices(msg)
        case "discoverCharacteristics":    handleDiscoverCharacteristics(msg)
        case "discoverDescriptors":        handleDiscoverDescriptors(msg)
        case "read":            handleRead(msg)
        case "readDescriptor":  handleReadDescriptor(msg)
        case "write":           handleWrite(msg)
        case "writeDescriptor": handleWriteDescriptor(msg)
        case "setNotify":       handleSetNotify(msg)
        case "readRSSI":        handleReadRSSI(msg)
        case "registerForConnectionEvents": break
        case "setMockConfiguration":   handleSetMockConfiguration(msg)
        case "clearMockConfiguration": clearClientSuppliedConfiguration()
        case "openL2CAP":       handleOpenL2CAP(msg)
        case "l2capWrite", "l2capClose": break
        default:
            NSLog("ImpossiBLE-Mock: unknown message type: %@", type)
        }
    }

    // MARK: - Helpers for main-thread store access

    private func fetchEnabledDevices() -> [MockDevice] {
        if let clientSuppliedDevices {
            return clientSuppliedDevices.filter(\.isEnabled)
        }
        return DispatchQueue.main.sync { store?.enabledDevices ?? [] }
    }

    private func fetchDevice(uuid: String) -> MockDevice? {
        if let clientSuppliedDevices {
            return clientSuppliedDevices.first { $0.id.uuidString == uuid }
        }
        return DispatchQueue.main.sync { store?.devices.first { $0.id.uuidString == uuid } }
    }

    // MARK: - Client-supplied configuration

    private func handleSetMockConfiguration(_ msg: [String: Any]) {
        guard let raw = msg["configuration"] else {
            sendMockConfigurationResult(ok: false, error: "missing configuration")
            return
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: raw)
            let configuration = try JSONDecoder().decode(MockConfiguration.self, from: data)
            clientSuppliedDevices = configuration.devices

            let published = ClientSuppliedConfiguration(
                name: configuration.name,
                devices: configuration.devices,
                client: currentClient
            )
            DispatchQueue.main.async { self.clientSuppliedConfiguration = published }
            let name = configuration.name
            transport.note("Client supplied configuration '\(name)' with \(configuration.devices.count) device(s)")
            sendMockConfigurationResult(ok: true, error: nil)
        } catch {
            // Report back rather than failing silently: a test that uploads a
            // malformed fixture would otherwise just see an empty scan.
            transport.note("Rejected client configuration: \(error.localizedDescription)")
            sendMockConfigurationResult(ok: false, error: error.localizedDescription)
        }
    }

    private func clearClientSuppliedConfiguration() {
        guard clientSuppliedDevices != nil else { return }
        clientSuppliedDevices = nil
        DispatchQueue.main.async { self.clientSuppliedConfiguration = nil }
        transport.note("Client configuration cleared; serving the selected configuration again")
    }

    private func sendMockConfigurationResult(ok: Bool, error: String?) {
        var msg: [String: Any] = ["type": "didSetMockConfiguration", "ok": ok]
        if let error { msg["error"] = error }
        transport.send(msg)
    }

    // MARK: - Scan

    private func handleScan(_ msg: [String: Any]) {
        scanActive = true
        let serviceFilter: [String]? = (msg["services"] as? [String])?.isEmpty == false
            ? msg["services"] as? [String]
            : nil

        sendDiscoveries(serviceFilter: serviceFilter)

        scanTimer?.cancel()
        let timer = DispatchSource.makeTimerSource()
        timer.schedule(deadline: .now() + 1.0, repeating: 2.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.transport.performOnIOQueue {
                guard self.scanActive else { return }
                self.sendDiscoveries(serviceFilter: serviceFilter)
            }
        }
        timer.resume()
        scanTimer = timer
    }

    private func handleStopScan() {
        scanActive = false
        scanTimer?.cancel()
        scanTimer = nil
    }

    private func sendDiscoveries(serviceFilter: [String]?) {
        let devices = fetchEnabledDevices()

        for device in devices {
            let matchesFilter: Bool
            if let filter = serviceFilter {
                let deviceServiceUUIDs = Set(
                    device.advertisedServiceUUIDs.map { $0.uppercased() } +
                    device.services.map { $0.uuid.uppercased() }
                )
                matchesFilter = filter.contains { deviceServiceUUIDs.contains($0.uppercased()) }
            } else {
                matchesFilter = true
            }
            guard matchesFilter else { continue }

            var adv: [String: Any] = [:]
            adv["kCBAdvDataLocalName"] = device.name
            adv["kCBAdvDataIsConnectable"] = device.isConnectable

            let svcUUIDs = device.advertisedServiceUUIDs.isEmpty
                ? device.services.map(\.uuid)
                : device.advertisedServiceUUIDs
            if !svcUUIDs.isEmpty {
                adv["kCBAdvDataServiceUUIDs"] = svcUUIDs
            }
            if let mfg = device.manufacturerData, !mfg.isEmpty {
                adv["kCBAdvDataManufacturerData"] = mfg.base64EncodedString()
            }

            transport.send([
                "type": "didDiscover",
                "id": device.id.uuidString,
                "name": device.name,
                "rssi": device.rssi,
                "adv": adv,
            ])
        }
    }

    // MARK: - Connect / Disconnect

    private func handleConnect(_ msg: [String: Any]) {
        guard let uuidStr = msg["id"] as? String else { return }
        guard let device = fetchDevice(uuid: uuidStr), device.isConnectable else {
            transport.send(["type": "didFailConnect", "id": uuidStr, "error": "Device not connectable"])
            return
        }
        connectedPeripherals.insert(uuidStr)
        publishDeviceState()
        transport.send(["type": "didConnect", "id": uuidStr])
    }

    private func handleCancel(_ msg: [String: Any]) {
        guard let uuidStr = msg["id"] as? String else { return }
        connectedPeripherals.remove(uuidStr)
        pairedPeripherals.remove(uuidStr)
        notifyingCharacteristics = notifyingCharacteristics.filter { !$0.hasPrefix(uuidStr) }
        publishDeviceState()
        transport.send([
            "type": "didDisconnect",
            "id": uuidStr,
            "error": "",
            "timestamp": CFAbsoluteTimeGetCurrent(),
            "isReconnecting": false,
        ])
    }

    // MARK: - Service Discovery

    private func handleDiscoverServices(_ msg: [String: Any]) {
        guard let uuidStr = msg["id"] as? String else { return }
        let rawFilter = msg["services"] as? [String]
        let filterUUIDs: [String]? = (rawFilter?.isEmpty == false) ? rawFilter!.map { $0.uppercased() } : nil

        guard let device = fetchDevice(uuid: uuidStr) else {
            transport.note("discoverServices: device not found for \(uuidStr)")
            transport.send(["type": "didDiscoverServices", "id": uuidStr, "services": [] as [[String: Any]], "error": "Device not found"])
            return
        }

        var servicesPayload: [[String: Any]] = []
        for (idx, svc) in device.services.enumerated() {
            if let filter = filterUUIDs, !filter.contains(svc.uuid.uppercased()) {
                continue
            }
            let shimId = "\(uuidStr):\(svc.uuid):\(idx)"
            servicesPayload.append([
                "id": shimId,
                "uuid": svc.uuid,
                "primary": svc.isPrimary,
            ])
        }

        transport.send([
            "type": "didDiscoverServices",
            "id": uuidStr,
            "services": servicesPayload,
            "error": "",
        ])
    }

    private func handleDiscoverIncludedServices(_ msg: [String: Any]) {
        guard let serviceId = msg["serviceId"] as? String else { return }
        let parts = serviceId.split(separator: ":")
        guard parts.count >= 1 else { return }
        let peripheralUUID = String(parts[0])
        transport.send([
            "type": "didDiscoverIncludedServices",
            "id": peripheralUUID,
            "serviceId": serviceId,
            "includedServices": [] as [[String: Any]],
            "error": "",
        ])
    }

    // MARK: - Characteristic Discovery

    private func handleDiscoverCharacteristics(_ msg: [String: Any]) {
        guard let serviceId = msg["serviceId"] as? String else { return }
        let rawFilter = msg["characteristics"] as? [String]
        let filterUUIDs: [String]? = (rawFilter?.isEmpty == false) ? rawFilter!.map { $0.uppercased() } : nil

        let parts = serviceId.split(separator: ":")
        guard parts.count >= 3 else { return }
        let peripheralUUID = String(parts[0])
        let serviceUUID = String(parts[1])
        let serviceIdx = Int(parts[2]) ?? 0

        guard let device = fetchDevice(uuid: peripheralUUID),
              serviceIdx < device.services.count,
              device.services[serviceIdx].uuid.uppercased() == serviceUUID.uppercased()
        else { return }

        let svc = device.services[serviceIdx]
        var charsPayload: [[String: Any]] = []
        for (idx, ch) in svc.characteristics.enumerated() {
            if let filter = filterUUIDs, !filter.contains(ch.uuid.uppercased()) {
                continue
            }
            let shimId = "\(serviceId):\(ch.uuid):\(idx)"
            charsPayload.append([
                "id": shimId,
                "uuid": ch.uuid,
                "properties": ch.properties,
            ])
        }

        transport.send([
            "type": "didDiscoverCharacteristics",
            "id": peripheralUUID,
            "serviceId": serviceId,
            "characteristics": charsPayload,
            "error": "",
        ])
    }

    // MARK: - Descriptor Discovery

    private func handleDiscoverDescriptors(_ msg: [String: Any]) {
        guard let charId = msg["characteristicId"] as? String else { return }
        let parts = charId.split(separator: ":")
        guard parts.count >= 5 else { return }
        let peripheralUUID = String(parts[0])
        let serviceIdx = Int(parts[2]) ?? 0
        let charIdx = Int(parts[4]) ?? 0

        guard let device = fetchDevice(uuid: peripheralUUID),
              serviceIdx < device.services.count,
              charIdx < device.services[serviceIdx].characteristics.count
        else { return }

        let ch = device.services[serviceIdx].characteristics[charIdx]
        var descriptorsPayload: [[String: Any]] = []
        for (idx, desc) in ch.descriptors.enumerated() {
            let shimId = "\(charId):\(desc.uuid):\(idx)"
            descriptorsPayload.append([
                "id": shimId,
                "uuid": desc.uuid,
            ])
        }

        transport.send([
            "type": "didDiscoverDescriptors",
            "id": peripheralUUID,
            "characteristicId": charId,
            "descriptors": descriptorsPayload,
            "error": "",
        ])
    }

    // MARK: - Read / Write

    private func handleRead(_ msg: [String: Any]) {
        guard let charId = msg["characteristicId"] as? String else { return }
        let parts = charId.split(separator: ":")
        guard parts.count >= 5 else { return }
        let peripheralUUID = String(parts[0])
        let serviceIdx = Int(parts[2]) ?? 0
        let charIdx = Int(parts[4]) ?? 0

        guard checkSecurity(peripheralUUID: peripheralUUID, serviceIdx: serviceIdx, charIdx: charIdx) else {
            sendAuthError(type: "didUpdateValue", peripheralUUID: peripheralUUID, idKey: "characteristicId", idValue: charId)
            return
        }

        let value: Data?
        if let written = writtenCharValues[charId] {
            value = written
        } else if let device = fetchDevice(uuid: peripheralUUID),
                  serviceIdx < device.services.count,
                  charIdx < device.services[serviceIdx].characteristics.count {
            value = device.services[serviceIdx].characteristics[charIdx].value
        } else {
            value = nil
        }

        transport.send([
            "type": "didUpdateValue",
            "id": peripheralUUID,
            "characteristicId": charId,
            "value": value?.base64EncodedString() ?? "",
            "error": "",
        ])
    }

    private func handleWrite(_ msg: [String: Any]) {
        guard let charId = msg["characteristicId"] as? String else { return }
        let parts = charId.split(separator: ":")
        guard parts.count >= 5 else { return }
        let peripheralUUID = String(parts[0])
        let serviceIdx = Int(parts[2]) ?? 0
        let charIdx = Int(parts[4]) ?? 0

        guard checkSecurity(peripheralUUID: peripheralUUID, serviceIdx: serviceIdx, charIdx: charIdx) else {
            sendAuthError(type: "didWriteValue", peripheralUUID: peripheralUUID, idKey: "characteristicId", idValue: charId)
            return
        }

        if let b64 = msg["value"] as? String, !b64.isEmpty {
            writtenCharValues[charId] = Data(base64Encoded: b64)
        } else {
            writtenCharValues[charId] = Data()
        }

        let writeType = (msg["writeType"] as? Int) ?? 0
        if writeType == 0 {
            transport.send([
                "type": "didWriteValue",
                "id": peripheralUUID,
                "characteristicId": charId,
                "error": "",
            ])
        }
    }

    private func handleReadDescriptor(_ msg: [String: Any]) {
        guard let descId = msg["descriptorId"] as? String else { return }
        let parts = descId.split(separator: ":")
        guard parts.count >= 5 else { return }
        let peripheralUUID = String(parts[0])
        let serviceIdx = Int(parts[2]) ?? 0
        let charIdx = Int(parts[4]) ?? 0
        let descIdx: Int
        if parts.count >= 7 {
            descIdx = Int(parts[6]) ?? 0
        } else {
            descIdx = 0
        }

        let value: Data?
        if let written = writtenDescValues[descId] {
            value = written
        } else if let device = fetchDevice(uuid: peripheralUUID),
                  serviceIdx < device.services.count,
                  charIdx < device.services[serviceIdx].characteristics.count,
                  descIdx < device.services[serviceIdx].characteristics[charIdx].descriptors.count {
            value = device.services[serviceIdx].characteristics[charIdx].descriptors[descIdx].value
        } else {
            value = nil
        }

        transport.send([
            "type": "didUpdateDescriptorValue",
            "id": peripheralUUID,
            "descriptorId": descId,
            "value": NSNull(),
            "valueB64": value?.base64EncodedString() ?? "",
            "error": "",
        ])
    }

    private func handleWriteDescriptor(_ msg: [String: Any]) {
        guard let descId = msg["descriptorId"] as? String else { return }
        let parts = descId.split(separator: ":")
        guard parts.count >= 1 else { return }
        let peripheralUUID = String(parts[0])

        if let b64 = msg["value"] as? String, !b64.isEmpty {
            writtenDescValues[descId] = Data(base64Encoded: b64)
        }

        transport.send([
            "type": "didWriteDescriptorValue",
            "id": peripheralUUID,
            "descriptorId": descId,
            "error": "",
        ])
    }

    // MARK: - Notify

    private func handleSetNotify(_ msg: [String: Any]) {
        guard let charId = msg["characteristicId"] as? String else { return }
        let enabled: Bool
        if let b = msg["enabled"] as? Bool {
            enabled = b
        } else if let n = msg["enabled"] as? Int {
            enabled = n != 0
        } else {
            return
        }

        let parts = charId.split(separator: ":")
        guard parts.count >= 1 else { return }
        let peripheralUUID = String(parts[0])

        if enabled {
            notifyingCharacteristics.insert(charId)
        } else {
            notifyingCharacteristics.remove(charId)
        }

        transport.send([
            "type": "didUpdateNotification",
            "id": peripheralUUID,
            "characteristicId": charId,
            "enabled": enabled,
            "error": "",
        ])
    }

    // MARK: - RSSI

    private func handleReadRSSI(_ msg: [String: Any]) {
        guard let uuidStr = msg["id"] as? String else { return }
        let device = fetchDevice(uuid: uuidStr)

        transport.send([
            "type": "didReadRSSI",
            "id": uuidStr,
            "rssi": device?.rssi ?? -50,
            "error": "",
        ])
    }

    // MARK: - L2CAP (not supported in mock mode)

    private func handleOpenL2CAP(_ msg: [String: Any]) {
        guard let uuidStr = msg["id"] as? String else { return }
        transport.send([
            "type": "didOpenL2CAP",
            "id": uuidStr,
            "channelId": "",
            "psm": 0,
            "error": "L2CAP is not supported in mock mode",
        ])
    }

    // MARK: - Security

    private func checkSecurity(peripheralUUID: String, serviceIdx: Int, charIdx: Int) -> Bool {
        guard let device = fetchDevice(uuid: peripheralUUID),
              serviceIdx < device.services.count,
              charIdx < device.services[serviceIdx].characteristics.count
        else { return true }

        let characteristic = device.services[serviceIdx].characteristics[charIdx]
        guard characteristic.securityLevel == .encryptionRequired else { return true }
        guard !pairedPeripherals.contains(peripheralUUID) else { return true }

        switch device.pairingMode {
            case .none:
                return true
            case .justWorks:
                pairedPeripherals.insert(peripheralUUID)
                publishDeviceState()
                transport.note("Auto-paired (Just Works): \(device.name)")
                return true
            case .passkey:
                return false
        }
    }

    private func sendAuthError(type: String, peripheralUUID: String, idKey: String, idValue: String) {
        transport.send([
            "type": type,
            "id": peripheralUUID,
            idKey: idValue,
            "value": "",
            "error": "Insufficient authentication",
            "errorDomain": "CBATTErrorDomain",
            "errorCode": 5,
        ])
    }

    // MARK: - Utilities

    private func publishDeviceState() {
        let connected = connectedPeripherals
        let paired = pairedPeripherals
        DispatchQueue.main.async { [weak self] in
            self?.connectedDeviceIDs = connected
            self?.pairedDeviceIDs = paired
        }
    }
}
