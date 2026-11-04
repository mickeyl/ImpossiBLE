import CoreBluetooth
@testable import ImpossiBLE
import XCTest

#if targetEnvironment(simulator)
private final class ErrorRecordingDelegate: NSObject, CBCentralManagerDelegate {
    private let lock = NSLock()
    private var _discovered: [CBPeripheral] = []
    private var _disconnectErrors: [NSError?] = []

    var discovered: [CBPeripheral] {
        lock.lock()
        defer { lock.unlock() }
        return _discovered
    }

    var disconnectErrors: [NSError?] {
        lock.lock()
        defer { lock.unlock() }
        return _disconnectErrors
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {}

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        lock.lock()
        _discovered.append(peripheral)
        lock.unlock()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        lock.lock()
        _disconnectErrors.append(error as NSError?)
        lock.unlock()
    }
}

final class ConnectionErrorTests: XCTestCase {
    func testDisconnectCarriesTheProvidersErrorDomainAndCode() throws {
        let provider = try FakeProvider.shared()
        let delegate = ErrorRecordingDelegate()
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

        provider.send(["type": "didDisconnect", "id": id,
                       "error": "The specified device has disconnected from us.",
                       "errorDomain": CBErrorDomain, "errorCode": CBError.Code.peripheralDisconnected.rawValue])
        XCTAssertTrue(waitUntil { delegate.disconnectErrors.count == 1 })
        let error = try XCTUnwrap(delegate.disconnectErrors.first ?? nil)
        XCTAssertEqual(error.domain, CBErrorDomain)
        XCTAssertEqual(error.code, CBError.Code.peripheralDisconnected.rawValue)
    }
}
#endif
