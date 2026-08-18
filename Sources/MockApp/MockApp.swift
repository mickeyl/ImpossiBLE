import SwiftUI
import AppKit
import SimBridgeShell

@MainActor
private final class MockAppRuntime {
    let store: MockStore
    let server: MockServer
    let modeController: ModeTransitionController<ProviderMode>
    let statusBar: StatusBarController

    init() {
        store = MockStore()
        let server = MockServer(autoStart: false)
        self.server = server
        // Creating the controller restores the persisted provider mode. Mode
        // switches always bounce through a stop so a connected client observes
        // a disconnect instead of silently changing provider behavior.
        modeController = ModeTransitionController(
            initial: ProviderMode.persisted(legacyServerEnabledKey: "ServerEnabled"),
            persist: { $0.persist() }
        ) { mode, completion in
            switch mode {
                case .off:
                    server.stop(completion: completion)
                case .mock:
                    server.stop {
                        server.start(mode: .mock, completion: completion)
                    }
                case .passthrough:
                    server.stop {
                        server.start(mode: .passthrough, completion: completion)
                    }
            }
        }
        statusBar = StatusBarController(store: store, server: server, modeController: modeController)

        server.store = store
    }
}

/// Shuts the socket server down before the process exits so the socket file is
/// unlinked cleanly. Handles every quit path (footer button and ⌘Q).
final class MockAppDelegate: NSObject, NSApplicationDelegate {
    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let server = MockApp.retainedRuntime?.server else {
            return .terminateNow
        }

        server.stop {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct MockApp: App {
    fileprivate static var retainedRuntime: MockAppRuntime?

    @NSApplicationDelegateAdaptor(MockAppDelegate.self) private var appDelegate

    @StateObject private var store: MockStore
    @StateObject private var server: MockServer
    @StateObject private var modeController: ModeTransitionController<ProviderMode>
    @StateObject private var statusBar: StatusBarController

    init() {
        let runtime = Self.retainedRuntime ?? MockAppRuntime()
        Self.retainedRuntime = runtime

        _store = StateObject(wrappedValue: runtime.store)
        _server = StateObject(wrappedValue: runtime.server)
        _modeController = StateObject(wrappedValue: runtime.modeController)
        _statusBar = StateObject(wrappedValue: runtime.statusBar)

        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
