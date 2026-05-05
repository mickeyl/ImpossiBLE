import AppKit
import Combine
import SwiftUI

final class ControlPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class TransparentHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
}

final class MenuPanelContentView: NSView {
    private let hostingView: NSView
    private let cornerRadius: CGFloat

    override var isOpaque: Bool { false }

    init<Content: View>(rootView: Content, contentSize: NSSize, cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        hostingView = TransparentHostingView(rootView: rootView)
        super.init(frame: NSRect(origin: .zero, size: contentSize))

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        hostingView.frame = bounds
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.isOpaque = false
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.cornerRadius = cornerRadius
        hostingView.layer?.cornerCurve = .continuous
        hostingView.layer?.masksToBounds = true
        addSubview(hostingView)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let rect = bounds.insetBy(dx: 0.25, dy: 0.25)
        let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
        NSColor.windowBackgroundColor.setFill()
        path.fill()

        NSColor.separatorColor.withAlphaComponent(0.35).setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
final class StatusBarController: NSObject, ObservableObject, NSWindowDelegate {
    private let store: MockStore
    private let server: MockServer
    private let forwarder: ForwarderController
    private let statusItem: NSStatusItem
    private var controlWindow: NSPanel?
    private var captureWindow: NSWindow?
    private var deviceWindows: [UUID: NSWindow] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private static let controlWindowContentSize = NSSize(width: 360, height: 580)
    private static let controlWindowCornerRadius: CGFloat = 10

    init(store: MockStore, server: MockServer, forwarder: ForwarderController) {
        self.store = store
        self.server = server
        self.forwarder = forwarder
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureStatusItem()
        observeIconState()
        updateIcon()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(toggleControlWindow)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageOnly
        button.toolTip = "ImpossiBLE Mock"
    }

    private func observeIconState() {
        server.$status.sink { [weak self] _ in self?.updateIcon() }.store(in: &cancellables)
        server.$trafficActive.sink { [weak self] _ in self?.updateIcon() }.store(in: &cancellables)
        forwarder.$status.sink { [weak self] _ in self?.updateIcon() }.store(in: &cancellables)
        forwarder.$trafficActive.sink { [weak self] _ in self?.updateIcon() }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: AppPreferences.controlWindowBehaviorDidChange)
            .sink { [weak self] _ in self?.applyControlWindowBehavior() }
            .store(in: &cancellables)
    }

    private func updateIcon() {
        statusItem.button?.image = FontAwesome.brandImage(
            FontAwesome.bluetoothB,
            size: 16,
            active: server.trafficActive || forwarder.trafficActive,
            mode: menuBarMode
        )
    }

    private var menuBarMode: FontAwesome.MenuBarMode {
        if server.status != .stopped { return .mock }
        if case .running = forwarder.status { return .passthrough }
        return .off
    }

    @objc private func toggleControlWindow() {
        if controlWindow?.isVisible == true {
            hideControlWindow()
        } else {
            showControlWindow()
        }
    }

    private func showControlWindow() {
        let window = controlWindow ?? makeControlWindow()
        applyControlWindowBehavior()
        positionControlWindow(window)
        window.makeKeyAndOrderFront(nil)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        NSApplication.shared.activate()
    }

    private func makeControlWindow() -> NSPanel {
        let root = MockMenuContent(
            store: store,
            server: server,
            forwarder: forwarder,
            onDismiss: { [weak self] in self?.hideControlWindow() },
            onOpenCapture: { [weak self] in self?.openCaptureWindow() },
            onOpenDevice: { [weak self] deviceId in self?.openDeviceEditor(deviceId) }
        )
        .frame(width: 360, height: 580)

        let contentRect = NSRect(origin: .zero, size: Self.controlWindowContentSize)
        let window = ControlPanel(
            contentRect: contentRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = MenuPanelContentView(
            rootView: root,
            contentSize: Self.controlWindowContentSize,
            cornerRadius: Self.controlWindowCornerRadius
        )
        window.delegate = self
        window.title = "ImpossiBLE Mock"
        window.isReleasedWhenClosed = false
        window.hasShadow = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace]
        window.hidesOnDeactivate = AppPreferences.dismissControlWindowOnDeactivate
        window.invalidateShadow()
        controlWindow = window
        return window
    }

    private func applyControlWindowBehavior() {
        controlWindow?.hidesOnDeactivate = AppPreferences.dismissControlWindowOnDeactivate
    }

    private func positionControlWindow(_ window: NSWindow) {
        guard let button = statusItem.button, let buttonWindow = button.window else {
            window.center()
            return
        }

        let buttonFrame = buttonWindow.convertToScreen(button.frame)
        let screen = buttonWindow.screen ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        window.setContentSize(Self.controlWindowContentSize)
        window.contentView?.layoutSubtreeIfNeeded()
        let frameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: Self.controlWindowContentSize)).size
        let centeredX = buttonFrame.midX - frameSize.width / 2
        let x = min(
            max(centeredX, visibleFrame.minX + 8),
            visibleFrame.maxX - frameSize.width - 8
        )
        let y = max(visibleFrame.minY + 8, buttonFrame.minY - frameSize.height - 8)
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func hideControlWindow() {
        controlWindow?.orderOut(nil)
    }

    private func openCaptureWindow() {
        hideControlWindow()
        if let captureWindow {
            captureWindow.makeKeyAndOrderFront(nil)
            NSRunningApplication.current.activate(options: [.activateAllWindows])
            return
        }

        let root = CaptureSheet(
            store: store,
            server: server,
            forwarder: forwarder,
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
        hideControlWindow()
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
