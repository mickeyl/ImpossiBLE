import SwiftUI
import AppKit
import SimBridgeServer
import SimBridgeShell

/// The embeddable heart of the ImpossiBLE provider UI: mode picker, status
/// line, and the mode-specific body. The standalone panel wraps it with a
/// title header and an app footer; the Simsalabim suite embeds it as one
/// section among several providers.
public struct ImpossiBLESection: View {
    @ObservedObject var store: MockStore
    @ObservedObject var server: MockServer
    @ObservedObject var transport: ProtocolServer
    @ObservedObject var activity: PassthroughActivityMonitor
    @ObservedObject var controller: ModeTransitionController<ProviderMode>
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    /// A host that surfaces the connected client on its own level (the suite
    /// does) passes false; the section then omits its client display.
    var showsClient: Bool
    var onDismiss: (() -> Void)?
    var onOpenCapture: (() -> Void)?
    var onOpenDevice: ((UUID) -> Void)?
    @State private var showConfigs = false
    @State private var saveConfigName = ""
    @State private var showSaveField = false
    static let statusIconColumnWidth: CGFloat = 24
    static let bodyPlaceholderGlyphSize: CGFloat = 34

    public init(
        store: MockStore,
        server: MockServer,
        transport: ProtocolServer,
        activity: PassthroughActivityMonitor,
        controller: ModeTransitionController<ProviderMode>,
        showsClient: Bool = true,
        onDismiss: (() -> Void)? = nil,
        onOpenCapture: (() -> Void)? = nil,
        onOpenDevice: ((UUID) -> Void)? = nil
    ) {
        self.store = store
        self.server = server
        self.transport = transport
        self.activity = activity
        self.controller = controller
        self.showsClient = showsClient
        self.onDismiss = onDismiss
        self.onOpenCapture = onOpenCapture
        self.onOpenDevice = onOpenDevice
    }

