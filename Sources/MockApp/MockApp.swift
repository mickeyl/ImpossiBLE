import SwiftUI

@main
struct MockApp: App {
    @StateObject private var store = MockStore()
    @StateObject private var server = MockServer()

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
    }
}
