import SwiftUI
import AppKit

struct MockMenuContent: View {
    @ObservedObject var store: MockStore
    @ObservedObject var server: MockServer
    @ObservedObject var forwarder: ForwarderController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    var onDismiss: (() -> Void)?
    var onOpenCapture: (() -> Void)?
    var onOpenDevice: ((UUID) -> Void)?
    @State private var showConfigs = false
    @State private var saveConfigName = ""
    @State private var showSaveField = false
    @AppStorage(AppPreferences.dismissControlWindowOnDeactivateKey) private var dismissOnDeactivate = false
    fileprivate static let statusIconColumnWidth: CGFloat = 24

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if currentMode == .passthrough {
                passthroughBody
            } else {
                configBar
                Divider()

                if showConfigs {
                    configList
                    Divider()
                }
                deviceList
            }

            Divider()
            footer
        }
        .onAppear {
            server.store = store
        }
        .background(Color.clear)
    }

    // MARK: - Mode

    private var currentMode: MockProviderMode {
        if server.status != .stopped { return .mock }
        if forwarder.isRunning { return .passthrough }
        return .off
    }

    private var modeBinding: Binding<MockProviderMode> {
        Binding(
            get: { currentMode },
            set: { setMode($0) }
        )
    }

    private func setMode(_ mode: MockProviderMode) {
        mode.persist()

        switch mode {
            case .off:
                server.stop()
                forwarder.stop()
            case .mock:
                forwarder.stop {
                    server.start()
                }
            case .passthrough:
                server.stop {
                    forwarder.start()
                }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 8) {
            HStack {
                Image(nsImage: FontAwesome.brandImage(FontAwesome.bluetoothB, size: 18))
                    .foregroundStyle(statusColor)
                    .frame(width: Self.statusIconColumnWidth, alignment: .center)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("ImpossiBLE Mock")
                        .font(.headline)
                    if !appVersion.isEmpty {
                        Text(appVersion)
                            .font(.caption)
                            .fontWeight(.regular)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }

            Picker("Mode", selection: modeBinding) {
                ForEach(MockProviderMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(forwarder.isBusy)

            modeStatusDetail
        }
        .padding(12)
        .onAppear {
            forwarder.refresh()
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? AppVersion.current
    }

    @ViewBuilder
    private var modeStatusDetail: some View {
        ProviderStatusLine(
            iconName: statusIconName,
            statusColor: statusColor,
            title: providerStatusTitle,
            detail: providerStatusDetailText,
            client: providerClient,
            terminateClient: providerClient == nil ? nil : terminateProviderClient
        )
    }

    private var statusColor: Color {
        switch currentMode {
            case .off:
                .secondary
            case .mock:
                switch server.status {
                    case .stopped:         .secondary
                    case .listening:       .blue
                    case .clientConnected: .green
                }
            case .passthrough:
                forwarderStatusColor
        }
    }

    private var deviceSummary: String {
        let enabledCount = store.devices.filter(\.isEnabled).count
        let deviceWord = store.devices.count == 1 ? "device" : "devices"
        return "\(enabledCount)/\(store.devices.count) \(deviceWord) enabled"
    }

    private var statusText: String {
        switch server.status {
            case .stopped:          "Stopped"
            case .listening:        "Listening"
            case .clientConnected:  "Client connected"
        }
    }

    private var statusIconName: String {
        switch currentMode {
            case .off:
                "power"
            case .mock:
                "antenna.radiowaves.left.and.right.circle"
            case .passthrough:
                forwarder.trafficActive ? "bolt.horizontal.circle.fill" : "antenna.radiowaves.left.and.right.circle"
        }
    }

    private var providerStatusTitle: String {
        switch currentMode {
            case .off:
                "Off"
            case .mock:
                statusText
            case .passthrough:
                forwarderStatusText
        }
    }

    private var providerStatusDetailText: String {
        switch currentMode {
            case .off:
                return "No provider running"
            case .mock:
                guard !server.lastActivity.isEmpty else { return deviceSummary }
                return "\(deviceSummary) · \(server.lastActivity)"
            case .passthrough:
                let summary = passthroughDetailText
                guard !forwarder.lastActivity.isEmpty else { return summary }
                return "\(summary) · \(forwarder.lastActivity)"
        }
    }

    private var providerClient: SocketClientInfo? {
        switch currentMode {
            case .off:
                nil
            case .mock:
                server.connectedClient
            case .passthrough:
                forwarder.connectedClient
        }
    }

    private func terminateProviderClient() {
        switch currentMode {
            case .off:
                break
            case .mock:
                server.terminateConnectedClient()
            case .passthrough:
                forwarder.terminateConnectedClient()
        }
    }

    private var forwarderStatusColor: Color {
        switch forwarder.status {
            case .unknown:          .secondary
            case .stopped:          .secondary
            case .running:          .green
            case .unavailable:      .orange
        }
    }

    private var forwarderStatusText: String {
        switch forwarder.status {
            case .unknown:
                "Checking..."
            case .stopped:
                "Stopped"
            case .running(let pids):
                pids.count == 1 ? "Running (PID \(pids[0]))" : "Running (\(pids.count) processes)"
            case .unavailable(let message):
                message
        }
    }

    private var passthroughDetailText: String {
        guard forwarder.isRunning else { return "No passthrough provider running" }
        let devices = forwarder.passthroughDevices
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
                    openCaptureWindow()
                } label: {
                    Text("Capture")
                }
                .font(.caption)
                .buttonStyle(.borderless)
                .help("Capture nearby BLE devices")
                .disabled(forwarder.isBusy || (!forwarder.canStart && !forwarder.isRunning))

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
            if let message = forwarder.activityUnavailableMessage {
                passthroughPlaceholder(
                    systemImage: "exclamationmark.triangle",
                    tint: .orange.opacity(0.75),
                    message: message
                )
            } else if forwarder.passthroughDevices.isEmpty {
                passthroughPlaceholder(
                    systemImage: "antenna.radiowaves.left.and.right.slash",
                    tint: .secondary.opacity(0.35),
                    message: "No device traffic yet"
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(forwarder.passthroughDevices) { activity in
                            PassthroughActivityRow(activity: activity)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func passthroughPlaceholder(systemImage: String, tint: Color, message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(tint)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    private static let launchAgentPath: String = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.impossible.ble-mock.plist")
            .path
    }()

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { FileManager.default.fileExists(atPath: Self.launchAgentPath) },
            set: { newValue in
                if newValue {
                    Self.writeLaunchAgent()
                } else {
                    try? FileManager.default.removeItem(atPath: Self.launchAgentPath)
                }
            }
        )
    }

    private static func writeLaunchAgent() {
        let bundleURL = Bundle.main.bundleURL
        let arguments: [String] = if bundleURL.pathExtension == "app" {
            ["/usr/bin/open", bundleURL.path]
        } else {
            [Bundle.main.executableURL?.path ?? ProcessInfo.processInfo.arguments[0]]
        }
        let plist: [String: Any] = [
            "Label": "com.impossible.ble-mock",
            "ProgramArguments": arguments,
            "RunAtLoad": true
        ]
        let dir = (launchAgentPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
            FileManager.default.createFile(atPath: launchAgentPath, contents: data)
        }
    }

    private var footer: some View {
        HStack {
            if currentMode != .passthrough {
                Button {
                    store.addDevice()
                } label: {
                    Label("Add Device", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }

            Spacer()

            Toggle("Launch at Startup", isOn: launchAtLoginBinding)
                .toggleStyle(.checkbox)
                .font(.caption)
                .controlSize(.small)

            Toggle("Dismiss on Switch", isOn: $dismissOnDeactivate)
                .toggleStyle(.checkbox)
                .font(.caption)
                .controlSize(.small)
                .onChange(of: dismissOnDeactivate) { _, _ in
                    NotificationCenter.default.post(name: AppPreferences.controlWindowBehaviorDidChange, object: nil)
                }

            Spacer()

            Button("Quit") {
                server.stop()
                NSApplication.shared.terminate(nil)
            }
            .font(.caption)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .padding(12)
    }
}

private struct ProviderStatusLine: View {
    let iconName: String
    let statusColor: Color
    let title: String
    let detail: String
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
            .frame(width: MockMenuContent.statusIconColumnWidth, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Text(clientText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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
        return "Client \(client.displayText)"
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
