import AppKit
import Combine
import SwiftUI
import SimBridgeServer
import SimBridgeShell

/// Owns the app's menu bar presence and its auxiliary windows. The status item
/// and control panel machinery come from SimBridgeShell's
/// `StatusItemPanelController`; this class contributes the icon, the panel
/// content, and the capture/device-editor document windows.
@MainActor
final class StatusBarController: NSObject, ObservableObject, NSWindowDelegate {
    private let store: MockStore
    private let server: MockServer
    private let modeController: ModeTransitionController<ProviderMode>
    private var panel: StatusItemPanelController!
    private var captureWindow: NSWindow?
    private var deviceWindows: [UUID: NSWindow] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private static let controlWindowContentSize = NSSize(width: 360, height: 580)

    init(store: MockStore, server: MockServer, modeController: ModeTransitionController<ProviderMode>) {
        self.store = store
        self.server = server
        self.modeController = modeController
        super.init()
        panel = StatusItemPanelController(
            title: "ImpossiBLE Mock",
            toolTip: "ImpossiBLE Mock",
            contentSize: Self.controlWindowContentSize
        ) { [weak self] in
            guard let self else { return AnyView(EmptyView()) }
            return AnyView(MockMenuContent(
                store: self.store,
                server: self.server,
                transport: self.server.transport,
                activity: self.server.passthroughActivity,
                controller: self.modeController,
                onDismiss: { [weak self] in self?.panel.hidePanel() },
                onOpenCapture: { [weak self] in self?.openCaptureWindow() },
                onOpenDevice: { [weak self] deviceId in self?.openDeviceEditor(deviceId) }
            ))
        }
        observeIconState()
        updateIcon()
    }

    private func observeIconState() {
        // @Published emits in willSet, so reading server state inside the sink
        // would see the old value. Hop through the main queue so updateIcon()
        // runs after didSet.
        server.transport.$status.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateIcon() }.store(in: &cancellables)
        server.transport.$trafficActive.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateIcon() }.store(in: &cancellables)
        modeController.$mode.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateIcon() }.store(in: &cancellables)
        server.passthroughActivity.$trafficActive.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateIcon() }.store(in: &cancellables)
    }

    private func updateIcon() {
        panel.setIcon(FontAwesome.brandImage(
            FontAwesome.bluetoothB,
            size: 16,
            active: server.transport.trafficActive || server.passthroughActivity.trafficActive,
            mode: menuBarMode
        ))
    }

    private var menuBarMode: FontAwesome.MenuBarMode {
        switch server.transport.status {
            case .stopped, .blocked:
                .off
            case .listening, .clientConnected:
                modeController.mode == .passthrough ? .passthrough : .mock
        }
    }

    // MARK: - Document windows

    private func openCaptureWindow() {
        panel.hidePanel()
        if let captureWindow {
            captureWindow.makeKeyAndOrderFront(nil)
            NSRunningApplication.current.activate(options: [.activateAllWindows])
            return
        }

        let root = CaptureSheet(
            store: store,
            onClose: { [weak self] in self?.captureWindow?.close() }
        )
        .background(DeviceEditorWindowActivator())

        let window = makeDocumentWindow(
            title: "Capture Nearby Devices",
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
            rootView: root
        )
        window.identifier = NSUserInterfaceItemIdentifier("capture")
        window.delegate = self
        captureWindow = window
        showDocumentWindow(window)
    }

    private func openDeviceEditor(_ deviceId: UUID) {
        panel.hidePanel()
        if let window = deviceWindows[deviceId] {
            showDocumentWindow(window)
            return
        }

        let root = NavigationStack {
            DeviceEditorWindowContent(deviceId: deviceId, store: store)
        }
        .background(DeviceEditorWindowActivator())
        .frame(minWidth: 720, minHeight: 760)

        let window = makeDocumentWindow(
            title: "Device Editor",
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 820),
            rootView: root
        )
        window.identifier = NSUserInterfaceItemIdentifier("device-\(deviceId.uuidString)")
        window.delegate = self
        deviceWindows[deviceId] = window
        showDocumentWindow(window)
    }

    private func makeDocumentWindow<Content: View>(
        title: String,
        contentRect: NSRect,
        rootView: Content
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = NSHostingController(rootView: rootView)
        window.title = title
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    private func showDocumentWindow(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        NSApplication.shared.activate()
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            guard let window = notification.object as? NSWindow else { return }
            if window === self.captureWindow {
                self.captureWindow = nil
                return
            }
            guard let identifier = window.identifier?.rawValue,
                  identifier.hasPrefix("device-")
            else { return }
            let uuidString = String(identifier.dropFirst("device-".count))
            if let uuid = UUID(uuidString: uuidString) {
                self.deviceWindows[uuid] = nil
            }
        }
    }
}
