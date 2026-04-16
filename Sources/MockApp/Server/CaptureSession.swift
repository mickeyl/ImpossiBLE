import Foundation
import Darwin

private let captureSocketPath = "/tmp/impossible.sock"

struct CapturedDevice: Identifiable, Hashable {
    let id: String
    var name: String
    var rssi: Int
    var isConnectable: Bool
    var advertisedServiceUUIDs: [String]
    var manufacturerData: Data?
    var firstSeen: Date
    var lastSeen: Date
    var seenCount: Int

    var displayName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Unnamed Device" : name
    }

    var hasName: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var servicesSummary: String {
        advertisedServiceUUIDs.isEmpty ? "No advertised services" : advertisedServiceUUIDs.joined(separator: ", ")
    }

    func makeMockDevice() -> MockDevice {
        var device = MockDevice()
        device.id = UUID(uuidString: id) ?? UUID()
        device.name = displayName
        device.rssi = rssi
        device.isConnectable = isConnectable
        device.isEnabled = true
        device.advertisedServiceUUIDs = advertisedServiceUUIDs
        device.manufacturerData = manufacturerData
        device.services = advertisedServiceUUIDs.map {
            MockService(uuid: $0, isPrimary: true, characteristics: [])
        }
        return device
    }
}

struct CaptureInspectionProgress: Equatable {
    var isActive = false
    var currentIndex = 0
    var total = 0
    var deviceName = ""
    var phase = ""

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, (Double(currentIndex) + 0.25) / Double(total)))
    }
}

final class CaptureSession: ObservableObject {
    enum Status: Equatable {
        case idle
        case connecting
        case scanning
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var devices: [CapturedDevice] = []
    @Published private(set) var lastActivity: String = ""
    @Published private(set) var inspectionProgress = CaptureInspectionProgress()

    private let queue = DispatchQueue(label: "impossible.capture.io")
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var readBuffer = Data()
    private var devicesByID: [String: CapturedDevice] = [:]
    private var inspectionCompletion: (([MockDevice]) -> Void)?
    private var inspectionDevices: [CapturedDevice] = []
    private var inspectionResults: [MockDevice] = []
    private var inspectionIndex = 0
    private var inspectionServices: [ServiceDraft] = []
    private var pendingInspection: PendingInspection?
    private var inspectionTimeoutID = 0

    var isRunning: Bool {
        status == .connecting || status == .scanning
    }

    var isInspecting: Bool {
        inspectionProgress.isActive
    }

    deinit {
        readSource?.cancel()
        readSource = nil
        if fd >= 0 {
            close(fd)
            fd = -1
        }
    }

    func start(serviceUUIDs: [String]) {
        queue.async { [self] in
            guard fd < 0 else { return }
            devicesByID.removeAll()
            readBuffer.removeAll()
            DispatchQueue.main.async {
                self.devices = []
                self.status = .connecting
                self.lastActivity = "Connecting to helper"
            }

            let socket = connectWithRetry()
            guard socket >= 0 else {
                publishFailure("Could not connect to impossible-helper")
                return
            }

            fd = socket
            startReader(fd: socket)
            send([
                "type": "scan",
                "services": serviceUUIDs,
                "options": ["kCBScanOptionAllowDuplicates": true],
            ])

            DispatchQueue.main.async {
                self.status = .scanning
                self.lastActivity = "Scanning"
            }
        }
    }

    func stop() {
        queue.async { [self] in
            inspectionTimeoutID += 1
            inspectionCompletion = nil
            pendingInspection = nil

            if fd >= 0 {
                send(["type": "stopScan"])
            }

            readSource?.cancel()
            readSource = nil

            if fd >= 0 {
                close(fd)
                fd = -1
            }

            readBuffer.removeAll()
            DispatchQueue.main.async {
                if self.status != .idle {
                    self.status = .idle
                    self.lastActivity = "Stopped"
                }
                self.inspectionProgress = CaptureInspectionProgress()
            }
        }
    }

    func inspectDevices(_ devices: [CapturedDevice], completion: @escaping ([MockDevice]) -> Void) {
        queue.async { [self] in
            guard fd >= 0 else {
                let fallback = devices.map { $0.makeMockDevice() }
                DispatchQueue.main.async {
                    completion(fallback)
                }
                return
            }

            send(["type": "stopScan"])
            inspectionTimeoutID += 1
            inspectionCompletion = completion
            inspectionDevices = devices
            inspectionResults = []
            inspectionIndex = 0
            inspectionServices = []
            pendingInspection = nil

            inspectNextDevice()
        }
    }