    public var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Picker("Mode", selection: modeBinding) {
                    ForEach(ProviderMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(controller.isSwitching)

                // Redundant while off: the body's "ImpossiBLE is off" headline
                // carries the state, matching CAMouflage's layout.
                if currentMode != .off {
                    modeStatusDetail
                }
            }
            .padding(12)
            Divider()

            switch currentMode {
                case .off:
                    offBody
                case .mock:
                    mockBody
                case .passthrough:
                    passthroughBody
            }
        }
        .onAppear {
            server.store = store
        }
    }

    /// The provider's health, for a host that wants to tint its own chrome.
    public static func statusColor(mode: ProviderMode, status: ProtocolServer.Status) -> Color {
        switch mode {
            case .off:
                .secondary
            case .mock, .passthrough:
                switch status {
                    case .stopped:         .secondary
                    case .listening:       .blue
                    case .clientConnected: .green
                    case .blocked:         .orange
                }
        }
    }

    @ViewBuilder
    private var mockBody: some View {
        // A client-supplied configuration replaces what is being served, so it
        // has to replace what is shown too — otherwise the panel quietly lies
        // about which devices exist.
        if let supplied = server.clientSuppliedConfiguration {
            clientConfigBanner(supplied)
            Divider()
            clientDeviceList(supplied)
        } else {
            configBar
            Divider()

            if showConfigs {
                configList
                Divider()
            }
            deviceList
        }
    }

    private func clientConfigBanner(_ supplied: ClientSuppliedConfiguration) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text(supplied.name)
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(supplied.devices.count) devices")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text("Supplied by \(supplied.sourceDescription) · your selection resumes when it disconnects")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10))
    }

    /// Read-only on purpose: these devices belong to the client, and editing
    /// them here would be silently discarded on its next upload.
    private func clientDeviceList(_ supplied: ClientSuppliedConfiguration) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(supplied.devices) { device in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Image(systemName: device.isEnabled ? "dot.radiowaves.left.and.right" : "circle.slash")
                                .font(.caption)
                                .foregroundStyle(device.isEnabled ? .primary : .secondary)
                            Text(device.name)
                                .font(.subheadline)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text("\(device.rssi) dBm")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if let service = device.advertisedServiceUUIDs.first {
                            Text(service)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: .infinity)
    }

    /// The product's own icon from the app bundle, pre-scaled so redraws never
    /// pay for downsampling the icns. The FontAwesome glyph keeps the
    /// embeddable ProviderKit usable in hosts that do not ship the asset.
    private static let brandIcon = NSImage(named: "ImpossiBLE")?.sbkScaled(toPointSize: 148)

    private var offBody: some View {
        bodyPlaceholder(title: "ImpossiBLE is off", message: "Simulator apps see Bluetooth powered off.") {
            if let icon = Self.brandIcon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 148, height: 148)
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                    // Rasterize icon + shadow once: a bare .shadow forces an
                    // offscreen blur pass on every recomposite, which is visible
                    // as stutter while the suite's pane splitter resizes this pane.
                    .drawingGroup()
            } else {
                Image(nsImage: FontAwesome.brandImage(FontAwesome.bluetoothB, size: Self.bodyPlaceholderGlyphSize))
                    .foregroundStyle(.secondary.opacity(0.35))
            }
        }
    }

    @ViewBuilder
    private func bodyPlaceholder<Icon: View>(title: String? = nil, message: String, @ViewBuilder icon: () -> Icon) -> some View {
        VStack(spacing: 14) {
            icon()
            VStack(spacing: 4) {
                if let title {
                    Text(title)
                        .font(.headline)
                }
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Mode

    private var currentMode: ProviderMode {
        controller.mode
    }

    private var modeBinding: Binding<ProviderMode> {
        Binding(
            get: { controller.mode },
            set: { controller.select($0) }
        )
    }

    // MARK: - Status

    @ViewBuilder
    private var modeStatusDetail: some View {
        ProviderStatusLine(
            iconName: statusIconName,
            statusColor: Self.statusColor(mode: currentMode, status: transport.status),
            title: providerStatusTitle,
            detail: providerStatusDetailText,
            showsClient: showsClient,
            client: showsClient ? providerClient : nil,
            terminateClient: (showsClient && providerClient != nil) ? terminateProviderClient : nil
        )
    }

    private var deviceSummary: String {
        let enabledCount = store.devices.filter(\.isEnabled).count
        let deviceWord = store.devices.count == 1 ? "device" : "devices"
        return "\(enabledCount)/\(store.devices.count) \(deviceWord) enabled"
    }

    private var statusText: String {
        switch transport.status {
            case .stopped:          "Stopped"
            case .listening:        "Listening"
            case .clientConnected:  "Client connected"
            case .blocked:          "Blocked"
        }
    }

    private var statusIconName: String {
        switch currentMode {
            case .off:
                "power"
            case .mock:
                "antenna.radiowaves.left.and.right.circle"
            case .passthrough:
                activity.trafficActive ? "bolt.horizontal.circle.fill" : "antenna.radiowaves.left.and.right.circle"
        }
    }

    private var providerStatusTitle: String {
        switch currentMode {
            case .off:
                "Off"
            case .mock, .passthrough:
                statusText
        }
    }

    private var providerStatusDetailText: String {
        if case .blocked(let message) = transport.status, currentMode != .off {
            return message
        }
        switch currentMode {
            case .off:
                return "No provider running"
            case .mock:
                guard !transport.lastActivity.isEmpty else { return deviceSummary }
                return "\(deviceSummary) · \(transport.lastActivity)"
            case .passthrough:
                let summary = passthroughDetailText
                guard !activity.lastActivity.isEmpty else { return summary }
                return "\(summary) · \(activity.lastActivity)"
        }
    }

    private var providerClient: SocketClientInfo? {
        currentMode == .off ? nil : transport.connectedClient
    }

    private func terminateProviderClient() {
        guard currentMode != .off else { return }
        server.terminateConnectedClient()
    }

    private var passthroughDetailText: String {
        guard transport.status != .stopped else { return "No passthrough provider running" }
        let devices = activity.devices
        let activeCount = devices.filter(\.isActive).count
        if activeCount > 0 {
            let deviceWord = activeCount == 1 ? "device" : "devices"
            return "\(activeCount) active \(deviceWord)"
        }
        if !devices.isEmpty {
            let deviceWord = devices.count == 1 ? "device" : "devices"
            return "\(devices.count) communicating \(deviceWord)"
        }
        return "No device traffic yet"
    }

    // MARK: - Configuration Bar

    private var configBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showConfigs.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showConfigs ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .symbolRenderingMode(.monochrome)
                        Image(systemName: "folder")
                            .font(.caption)
                            .symbolRenderingMode(.monochrome)
                        if !store.activeConfigurationName.isEmpty {
                            Text(store.activeConfigurationName)
                                .font(.subheadline)
                                .lineLimit(1)
                        } else {
                            Text("Configurations")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    store.addDevice()
                } label: {
                    Image(systemName: "plus")
                }
                .font(.caption)
                .buttonStyle(.borderless)
                .help("Add a mock device")

                Button {
                    openCaptureWindow()
                } label: {
                    Text("Capture")
                }
                .font(.caption)
                .buttonStyle(.borderless)
                .help("Capture nearby BLE devices")
                .disabled(controller.isSwitching)

                Button {
                    saveConfigName = store.activeConfigurationName
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showSaveField.toggle()
                    }
                } label: {
                    Text("Save")
                }
                .font(.caption)
                .buttonStyle(.borderless)
                .help("Save current devices as configuration")
                .disabled(store.devices.isEmpty)
            }
            .padding(12)

            if showSaveField {
                HStack(spacing: 6) {
                    TextField("Configuration name", text: $saveConfigName)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .onSubmit { commitSaveConfig() }

                    Button("Save") { commitSaveConfig() }
                        .font(.caption)
                        .controlSize(.small)
                        .disabled(saveConfigName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showSaveField = false
                        }
                        saveConfigName = ""
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            }
        }
    }

    private func commitSaveConfig() {
        let name = saveConfigName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        store.saveCurrentAsConfiguration(name: name)
        store.activeConfigurationName = name
        saveConfigName = ""
        withAnimation(.easeInOut(duration: 0.15)) {
            showSaveField = false
        }
    }

    private func openCaptureWindow() {
        closeMenuWindow()
        if let onOpenCapture {
            onOpenCapture()
        } else {
            DispatchQueue.main.async {
                openWindow(id: "capture")
                NSRunningApplication.current.activate(options: [.activateAllWindows])
                NSApplication.shared.activate()
            }
        }
    }

    private func closeMenuWindow() {
        if let onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
    }

    private func openDeviceEditor(_ deviceId: UUID) {
        closeMenuWindow()
        if let onOpenDevice {
            onOpenDevice(deviceId)
        } else {
            DispatchQueue.main.async {
                openWindow(value: deviceId)
                NSRunningApplication.current.activate(options: [.activateAllWindows])
                NSApplication.shared.activate()
            }
        }
    }

    // MARK: - Configuration List

    private var configList: some View {
        ScrollView {
            VStack(spacing: 0) {
                if !StockConfigurations.all.isEmpty {
                    sectionHeader("Stock")
                    ForEach(StockConfigurations.all) { config in
                        configRow(config, isStock: true)
                    }
                }

                if !store.configurations.isEmpty {
                    sectionHeader("Saved")
                    ForEach(store.configurations) { config in
                        configRow(config, isStock: false)
                    }
                }

                if store.configurations.isEmpty {
                    Text("Save the current setup with the button above")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: 200)
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private func configRow(_ config: MockConfiguration, isStock: Bool) -> some View {
        let isActive = config.name == store.activeConfigurationName
        return HStack(spacing: 8) {
            Image(systemName: isActive ? "checkmark.circle.fill" : (isStock ? "star.fill" : "folder.fill"))
                .font(.caption2)
                .foregroundStyle(isActive ? .green : (isStock ? .orange : .blue))
                .frame(width: 14, alignment: .trailing)

            VStack(alignment: .leading, spacing: 1) {
                Text(config.name)
                    .font(.caption.weight(isActive ? .semibold : .regular))
                    .lineLimit(1)
                Text(configSummary(config))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !isStock {
                Button {
                    store.deleteConfiguration(id: config.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }

            Button("Load") {
                store.loadConfiguration(config)
                withAnimation(.easeInOut(duration: 0.15)) {
                    showConfigs = false
                }
            }
            .font(.caption)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    private func configSummary(_ config: MockConfiguration) -> String {
        let deviceCount = config.devices.count
        let serviceCount = config.devices.reduce(0) { $0 + $1.services.count }
        return "\(deviceCount) device\(deviceCount == 1 ? "" : "s"), \(serviceCount) service\(serviceCount == 1 ? "" : "s")"
    }

    // MARK: - Device List

    private var deviceList: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                if store.devices.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "plus.circle.dashed")
                            .font(.largeTitle)
                            .foregroundColor(.gray.opacity(0.2))
                        Text("No mock devices")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("Load a configuration or add a device")
                            .font(.caption)
                            .foregroundColor(.gray.opacity(0.5))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                } else {
                    ForEach($store.devices) { $device in
                        DeviceRow(
                            device: $device,
                            store: store,
                            server: server,
                            onDismiss: onDismiss,
                            onOpenDevice: openDeviceEditor
                        )
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Passthrough Body

    private var passthroughBody: some View {
        Group {
            if activity.devices.isEmpty {
                passthroughPlaceholder(
                    systemImage: "antenna.radiowaves.left.and.right.slash",
                    tint: .secondary.opacity(0.35),
                    message: "No device traffic yet"
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(activity.devices) { entry in
                            PassthroughActivityRow(activity: entry)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func passthroughPlaceholder(systemImage: String, tint: Color, message: String) -> some View {
        bodyPlaceholder(message: message) {
            Image(systemName: systemImage)
                .font(.system(size: Self.bodyPlaceholderGlyphSize))
                .foregroundStyle(tint)
        }
    }
}

private struct ProviderStatusLine: View {
    let iconName: String
    let statusColor: Color
    let title: String
    let detail: String
    let showsClient: Bool
    let client: SocketClientInfo?
    let terminateClient: (() -> Void)?

    @State private var confirmTermination = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            ZStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                    .offset(x: 7, y: -7)
                Image(systemName: iconName)
                    .font(.caption)
                    .foregroundStyle(statusColor)
            }
            .frame(width: ImpossiBLESection.statusIconColumnWidth, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    if showsClient {
                        Text(clientText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }

                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let terminateClient, let client {
                Button {
                    confirmTermination = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Terminate connected client")
                .accessibilityLabel("Terminate connected client")
                .confirmationDialog(
                    "Terminate \(client.displayText)?",
                    isPresented: $confirmTermination,
                    titleVisibility: .visible
                ) {
                    Button("Terminate", role: .destructive) {
                        terminateClient()
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("The simulator client will be disconnected from the BLE provider.")
                }
            }
        }
        .frame(minHeight: 26)
    }

    private var clientText: String {
        guard let client else { return "No client" }
        guard let version = client.libraryVersion else { return "Client \(client.displayText)" }
        return "Client \(client.displayText) · lib \(version)"
    }
}

// MARK: - Passthrough Activity Row

struct PassthroughActivityRow: View {
    let activity: PassthroughDeviceActivity

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(activity.isActive ? Color.green : Color.secondary.opacity(0.3))
                .frame(width: 8, height: 8)

            Image(systemName: "wave.3.right")
                .font(.caption)
                .foregroundStyle(activity.isActive ? .green : .blue)
                .frame(width: 16, alignment: .trailing)

            VStack(alignment: .leading, spacing: 2) {
                Text(activity.displayName)
                    .font(.subheadline)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(activity.lastOperation)
                    if !activity.lastDetail.isEmpty {
                        Text(activity.lastDetail)
                    }
                    Text("·")
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(ageText(now: context.date))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer()

            if activity.isActive {
                Text("Now")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.green)
            } else if activity.count > 1 {
                Text("\(activity.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(activity.isActive ? Color.green.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
        .help(activity.id)
    }

    private func ageText(now: Date) -> String {
        let age = max(0, now.timeIntervalSince(activity.lastAt))
        if age < 2 {
            return "now"
        }
        if age < 60 {
            return "\(Int(age))s ago"
        }
        if age < 3600 {
            return "\(Int(age / 60))m ago"
        }
        return "\(Int(age / 3600))h ago"
    }
}

// MARK: - Device Row

struct DeviceRow: View {
    @Binding var device: MockDevice
    @ObservedObject var store: MockStore
    @ObservedObject var server: MockServer
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    var onDismiss: (() -> Void)?
    var onOpenDevice: ((UUID) -> Void)?

    private var isConnected: Bool {
        server.connectedDeviceIDs.contains(device.id.uuidString)
    }

    private var isPaired: Bool {
        server.pairedDeviceIDs.contains(device.id.uuidString)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wave.3.right")
                .font(.caption)
                .foregroundColor(device.isEnabled ? .blue : .gray.opacity(0.3))
                .frame(width: 16, alignment: .trailing)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(device.name)
                        .font(.subheadline)
                        .lineLimit(1)
                    if isConnected {
                        Image(systemName: "link")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                    if isPaired {
                        Image(systemName: "lock.open.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                HStack(spacing: 4) {
                    Text(device.services.count == 1 ? "1 service" : "\(device.services.count) services")
                    Text("RSSI \(device.rssi)")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                openEditor()
            } label: {
                Label("Edit", systemImage: "pencil")
                    .font(.caption)
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Edit device")

            Toggle("", isOn: $device.isEnabled)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .onChange(of: device.isEnabled) { _, _ in
                    store.save()
                }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Edit\u{2026}") {
                openEditor()
            }
            Button("Duplicate") {
                store.duplicateDevice(id: device.id)
            }
            Divider()
            Button("Delete", role: .destructive) {
                store.deleteDevice(id: device.id)
            }
        }
    }

    private func openEditor() {
        let deviceId = device.id
        if let onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
        if let onOpenDevice {
            onOpenDevice(deviceId)
        } else {
            DispatchQueue.main.async {
                openWindow(value: deviceId)
                NSRunningApplication.current.activate(options: [.activateAllWindows])
            }
        }
    }
}
