import SwiftUI
import AppKit

@main
struct MockApp: App {
    @StateObject private var store = MockStore()
    @StateObject private var server = MockServer()
    @StateObject private var forwarder = ForwarderController()

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    private var menuBarMode: FontAwesome.MenuBarMode {
        if server.status != .stopped { return .mock }
        if case .running = forwarder.status { return .passthrough }
        return .off
    }

    var body: some Scene {
        MenuBarExtra {
            MockMenuContent(store: store, server: server, forwarder: forwarder)
                .frame(width: 360, height: 580)
        } label: {
            Image(nsImage: FontAwesome.brandImage(
                FontAwesome.bluetoothB,
                size: 16,
                active: server.trafficActive,
                mode: menuBarMode
            ))
            .accessibilityLabel("ImpossiBLE Mock")
        }
        .menuBarExtraStyle(.window)

        WindowGroup("Device Editor", for: UUID.self) { $deviceId in
            NavigationStack {
                DeviceEditorWindowContent(deviceId: deviceId, store: store)
            }
            .background(DeviceEditorWindowActivator())
            .frame(minWidth: 720, minHeight: 760)
        }
        .defaultSize(width: 760, height: 820)
    }
}