    private func connectWithRetry() -> Int32 {
        for attempt in 0..<15 {
            let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            if socket < 0 {
                return -1
            }

            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let pathBytes = captureSocketPath.utf8CString
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                let raw = UnsafeMutableRawPointer(ptr)
                pathBytes.withUnsafeBufferPointer { buffer in
                    raw.copyMemory(from: buffer.baseAddress!, byteCount: min(buffer.count, 104))
                }
            }

            let result = withUnsafePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    Darwin.connect(socket, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }

            if result == 0 {
                return socket
            }

            close(socket)
            if attempt < 14 {
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
        return -1
    }

    private func startReader(fd: Int32) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.readFromHelper(fd: fd)
        }
        source.setCancelHandler { }
        source.resume()
        readSource = source
    }

    private func readFromHelper(fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 2048)
        let count = Darwin.read(fd, &buffer, buffer.count)
        if count <= 0 {
            handleDisconnect()
            return
        }

        readBuffer.append(contentsOf: buffer[0..<count])
        while let newlineIndex = readBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = readBuffer[readBuffer.startIndex..<newlineIndex]
            readBuffer.removeSubrange(readBuffer.startIndex...newlineIndex)
            guard !lineData.isEmpty,
                  let message = try? JSONSerialization.jsonObject(with: Data(lineData)) as? [String: Any]
            else { continue }
            handleMessage(message)
        }
    }

    private func handleMessage(_ message: [String: Any]) {
        guard let type = message["type"] as? String else { return }
        switch type {
        case "didDiscover":
            handleDiscovery(message)
        case "didConnect":
            handleDidConnect(message)
        case "didFailConnect":
            handleDidFailConnect(message)
        case "didDisconnect":
            handleDidDisconnect(message)
        case "didDiscoverServices":
            handleDidDiscoverServices(message)
        case "didDiscoverCharacteristics":
            handleDidDiscoverCharacteristics(message)
        case "didDiscoverDescriptors":
            handleDidDiscoverDescriptors(message)
        case "didUpdateValue":
            handleDidUpdateValue(message)
        case "didUpdateDescriptorValue":
            handleDidUpdateDescriptorValue(message)
        default:
            break
        }
    }

    private func handleDiscovery(_ message: [String: Any]) {
        guard let id = message["id"] as? String else { return }
        let adv = message["adv"] as? [String: Any] ?? [:]
        let advertisedName = adv["kCBAdvDataLocalName"] as? String
        let name = (message["name"] as? String) ?? advertisedName ?? ""
        let rssi = (message["rssi"] as? NSNumber)?.intValue ?? 0
        let connectable = (adv["kCBAdvDataIsConnectable"] as? NSNumber)?.boolValue ?? true
        let serviceUUIDs = (adv["kCBAdvDataServiceUUIDs"] as? [String] ?? [])
            .map { $0.uppercased() }
            .sorted()

        let manufacturerData: Data?
        if let encoded = adv["kCBAdvDataManufacturerData"] as? String, !encoded.isEmpty {
            manufacturerData = Data(base64Encoded: encoded)
        } else {
            manufacturerData = nil
        }

        let now = Date()
        var device = devicesByID[id] ?? CapturedDevice(
            id: id,
            name: name,
            rssi: rssi,
            isConnectable: connectable,
            advertisedServiceUUIDs: serviceUUIDs,
            manufacturerData: manufacturerData,
            firstSeen: now,
            lastSeen: now,
            seenCount: 0
        )

        if !name.isEmpty {
            device.name = name
        }
        device.rssi = rssi
        device.isConnectable = connectable
        if !serviceUUIDs.isEmpty {
            device.advertisedServiceUUIDs = serviceUUIDs
        }
        if manufacturerData != nil {
            device.manufacturerData = manufacturerData
        }
        device.lastSeen = now
        device.seenCount += 1

        devicesByID[id] = device
        let snapshot = devicesByID.values.sorted(by: Self.isMoreInteresting)

        DispatchQueue.main.async {
            self.devices = snapshot
            self.lastActivity = "Captured \(snapshot.count) device\(snapshot.count == 1 ? "" : "s")"
        }
    }

    private func send(_ message: [String: Any]) {
        guard fd >= 0,
              let data = try? JSONSerialization.data(withJSONObject: message)
        else { return }

        var payload = data
        payload.append(UInt8(ascii: "\n"))
        payload.withUnsafeBytes { pointer in
            guard let baseAddress = pointer.baseAddress else { return }
            var written = 0
            while written < payload.count {
                let count = Darwin.write(fd, baseAddress.advanced(by: written), payload.count - written)
                if count <= 0 { break }
                written += count
            }
        }
    }

    private func handleDisconnect() {
        readSource?.cancel()
        readSource = nil
        if fd >= 0 {
            close(fd)
            fd = -1
        }
        if inspectionCompletion != nil {
            finishInspectionWithRemainingAdvertisementOnly()
        }
        DispatchQueue.main.async {
            if self.status == .scanning || self.status == .connecting {
                self.status = .idle
                self.lastActivity = "Helper disconnected"
            }
        }
    }

    private func publishFailure(_ message: String) {
        DispatchQueue.main.async {
            self.status = .failed(message)
            self.lastActivity = message
        }
    }

    private static func isMoreInteresting(_ lhs: CapturedDevice, _ rhs: CapturedDevice) -> Bool {
        if lhs.advertisedServiceUUIDs.count != rhs.advertisedServiceUUIDs.count {
            return lhs.advertisedServiceUUIDs.count > rhs.advertisedServiceUUIDs.count
        }
        if lhs.hasName != rhs.hasName {
            return lhs.hasName
        }
        if lhs.isConnectable != rhs.isConnectable {
            return lhs.isConnectable
        }
        if (lhs.manufacturerData != nil) != (rhs.manufacturerData != nil) {
            return lhs.manufacturerData != nil
        }
        if lhs.rssi != rhs.rssi {
            return lhs.rssi > rhs.rssi
        }
        return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
    }
}

