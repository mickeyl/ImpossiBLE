import CoreBluetooth
@testable import ImpossiBLE
import XCTest

#if targetEnvironment(simulator)
final class CentralLifecycleTests: XCTestCase {
    func testShortLivedCentralDeallocatesAfterScanLifecycleWhenAnotherCentralIsCurrent() {
        let survivorDelegate = CentralDelegate()
        let survivorQueue = DispatchQueue(label: "impossible.tests.central.survivor")
        let survivor = CBCentralManager(delegate: survivorDelegate, queue: survivorQueue)
        survivorQueue.sync {}

        let ephemeralDelegate = CentralDelegate()
        let ephemeralQueue = DispatchQueue(label: "impossible.tests.central.ephemeral")
        weak var releasedCentral: CBCentralManager?

        autoreleasepool {
            var central: CBCentralManager? = CBCentralManager(delegate: ephemeralDelegate, queue: ephemeralQueue)
            releasedCentral = central

            central?.scanForPeripherals(
                withServices: nil,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
            XCTAssertEqual(central?.isScanning, true)

            central?.stopScan()
            XCTAssertEqual(central?.isScanning, false)

            survivor.scanForPeripherals(
                withServices: nil,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
            survivor.stopScan()

            central = nil
        }

        ephemeralQueue.sync {}
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))

        XCTAssertNil(releasedCentral)
        _ = survivor
        _ = survivorDelegate
        _ = ephemeralDelegate
    }
}

private final class CentralDelegate: NSObject, CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {}
}
#endif
