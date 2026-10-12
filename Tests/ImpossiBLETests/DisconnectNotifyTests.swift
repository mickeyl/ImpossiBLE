import CoreBluetooth
@testable import ImpossiBLE
import XCTest

#if targetEnvironment(simulator)
final class DisconnectNotifyTests: XCTestCase {
    func testDisconnectEndsSubscriptions() throws {
        let provider = try FakeProvider.shared()
        let delegate = RecordingCentralDelegate()
        let central = CBCentralManager(delegate: delegate, queue: nil)
        let peripheral = try XCTUnwrap(discoverPeripheral(
            provider: provider, central: central, delegate: delegate,
            scanningFor: nil, advertising: ["180D"]
        ))
        let id = peripheral.identifier.uuidString

        central.connect(peripheral)
        XCTAssertNotNil(provider.next("connect"))
        provider.send(["type": "didConnect", "id": id])
        XCTAssertTrue(waitUntil { peripheral.state == .connected })

        peripheral.discoverServices(nil)
        XCTAssertNotNil(provider.next("discoverServices"))
        provider.send(["type": "didDiscoverServices", "id": id, "error": "",
                       "services": [["id": "s1", "uuid": "180D", "primary": true]]])
        XCTAssertTrue(waitUntil { peripheral.services?.isEmpty == false })
        let service = try XCTUnwrap(peripheral.services?.first)

        peripheral.discoverCharacteristics(nil, for: service)
        XCTAssertNotNil(provider.next("discoverCharacteristics"))
        provider.send(["type": "didDiscoverCharacteristics", "id": id, "serviceId": "s1", "error": "",
                       "characteristics": [["id": "c1", "uuid": "2A37", "properties": 0x10]]])
        XCTAssertTrue(waitUntil { service.characteristics?.isEmpty == false })
        let characteristic = try XCTUnwrap(service.characteristics?.first)

        peripheral.setNotifyValue(true, for: characteristic)
        XCTAssertNotNil(provider.next("setNotify"))
        provider.send(["type": "didUpdateNotification", "id": id, "characteristicId": "c1",
                       "enabled": true, "error": ""])
        XCTAssertTrue(waitUntil { characteristic.isNotifying })

        provider.send(["type": "didDisconnect", "id": id, "error": ""])
        XCTAssertTrue(waitUntil { delegate.disconnected.contains(peripheral.identifier) })

        XCTAssertEqual(peripheral.state, .disconnected)
        XCTAssertFalse(characteristic.isNotifying)
    }
}
#endif