private extension CaptureSession {
    struct DescriptorDraft {
        var id: String
        var uuid: String
        var value: Data?
    }

    struct CharacteristicDraft {
        var id: String
        var uuid: String
        var properties: UInt
        var value: Data?
        var descriptors: [DescriptorDraft] = []
    }

    struct ServiceDraft {
        var id: String
        var uuid: String
        var isPrimary: Bool
        var characteristics: [CharacteristicDraft] = []
    }

    enum PendingInspection {
        case connect(String)
        case services(String)
        case characteristics(String, Int)
        case descriptors(String, Int, Int)
        case readCharacteristic(String, Int, Int)
        case readDescriptor(String, Int, Int, Int)

        var deviceID: String {
            switch self {
            case .connect(let id),
                 .services(let id),
                 .characteristics(let id, _),
                 .descriptors(let id, _, _),
                 .readCharacteristic(let id, _, _),
                 .readDescriptor(let id, _, _, _):
                return id
            }
        }
    }

    func inspectNextDevice() {
        guard inspectionIndex < inspectionDevices.count else {
            finishInspection()
            return
        }

        let device = inspectionDevices[inspectionIndex]
        inspectionServices = []
        publishInspection(device: device, phase: device.isConnectable ? "Connecting" : "Advertisement only")

        guard device.isConnectable else {
            inspectionResults.append(device.makeMockDevice())
            inspectionIndex += 1
            inspectNextDevice()
            return
        }

        pendingInspection = .connect(device.id)
        send(["type": "connect", "id": device.id])
        scheduleInspectionTimeout(seconds: 5)
    }

    func handleDidConnect(_ message: [String: Any]) {
        guard case .connect(let id) = pendingInspection,
              message["id"] as? String == id
        else { return }

        cancelInspectionTimeout()
        publishInspection(phase: "Discovering services")
        pendingInspection = .services(id)
        send(["type": "discoverServices", "id": id, "services": []])
        scheduleInspectionTimeout(seconds: 8)
    }

    func handleDidFailConnect(_ message: [String: Any]) {
        guard case .connect(let id) = pendingInspection,
              message["id"] as? String == id
        else { return }

        cancelInspectionTimeout()
        appendAdvertisementOnlyAndContinue()
    }

    func handleDidDisconnect(_ message: [String: Any]) {
        guard let pendingInspection,
              message["id"] as? String == pendingInspection.deviceID
        else { return }

        cancelInspectionTimeout()
        if inspectionServices.isEmpty {
            appendAdvertisementOnlyAndContinue()
        } else {
            finalizeCurrentInspectedDevice()
        }
    }

