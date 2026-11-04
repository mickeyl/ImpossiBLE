import CoreBluetooth
@testable import ImpossiBLE
import XCTest

#if targetEnvironment(simulator)
/// Reconnects from didDisconnectPeripheral:, as an app that keeps a link up does.
private final class ReconnectingDelegate: NSObject, CBCentralManagerDelegate {
    private let lock = NSLock()
    private var _discovered: [CBPeripheral] = []
    private var _reconnects = 0

    var discovered: [CBPeripheral] {
        lock.lock()
        defer { lock.unlock() }
        return _discovered
    }

    var reconnects: Int {
        lock.lock()
        defer { lock.unlock() }
        return _reconnects
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {}

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        lock.lock()
        _discovered.append(peripheral)
        lock.unlock()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        central.connect(peripheral)
        lock.lock()
        _reconnects += 1
        lock.unlock()
    }
}

final class ReconnectFromDisconnectTests: XCTestCase {
    func testReconnectFromTheDisconnectCallbackStillGetsEvents() throws {
        let provider = try FakeProvider.shared()
        let delegate = ReconnectingDelegate()
        let central = CBCentralManager(delegate: delegate, queue: nil)
        XCTAssertTrue(waitUntil { central.state == .poweredOn })
        provider.reset()
        central.scanForPeripherals(withServices: nil)
        XCTAssertNotNil(provider.next("scan"))
        let uuid = UUID()
        let id = uuid.uuidString
        provider.send(["type": "didDiscover", "id": id, "name": "Fake", "rssi": -60,
                       "adv": ["kCBAdvDataServiceUUIDs": ["180D"], "kCBAdvDataIsConnectable": true]])
        XCTAssertTrue(waitUntil { delegate.discovered.contains { $0.identifier == uuid } })
        central.stopScan()
        let peripheral = try XCTUnwrap(delegate.discovered.first { $0.identifier == uuid })

        central.connect(peripheral)
        XCTAssertNotNil(provider.next("connect"))
        provider.send(["type": "didConnect", "id": id])
        XCTAssertTrue(waitUntil { peripheral.state == .connected })

        provider.send(["type": "didDisconnect", "id": id, "error": ""])
        XCTAssertTrue(waitUntil { delegate.reconnects == 1 })
        XCTAssertNotNil(provider.next("connect"))
        provider.send(["type": "didConnect", "id": id])
        XCTAssertTrue(waitUntil { peripheral.state == .connected })

        peripheral.discoverServices(nil)
        XCTAssertNotNil(provider.next("discoverServices"))
        provider.send(["type": "didDiscoverServices", "id": id, "error": "",
                       "services": [["id": "s1", "uuid": "180D", "primary": true]]])
        XCTAssertTrue(waitUntil { peripheral.services?.isEmpty == false },
                      "services discovered after the reconnect were dropped")
    }
}
#endif
