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
            Label("ImpossiBLE Mock", systemImage: "antenna.radiowaves.left.and.right")
        }
        .menuBarExtraStyle(.window)
    }
}