    func handleDidDiscoverServices(_ message: [String: Any]) {
        guard case .services(let id) = pendingInspection,
              message["id"] as? String == id
        else { return }

        cancelInspectionTimeout()
        let services = message["services"] as? [[String: Any]] ?? []
        inspectionServices = services.compactMap { payload in
            guard let serviceID = payload["id"] as? String,
                  let uuid = payload["uuid"] as? String
            else { return nil }
            let primary = (payload["primary"] as? NSNumber)?.boolValue ?? true
            return ServiceDraft(id: serviceID, uuid: uuid, isPrimary: primary)
        }

        discoverCharacteristics(at: 0)
    }

    func discoverCharacteristics(at index: Int) {
        guard index < inspectionServices.count else {
            discoverDescriptors(serviceIndex: 0, characteristicIndex: 0)
            return
        }

        let service = inspectionServices[index]
        publishInspection(phase: "Discovering characteristics")
        pendingInspection = .characteristics(currentInspectionDeviceID, index)
        send([
            "type": "discoverCharacteristics",
            "id": currentInspectionDeviceID,
            "serviceId": service.id,
            "characteristics": [],
        ])
        scheduleInspectionTimeout(seconds: 8)
    }

    func handleDidDiscoverCharacteristics(_ message: [String: Any]) {
        guard case .characteristics(_, let serviceIndex) = pendingInspection,
              let serviceID = message["serviceId"] as? String,
              serviceIndex < inspectionServices.count,
              inspectionServices[serviceIndex].id == serviceID
        else { return }

        cancelInspectionTimeout()
        let characteristics = message["characteristics"] as? [[String: Any]] ?? []
        inspectionServices[serviceIndex].characteristics = characteristics.compactMap { payload in
            guard let characteristicID = payload["id"] as? String,
                  let uuid = payload["uuid"] as? String
            else { return nil }
            let properties = (payload["properties"] as? NSNumber)?.uintValue ?? 0
            return CharacteristicDraft(id: characteristicID, uuid: uuid, properties: properties)
        }

        discoverCharacteristics(at: serviceIndex + 1)
    }

    func discoverDescriptors(serviceIndex: Int, characteristicIndex: Int) {
        guard let next = nextCharacteristicPosition(startingAtService: serviceIndex, characteristic: characteristicIndex) else {
            readCharacteristics(serviceIndex: 0, characteristicIndex: 0)
            return
        }

        let characteristic = inspectionServices[next.service].characteristics[next.characteristic]
        publishInspection(phase: "Discovering descriptors")
        pendingInspection = .descriptors(currentInspectionDeviceID, next.service, next.characteristic)
        send([
            "type": "discoverDescriptors",
            "id": currentInspectionDeviceID,
            "characteristicId": characteristic.id,
        ])
        scheduleInspectionTimeout(seconds: 8)
    }

    func handleDidDiscoverDescriptors(_ message: [String: Any]) {
        guard case .descriptors(_, let serviceIndex, let characteristicIndex) = pendingInspection,
              serviceIndex < inspectionServices.count,
              characteristicIndex < inspectionServices[serviceIndex].characteristics.count,
              let characteristicID = message["characteristicId"] as? String,
              inspectionServices[serviceIndex].characteristics[characteristicIndex].id == characteristicID
        else { return }

        cancelInspectionTimeout()
        let descriptors = message["descriptors"] as? [[String: Any]] ?? []
        inspectionServices[serviceIndex].characteristics[characteristicIndex].descriptors = descriptors.compactMap { payload in
            guard let descriptorID = payload["id"] as? String,
                  let uuid = payload["uuid"] as? String
            else { return nil }
            return DescriptorDraft(id: descriptorID, uuid: uuid)
        }

        discoverDescriptors(serviceIndex: serviceIndex, characteristicIndex: characteristicIndex + 1)
    }

    func readCharacteristics(serviceIndex: Int, characteristicIndex: Int) {
        guard let next = nextReadableCharacteristicPosition(startingAtService: serviceIndex, characteristic: characteristicIndex) else {
            readDescriptors(serviceIndex: 0, characteristicIndex: 0, descriptorIndex: 0)
            return
        }

        let characteristic = inspectionServices[next.service].characteristics[next.characteristic]
        publishInspection(phase: "Reading values")
        pendingInspection = .readCharacteristic(currentInspectionDeviceID, next.service, next.characteristic)
        send([
            "type": "read",
            "id": currentInspectionDeviceID,
            "characteristicId": characteristic.id,
        ])
        scheduleInspectionTimeout(seconds: 6)
    }

