import SwiftUI
import AppKit

@MainActor
private final class MockAppRuntime {
    let store: MockStore
    let server: MockServer
    let forwarder: ForwarderController
    let modeController: ProviderModeController
    let statusBar: StatusBarController

    init() {
        store = MockStore()
        server = MockServer(autoStart: false)
        forwarder = ForwarderController()
        // Creating the controller restores the persisted provider mode.
        modeController = ProviderModeController(server: server, forwarder: forwarder)
        statusBar = StatusBarController(store: store, server: server, forwarder: forwarder, modeController: modeController)

        server.store = store
    }
}

/// Stops the passthrough helper as the app terminates, unless the user opted to
/// keep it running. Handles every quit path (footer button and ⌘Q), not just the
/// in-view button.
final class MockAppDelegate: NSObject, NSApplicationDelegate {
    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !AppPreferences.keepHelperRunningOnQuit,
              let forwarder = MockApp.retainedRuntime?.forwarder,
              forwarder.isRunning
        else {
            return .terminateNow
        }

        forwarder.stop {
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
    @StateObject private var forwarder: ForwarderController
    @StateObject private var modeController: ProviderModeController
    @StateObject private var statusBar: StatusBarController

    init() {
        let runtime = Self.retainedRuntime ?? MockAppRuntime()
        Self.retainedRuntime = runtime

        _store = StateObject(wrappedValue: runtime.store)
        _server = StateObject(wrappedValue: runtime.server)
        _forwarder = StateObject(wrappedValue: runtime.forwarder)
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
