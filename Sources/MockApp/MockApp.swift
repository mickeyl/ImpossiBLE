import SwiftUI
import AppKit

@MainActor
private final class MockAppRuntime {
    let store: MockStore
    let server: MockServer
    let forwarder: ForwarderController
    let statusBar: StatusBarController

    init() {
        store = MockStore()
        server = MockServer(autoStart: false)
        forwarder = ForwarderController()
        statusBar = StatusBarController(store: store, server: server, forwarder: forwarder)

        server.store = store
    }
}

@main
struct MockApp: App {
    private static var retainedRuntime: MockAppRuntime?

    @StateObject private var store: MockStore
    @StateObject private var server: MockServer
    @StateObject private var forwarder: ForwarderController
    @StateObject private var statusBar: StatusBarController

    init() {
        let runtime = Self.retainedRuntime ?? MockAppRuntime()
        Self.retainedRuntime = runtime

        _store = StateObject(wrappedValue: runtime.store)
        _server = StateObject(wrappedValue: runtime.server)
        _forwarder = StateObject(wrappedValue: runtime.forwarder)
        _statusBar = StateObject(wrappedValue: runtime.statusBar)

        NSApplication.shared.setActivationPolicy(.accessory)
        Self.restorePersistedMode(server: runtime.server, forwarder: runtime.forwarder)
    }

    private static func restorePersistedMode(server: MockServer, forwarder: ForwarderController) {
        switch MockProviderMode.persisted {
            case .off:
                server.stop()
                forwarder.stop()
            case .mock:
                forwarder.stop {
                    server.start()
                }
            case .passthrough:
                server.stop {
                    forwarder.start()
                }
        }
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
