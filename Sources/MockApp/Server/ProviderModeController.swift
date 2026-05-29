import Foundation

/// Single source of truth for the selected provider mode.
///
/// The UI binds to `mode` so the picker reflects the user's choice immediately,
/// rather than inferring it from the live — and, mid-transition, briefly
/// inconsistent — state of the mock server and the passthrough helper. Without
/// this, a slow daemon launch would make the segmented control snap back to the
/// previous mode until the next status poll caught up.
///
/// Transitions are serialized: while one is in flight, only the most recent
/// requested mode is remembered and applied once the current transition
/// finishes, so rapid clicks converge on the last choice instead of racing.
///
/// Mutations happen on the main thread (the SwiftUI caller and the server /
/// forwarder completion handlers all hop to main), mirroring `ForwarderController`.
final class ProviderModeController: ObservableObject {
    @Published private(set) var mode: MockProviderMode
    @Published private(set) var isSwitching = false

    private let server: MockServer
    private let forwarder: ForwarderController
    private var queuedMode: MockProviderMode?

    init(server: MockServer, forwarder: ForwarderController) {
        self.server = server
        self.forwarder = forwarder
        self.mode = MockProviderMode.persisted
        applyTransition(to: mode)
    }

    func select(_ newMode: MockProviderMode) {
        mode = newMode
        newMode.persist()
        applyTransition(to: newMode)
    }

    private func applyTransition(to target: MockProviderMode) {
        guard !isSwitching else {
            queuedMode = target
            return
        }

        isSwitching = true
        runTransition(to: target) { [weak self] in
            guard let self else { return }
            self.isSwitching = false
            if let queued = self.queuedMode, queued != target {
                self.queuedMode = nil
                self.applyTransition(to: queued)
            } else {
                self.queuedMode = nil
            }
        }
    }

    private func runTransition(to target: MockProviderMode, completion: @escaping () -> Void) {
        switch target {
            case .off:
                server.stop {
                    self.forwarder.stop(completion: completion)
                }
            case .mock:
                forwarder.stop {
                    self.server.start(completion: completion)
                }
            case .passthrough:
                server.stop {
                    self.forwarder.start(completion: completion)
                }
        }
    }
}
