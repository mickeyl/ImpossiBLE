import CoreBluetooth
@testable import ImpossiBLE
import XCTest

#if targetEnvironment(simulator)
final class RetrievePeripheralsTests: XCTestCase {
    private let knownPeripheralsKey = "ImpossiBLE.knownPeripherals"

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: knownPeripheralsKey)
        super.tearDown()
    }

    func testRetrievesPeripheralSeenInAnEarlierLaunch() {
        let id = UUID()
        UserDefaults.standard.set([id.uuidString: "Fake"], forKey: knownPeripheralsKey)
        let central = CBCentralManager(delegate: RecordingCentralDelegate(), queue: nil)

        let peripherals = central.retrievePeripherals(withIdentifiers: [id])

        XCTAssertEqual(peripherals.map(\.identifier), [id])
        XCTAssertEqual(peripherals.first?.name, "Fake")
    }

    func testRetrievesNothingForUnknownIdentifier() {
        let central = CBCentralManager(delegate: RecordingCentralDelegate(), queue: nil)

        XCTAssertTrue(central.retrievePeripherals(withIdentifiers: [UUID()]).isEmpty)
    }

    func testDiscoveryIsRememberedForLaterLaunches() throws {
        let provider = try FakeProvider.shared()
        let delegate = RecordingCentralDelegate()
        let central = CBCentralManager(delegate: delegate, queue: nil)

        let peripheral = try XCTUnwrap(discoverPeripheral(
            provider: provider, central: central, delegate: delegate,
            scanningFor: nil, advertising: ["180D"]
        ))

        let known = UserDefaults.standard.dictionary(forKey: knownPeripheralsKey)
        XCTAssertEqual(known?[peripheral.identifier.uuidString] as? String, "Fake")
    }
}
#endif
