import CoreBluetooth
@testable import ImpossiBLE
import XCTest

#if targetEnvironment(simulator)
final class ServiceUUIDFormTests: XCTestCase {
    func testScanForLongFormFindsShortFormAdvert() throws {
        let provider = try FakeProvider.shared()
        let delegate = RecordingCentralDelegate()
        let central = CBCentralManager(delegate: delegate, queue: nil)

        let peripheral = discoverPeripheral(
            provider: provider, central: central, delegate: delegate,
            scanningFor: [CBUUID(string: "00004024-0000-1000-8000-00805F9B34FB")],
            advertising: ["4024"]
        )

        XCTAssertNotNil(peripheral)
    }

    func testScanForShortFormFindsLongFormAdvert() throws {
        let provider = try FakeProvider.shared()
        let delegate = RecordingCentralDelegate()
        let central = CBCentralManager(delegate: delegate, queue: nil)

        let peripheral = discoverPeripheral(
            provider: provider, central: central, delegate: delegate,
            scanningFor: [CBUUID(string: "4024")],
            advertising: ["00004024-0000-1000-8000-00805F9B34FB"]
        )

        XCTAssertNotNil(peripheral)
    }

    func testScanStillSkipsOtherServices() throws {
        let provider = try FakeProvider.shared()
        let delegate = RecordingCentralDelegate()
        let central = CBCentralManager(delegate: delegate, queue: nil)

        let peripheral = discoverPeripheral(
            provider: provider, central: central, delegate: delegate,
            scanningFor: [CBUUID(string: "00004024-0000-1000-8000-00805F9B34FB")],
            advertising: ["4025"]
        )

        XCTAssertNil(peripheral)
    }
}
#endif
