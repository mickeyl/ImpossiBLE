import CoreBluetooth
import Foundation
import XCTest

#if targetEnvironment(simulator)
/// Stands in for the Mac provider on ImpossiBLE's socket, so a test can see
/// what the library sends and answer it.
final class FakeProvider {
    static let path = "/tmp/impossible.sock"

    private static var instance: FakeProvider?

    /// The library connects once per process, so tests share one provider.
    static func shared() throws -> FakeProvider {
        if let instance = instance {
            return instance
        }
        if providerIsListening() {
            throw XCTSkip("A provider is already serving \(path)")
        }
        let provider = try FakeProvider()
        instance = provider
        return provider
    }

    private let listener: Int32
    private let condition = NSCondition()
    private var client: Int32 = -1
    private var received: [[String: Any]] = []

    private init() throws {
        unlink(Self.path)
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = Self.address()
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard listener >= 0, bound == 0, listen(listener, 1) == 0 else {
            throw XCTSkip("Can't listen on \(Self.path): errno \(errno)")
        }
        let thread = Thread { [unowned self] in self.serve() }
        thread.start()
    }

    /// Drops what the library has sent so far.
    func reset() {
        condition.lock()
        received.removeAll()
        condition.unlock()
    }

    /// Waits for the library to send a message of this type, and takes it.
    func next(_ type: String, timeout: TimeInterval = 5) -> [String: Any]? {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while true {
            if let index = received.firstIndex(where: { $0["type"] as? String == type }) {
                return received.remove(at: index)
            }
            if !condition.wait(until: deadline) {
                return nil
            }
        }
    }

    func send(_ message: [String: Any]) {
        condition.lock()
        let fd = client
        condition.unlock()
        guard fd >= 0, var data = try? JSONSerialization.data(withJSONObject: message) else {
            XCTFail("Can't send \(message)")
            return
        }
        data.append(0x0A)
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    private func serve() {
        while true {
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { return }
            condition.lock()
            client = fd
            condition.unlock()
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = read(fd, &chunk, chunk.count)
                guard count > 0 else { break }
                buffer.append(contentsOf: chunk[0..<count])
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<newline]
                    buffer.removeSubrange(buffer.startIndex...newline)
                    if let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                        condition.lock()
                        received.append(message)
                        condition.broadcast()
                        condition.unlock()
                    }
                }
            }
            close(fd)
        }
    }

    private static func address() -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            path.utf8CString.withUnsafeBytes { buffer.copyMemory(from: $0) }
        }
        return addr
    }

    private static func providerIsListening() -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = address()
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
    }
}

final class RecordingCentralDelegate: NSObject, CBCentralManagerDelegate {
    private let lock = NSLock()
    private var _discovered: [CBPeripheral] = []
    private var _disconnected: [UUID] = []

    var discovered: [CBPeripheral] {
        lock.lock()
        defer { lock.unlock() }
        return _discovered
    }

    var disconnected: [UUID] {
        lock.lock()
        defer { lock.unlock() }
        return _disconnected
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {}

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        lock.lock()
        _discovered.append(peripheral)
        lock.unlock()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        lock.lock()
        _disconnected.append(peripheral.identifier)
        lock.unlock()
    }
}

func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline {
            return false
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    return true
}

/// A central connected to the fake provider, with a peripheral advertising
/// these services, as written in the advert.
func discoverPeripheral(
    provider: FakeProvider,
    central: CBCentralManager,
    delegate: RecordingCentralDelegate,
    scanningFor filter: [CBUUID]?,
    advertising services: [String]
) -> CBPeripheral? {
    guard waitUntil({ central.state == .poweredOn }) else {
        XCTFail("Central never powered on")
        return nil
    }
    provider.reset()
    central.scanForPeripherals(withServices: filter)
    guard provider.next("scan") != nil else {
        XCTFail("No scan request")
        return nil
    }
    let id = UUID()
    provider.send([
        "type": "didDiscover",
        "id": id.uuidString,
        "name": "Fake",
        "rssi": -60,
        "adv": ["kCBAdvDataServiceUUIDs": services, "kCBAdvDataIsConnectable": true],
    ])
    _ = waitUntil(timeout: 2) { delegate.discovered.contains { $0.identifier == id } }
    central.stopScan()
    return delegate.discovered.first { $0.identifier == id }
}
#endif