    func handleDidUpdateValue(_ message: [String: Any]) {
        guard case .readCharacteristic(_, let serviceIndex, let characteristicIndex) = pendingInspection,
              serviceIndex < inspectionServices.count,
              characteristicIndex < inspectionServices[serviceIndex].characteristics.count,
              let characteristicID = message["characteristicId"] as? String,
              inspectionServices[serviceIndex].characteristics[characteristicIndex].id == characteristicID
        else { return }

        cancelInspectionTimeout()
        if (message["error"] as? String ?? "").isEmpty,
           let value = message["value"] as? String {
            inspectionServices[serviceIndex].characteristics[characteristicIndex].value = Data(base64Encoded: value)
        }

        readCharacteristics(serviceIndex: serviceIndex, characteristicIndex: characteristicIndex + 1)
    }

    func readDescriptors(serviceIndex: Int, characteristicIndex: Int, descriptorIndex: Int) {
        guard let next = nextDescriptorPosition(
            startingAtService: serviceIndex,
            characteristic: characteristicIndex,
            descriptor: descriptorIndex
        ) else {
            finalizeCurrentInspectedDevice()
            return
        }

        let descriptor = inspectionServices[next.service].characteristics[next.characteristic].descriptors[next.descriptor]
        publishInspection(phase: "Reading descriptors")
        pendingInspection = .readDescriptor(currentInspectionDeviceID, next.service, next.characteristic, next.descriptor)
        send([
            "type": "readDescriptor",
            "id": currentInspectionDeviceID,
            "descriptorId": descriptor.id,
        ])
        scheduleInspectionTimeout(seconds: 6)
    }

    func handleDidUpdateDescriptorValue(_ message: [String: Any]) {
        guard case .readDescriptor(_, let serviceIndex, let characteristicIndex, let descriptorIndex) = pendingInspection,
              serviceIndex < inspectionServices.count,
              characteristicIndex < inspectionServices[serviceIndex].characteristics.count,
              descriptorIndex < inspectionServices[serviceIndex].characteristics[characteristicIndex].descriptors.count,
              let descriptorID = message["descriptorId"] as? String,
              inspectionServices[serviceIndex].characteristics[characteristicIndex].descriptors[descriptorIndex].id == descriptorID
        else { return }

        cancelInspectionTimeout()
        if (message["error"] as? String ?? "").isEmpty,
           let value = message["valueB64"] as? String {
            inspectionServices[serviceIndex].characteristics[characteristicIndex].descriptors[descriptorIndex].value = Data(base64Encoded: value)
        }

        readDescriptors(serviceIndex: serviceIndex, characteristicIndex: characteristicIndex, descriptorIndex: descriptorIndex + 1)
    }

    func finalizeCurrentInspectedDevice() {
        let device = currentInspectionDevice.makeMockDevice()
        var enrichedDevice = device
        enrichedDevice.services = inspectionServices.map { service in
            MockService(
                uuid: service.uuid,
                isPrimary: service.isPrimary,
                characteristics: service.characteristics.map { characteristic in
                    MockCharacteristic(
                        uuid: characteristic.uuid,
                        properties: characteristic.properties,
                        value: characteristic.value,
                        descriptors: characteristic.descriptors.map { descriptor in
                            MockDescriptor(uuid: descriptor.uuid, value: descriptor.value)
                        }
                    )
                }
            )
        }

        inspectionResults.append(enrichedDevice)
        send(["type": "cancel", "id": currentInspectionDeviceID])
        inspectionIndex += 1
        pendingInspection = nil
        inspectNextDevice()
    }

    func appendAdvertisementOnlyAndContinue() {
        inspectionResults.append(currentInspectionDevice.makeMockDevice())
        inspectionIndex += 1
        pendingInspection = nil
        inspectNextDevice()
    }

    func finishInspection() {
        cancelInspectionTimeout()
        let results = inspectionResults
        let completion = inspectionCompletion
        inspectionCompletion = nil
        inspectionDevices = []
        inspectionResults = []
        inspectionIndex = 0
        inspectionServices = []
        pendingInspection = nil

        DispatchQueue.main.async {
            self.inspectionProgress = CaptureInspectionProgress()
            completion?(results)
        }
    }

