import SwiftUI
import AppKit

@main
struct MockApp: App {
    @StateObject private var store: MockStore
    @StateObject private var server: MockServer
    @StateObject private var forwarder: ForwarderController
    @StateObject private var statusBar: StatusBarController

    init() {
        let store = MockStore()
        let server = MockServer(autoStart: false)
        let forwarder = ForwarderController()
        let statusBar = StatusBarController(store: store, server: server, forwarder: forwarder)

        server.store = store

        _store = StateObject(wrappedValue: store)
        _server = StateObject(wrappedValue: server)
        _forwarder = StateObject(wrappedValue: forwarder)
        _statusBar = StateObject(wrappedValue: statusBar)

        NSApplication.shared.setActivationPolicy(.accessory)
        Self.restorePersistedMode(server: server, forwarder: forwarder)
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
