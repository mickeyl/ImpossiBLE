import Foundation

private let kSocketPath = "/tmp/impossible.sock"

/// Socket server that implements the ImpossiBLE helper protocol with mock data.
/// All socket I/O runs on `ioQueue`. UI-facing state is published on the main thread.
final class MockServer: ObservableObject {
    enum Status: Equatable, Sendable {
        case stopped
        case listening
        case clientConnected
    }

    @Published var status: Status = .stopped
    @Published var lastActivity: String = ""
    @Published var trafficActive: Bool = false
    @Published var connectedDeviceIDs: Set<String> = []
    @Published var pairedDeviceIDs: Set<String> = []

    private let ioQueue = DispatchQueue(label: "impossible.mock.io")

    // Guarded by ioQueue
    private var serverFd: Int32 = -1
    private var clientFd: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var readSource: DispatchSourceRead?
    private var readBuffer = Data()
    private var connectedPeripherals = Set<String>()
    private var pairedPeripherals = Set<String>()
    private var scanActive = false
    private var scanTimer: DispatchSourceTimer?
    private var writtenCharValues: [String: Data] = [:]
    private var writtenDescValues: [String: Data] = [:]
    private var notifyingCharacteristics = Set<String>()

    weak var store: MockStore?

    private static let serverEnabledKey = "ServerEnabled"

    init(autoStart: Bool = true) {
        if autoStart, UserDefaults.standard.bool(forKey: Self.serverEnabledKey) {
            start()
        }
    }