    func finishInspectionWithRemainingAdvertisementOnly() {
        cancelInspectionTimeout()
        if inspectionIndex < inspectionDevices.count {
            let remaining = inspectionDevices[inspectionIndex...].map { $0.makeMockDevice() }
            inspectionResults.append(contentsOf: remaining)
        }
        finishInspection()
    }

    func handleInspectionTimeout() {
        guard pendingInspection != nil else { return }
        switch pendingInspection {
        case .connect, .services:
            appendAdvertisementOnlyAndContinue()
        case .characteristics(_, let serviceIndex):
            discoverCharacteristics(at: serviceIndex + 1)
        case .descriptors(_, let serviceIndex, let characteristicIndex):
            discoverDescriptors(serviceIndex: serviceIndex, characteristicIndex: characteristicIndex + 1)
        case .readCharacteristic(_, let serviceIndex, let characteristicIndex):
            readCharacteristics(serviceIndex: serviceIndex, characteristicIndex: characteristicIndex + 1)
        case .readDescriptor(_, let serviceIndex, let characteristicIndex, let descriptorIndex):
            readDescriptors(serviceIndex: serviceIndex, characteristicIndex: characteristicIndex, descriptorIndex: descriptorIndex + 1)
        case .none:
            break
        }
    }

    func scheduleInspectionTimeout(seconds: TimeInterval) {
        cancelInspectionTimeout()
        inspectionTimeoutID += 1
        let timeoutID = inspectionTimeoutID
        queue.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.inspectionTimeoutID == timeoutID else { return }
            self.handleInspectionTimeout()
        }
    }

    func cancelInspectionTimeout() {
        inspectionTimeoutID += 1
    }

    func publishInspection(device: CapturedDevice? = nil, phase: String) {
        let current = device ?? currentInspectionDevice
        DispatchQueue.main.async {
            self.inspectionProgress = CaptureInspectionProgress(
                isActive: true,
                currentIndex: self.inspectionIndex,
                total: self.inspectionDevices.count,
                deviceName: current.displayName,
                phase: phase
            )
        }
    }

    var currentInspectionDevice: CapturedDevice {
        inspectionDevices[min(inspectionIndex, max(inspectionDevices.count - 1, 0))]
    }

    var currentInspectionDeviceID: String {
        currentInspectionDevice.id
    }

    func nextCharacteristicPosition(startingAtService serviceIndex: Int, characteristic characteristicIndex: Int) -> (service: Int, characteristic: Int)? {
        guard !inspectionServices.isEmpty else { return nil }
        guard serviceIndex < inspectionServices.count else { return nil }
        for service in serviceIndex..<inspectionServices.count {
            let startCharacteristic = service == serviceIndex ? characteristicIndex : 0
            if startCharacteristic < inspectionServices[service].characteristics.count {
                return (service, startCharacteristic)
            }
        }
        return nil
    }

    func nextReadableCharacteristicPosition(startingAtService serviceIndex: Int, characteristic characteristicIndex: Int) -> (service: Int, characteristic: Int)? {
        guard !inspectionServices.isEmpty else { return nil }
        guard serviceIndex < inspectionServices.count else { return nil }
        for service in serviceIndex..<inspectionServices.count {
            let startCharacteristic = service == serviceIndex ? characteristicIndex : 0
            for characteristic in startCharacteristic..<inspectionServices[service].characteristics.count {
                if inspectionServices[service].characteristics[characteristic].properties & 0x02 != 0 {
                    return (service, characteristic)
                }
            }
        }
        return nil
    }

    func nextDescriptorPosition(
        startingAtService serviceIndex: Int,
        characteristic characteristicIndex: Int,
        descriptor descriptorIndex: Int
    ) -> (service: Int, characteristic: Int, descriptor: Int)? {
        guard !inspectionServices.isEmpty else { return nil }
        guard serviceIndex < inspectionServices.count else { return nil }
        for service in serviceIndex..<inspectionServices.count {
            let startCharacteristic = service == serviceIndex ? characteristicIndex : 0
            for characteristic in startCharacteristic..<inspectionServices[service].characteristics.count {
                let startDescriptor = service == serviceIndex && characteristic == characteristicIndex ? descriptorIndex : 0
                if startDescriptor < inspectionServices[service].characteristics[characteristic].descriptors.count {
                    return (service, characteristic, startDescriptor)
                }
            }
        }
        return nil
    }
}
