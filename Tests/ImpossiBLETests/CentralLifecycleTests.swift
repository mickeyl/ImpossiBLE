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

    func testStateUpdatesArriveOnTheCentralsQueue() {
        let key = DispatchSpecificKey<Bool>()
        let queue = DispatchQueue(label: "impossible.tests.central.queue")
        queue.setSpecific(key: key, value: true)
        let delegate = QueueRecordingDelegate(key: key)

        let central = CBCentralManager(delegate: delegate, queue: queue, options: nil)
        queue.sync {}
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        queue.sync {}

        XCTAssertFalse(delegate.onQueue.isEmpty)
        XCTAssertEqual(delegate.onQueue.filter { !$0 }.count, 0, "a state update arrived off the central's queue")
        _ = central
    }
}

private final class CentralDelegate: NSObject, CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {}
}

private final class QueueRecordingDelegate: NSObject, CBCentralManagerDelegate {
    let key: DispatchSpecificKey<Bool>
    private let lock = NSLock()
    private var calls: [Bool] = []

    init(key: DispatchSpecificKey<Bool>) {
        self.key = key
    }

    var onQueue: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let isOnQueue = DispatchQueue.getSpecific(key: key) == true
        lock.lock()
        calls.append(isOnQueue)
        lock.unlock()
    }
}
#endif
