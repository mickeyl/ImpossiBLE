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

    func testEveryInitializerReportsTheInitialStateTheSameNumberOfTimes() {
        let withOptions = CountingDelegate()
        let withOptionsQueue = DispatchQueue(label: "impossible.tests.central.options")
        let a = CBCentralManager(delegate: withOptions, queue: withOptionsQueue, options: nil)

        let withoutOptions = CountingDelegate()
        let withoutOptionsQueue = DispatchQueue(label: "impossible.tests.central.nooptions")
        let b = CBCentralManager(delegate: withoutOptions, queue: withoutOptionsQueue)

        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        withOptionsQueue.sync {}
        withoutOptionsQueue.sync {}

        XCTAssertGreaterThan(withOptions.count, 0)
        XCTAssertEqual(withoutOptions.count, withOptions.count)
        _ = (a, b)
    }
}

private final class CentralDelegate: NSObject, CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {}
}

private final class CountingDelegate: NSObject, CBCentralManagerDelegate {
    private let lock = NSLock()
    private var updates = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return updates
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        lock.lock()
        updates += 1
        lock.unlock()
    }
}
#endif