    func start() {
        UserDefaults.standard.set(true, forKey: Self.serverEnabledKey)
        ioQueue.async { [self] in
            guard serverFd < 0 else { return }

            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else {
                NSLog("ImpossiBLE-Mock: socket() failed")
                return
            }

            unlink(kSocketPath)

            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let pathBytes = kSocketPath.utf8CString
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                let raw = UnsafeMutableRawPointer(ptr)
                pathBytes.withUnsafeBufferPointer { buf in
                    raw.copyMemory(from: buf.baseAddress!, byteCount: min(buf.count, 104))
                }
            }

            let bindResult = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bindResult == 0 else {
                NSLog("ImpossiBLE-Mock: bind() failed: %d", errno)
                close(fd)
                return
            }

            guard listen(fd, 2) == 0 else {
                NSLog("ImpossiBLE-Mock: listen() failed")
                close(fd)
                return
            }

            serverFd = fd
            publishStatus(.listening)
            log("Listening")

            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
            source.setEventHandler { [weak self] in
                self?.acceptClient()
            }
            source.setCancelHandler {
                close(fd)
            }
            source.resume()
            acceptSource = source
        }
    }

    func stop(completion: (() -> Void)? = nil) {
        UserDefaults.standard.set(false, forKey: Self.serverEnabledKey)
        ioQueue.async { [self] in
            let hadServer = serverFd >= 0

            scanTimer?.cancel()
            scanTimer = nil
            scanActive = false

            readSource?.cancel()
            readSource = nil
            if clientFd >= 0 {
                close(clientFd)
                clientFd = -1
            }

            acceptSource?.cancel()
            acceptSource = nil
            serverFd = -1

            if hadServer {
                unlink(kSocketPath)
            }

            connectedPeripherals.removeAll()
            pairedPeripherals.removeAll()
            writtenCharValues.removeAll()
            writtenDescValues.removeAll()
            notifyingCharacteristics.removeAll()
            readBuffer.removeAll()

            publishDeviceState()
            publishStatus(.stopped)
            log("Stopped")

            if let completion {
                DispatchQueue.main.async {
                    completion()
                }
            }
        }
    }

    // MARK: - Connection (called on ioQueue)

    private func acceptClient() {
        let fd = accept(serverFd, nil, nil)
        guard fd >= 0 else { return }

        if clientFd >= 0 {
            readSource?.cancel()
            close(clientFd)
        }
        clientFd = fd
        readBuffer.removeAll()
        connectedPeripherals.removeAll()
        pairedPeripherals.removeAll()
        writtenCharValues.removeAll()
        writtenDescValues.removeAll()
        notifyingCharacteristics.removeAll()
        scanActive = false
        scanTimer?.cancel()
        scanTimer = nil

        publishStatus(.clientConnected)
        log("Client connected")

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
        source.setEventHandler { [weak self] in
            self?.readFromClient(fd: fd)
        }
        source.setCancelHandler { }
        source.resume()
        readSource = source
    }

    private func readFromClient(fd: Int32) {
        var buf = [UInt8](repeating: 0, count: 2048)
        let n = read(fd, &buf, buf.count)
        if n <= 0 {
            readSource?.cancel()
            readSource = nil
            close(fd)
            clientFd = -1
            scanTimer?.cancel()
            scanTimer = nil
            scanActive = false
            connectedPeripherals.removeAll()
            pairedPeripherals.removeAll()

            publishDeviceState()
            publishStatus(.listening)
            log("Client disconnected")
            return
        }
        readBuffer.append(contentsOf: buf[0..<n])

        while let newlineIndex = readBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = readBuffer[readBuffer.startIndex..<newlineIndex]
            readBuffer.removeSubrange(readBuffer.startIndex...newlineIndex)
            if lineData.isEmpty { continue }
            if let msg = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] {
                handleMessage(msg)
            }
        }
    }

    // MARK: - Send (called on ioQueue)

    private func send(_ msg: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              clientFd >= 0 else { return }
        var payload = data
        payload.append(UInt8(ascii: "\n"))
        let fd = clientFd
        payload.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            var written = 0
            while written < payload.count {
                let n = write(fd, base.advanced(by: written), payload.count - written)
                if n <= 0 { break }
                written += n
            }
        }
    }

    // MARK: - Protocol Handler (called on ioQueue)

    private func handleMessage(_ msg: [String: Any]) {
        guard let type = msg["type"] as? String else { return }

        log("recv: \(type)")

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
        case "openL2CAP":       handleOpenL2CAP(msg)
        case "l2capWrite", "l2capClose": break
        default:
            NSLog("ImpossiBLE-Mock: unknown message type: %@", type)
        }
    }

    // MARK: - Helpers for main-thread store access

    private func fetchEnabledDevices() -> [MockDevice] {
        DispatchQueue.main.sync { store?.enabledDevices ?? [] }
    }

    private func fetchDevice(uuid: String) -> MockDevice? {
        DispatchQueue.main.sync { store?.devices.first { $0.id.uuidString == uuid } }
    }

    // MARK: - Scan

    private func handleScan(_ msg: [String: Any]) {
        scanActive = true
        let serviceFilter: [String]? = (msg["services"] as? [String])?.isEmpty == false
            ? msg["services"] as? [String]
            : nil

        sendDiscoveries(serviceFilter: serviceFilter)

        scanTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: ioQueue)
        timer.schedule(deadline: .now() + 1.0, repeating: 2.0)
        timer.setEventHandler { [weak self] in
            guard let self, self.scanActive else { return }
            self.sendDiscoveries(serviceFilter: serviceFilter)
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

            send([
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
            send(["type": "didFailConnect", "id": uuidStr, "error": "Device not connectable"])
            return
        }
        connectedPeripherals.insert(uuidStr)
        publishDeviceState()
        send(["type": "didConnect", "id": uuidStr])
    }

    private func handleCancel(_ msg: [String: Any]) {
        guard let uuidStr = msg["id"] as? String else { return }
        connectedPeripherals.remove(uuidStr)
        pairedPeripherals.remove(uuidStr)
        notifyingCharacteristics = notifyingCharacteristics.filter { !$0.hasPrefix(uuidStr) }
        publishDeviceState()
        send([
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
            log("discoverServices: device not found for \(uuidStr)")
            send(["type": "didDiscoverServices", "id": uuidStr, "services": [] as [[String: Any]], "error": "Device not found"])
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

        send([
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
        send([
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

        send([
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

        send([
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

        send([
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
            send([
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

        send([
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

        send([
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

        send([
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

        send([
            "type": "didReadRSSI",
            "id": uuidStr,
            "rssi": device?.rssi ?? -50,
            "error": "",
        ])
    }

    // MARK: - L2CAP (not supported)

    private func handleOpenL2CAP(_ msg: [String: Any]) {
        guard let uuidStr = msg["id"] as? String else { return }
        send([
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
                log("Auto-paired (Just Works): \(device.name)")
                return true
            case .passkey:
                return false
        }
    }

    private func sendAuthError(type: String, peripheralUUID: String, idKey: String, idValue: String) {
        send([
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

    private func publishStatus(_ newStatus: Status) {
        DispatchQueue.main.async { [weak self] in
            self?.status = newStatus
        }
    }

    private func publishDeviceState() {
        let connected = connectedPeripherals
        let paired = pairedPeripherals
        DispatchQueue.main.async { [weak self] in
            self?.connectedDeviceIDs = connected
            self?.pairedDeviceIDs = paired
        }
    }

    private var pulseWorkItem: DispatchWorkItem?

    private func log(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lastActivity = message
            self.pulseTraffic()
        }
    }

    private func pulseTraffic() {
        pulseWorkItem?.cancel()
        trafficActive = true
        let item = DispatchWorkItem { [weak self] in
            self?.trafficActive = false
        }
        pulseWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }
}
