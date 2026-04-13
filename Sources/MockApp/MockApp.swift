import SwiftUI
import AppKit

@main
struct MockApp: App {
    @StateObject private var store = MockStore()
    @StateObject private var server = MockServer()

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            MockMenuContent(store: store, server: server)
                .frame(width: 360, height: 520)
        } label: {
            Image(nsImage: FontAwesome.brandImage(
                FontAwesome.bluetoothB,
                size: 16,
                active: server.trafficActive
            ))
            .accessibilityLabel("ImpossiBLE Mock")
        }
        .menuBarExtraStyle(.window)

        WindowGroup("Device Editor", for: UUID.self) { $deviceId in
            NavigationStack {
                DeviceEditorWindowContent(deviceId: deviceId, store: store)
            }
            .background(DeviceEditorWindowActivator())
            .frame(minWidth: 520, minHeight: 640)
        }
        .defaultSize(width: 520, height: 640)
    }
}
