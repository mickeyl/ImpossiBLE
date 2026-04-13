import SwiftUI
import AppKit

/// Opens and manages standalone NSWindows for device editing.
/// This bypasses SwiftUI's `openWindow` which doesn't work from MenuBarExtra.
final class EditorWindowController {
    static let shared = EditorWindowController()

    private var windows: [UUID: NSWindow] = [:]

    func openEditor(for deviceId: UUID, store: MockStore) {
        if let existing = windows[deviceId], existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostView = DeviceEditorWindowContent(deviceId: deviceId, store: store) { [weak self] in
            self?.windows[deviceId]?.close()
            self?.windows.removeValue(forKey: deviceId)
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        let deviceName = store.devices.first { $0.id == deviceId }?.name ?? "Device"
        window.title = "Edit: \(deviceName)"
        window.contentView = NSHostingView(rootView: hostView)
        window.center()
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("DeviceEditor-\(deviceId.uuidString.prefix(8))")
        windows[deviceId] = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func closeAll() {
        for (_, window) in windows {
            window.close()
        }
        windows.removeAll()
    }
}

struct DeviceEditorWindowContent: View {
    let deviceId: UUID
    @ObservedObject var store: MockStore
    var onClose: () -> Void

    var body: some View {
        if let idx = store.devices.firstIndex(where: { $0.id == deviceId }) {
            DeviceEditorView(device: $store.devices[idx], onSave: { store.save() })
        } else {
            VStack(spacing: 12) {
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("Device no longer exists")
                    .font(.headline)
                Button("Close") { onClose() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
