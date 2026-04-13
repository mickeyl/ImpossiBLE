import SwiftUI

struct MockMenuContent: View {
    @ObservedObject var store: MockStore
    @ObservedObject var server: MockServer
    @State private var showConfigs = false
    @State private var saveConfigName = ""
    @State private var showSaveAlert = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            configBar
            Divider()

            if showConfigs {
                configList
            } else {
                deviceList
            }

            Divider()
            footer
        }
        .onAppear {
            server.store = store
        }
        .alert("Save Configuration", isPresented: $showSaveAlert) {
            TextField("Configuration name", text: $saveConfigName)
            Button("Save") {
                let name = saveConfigName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                store.saveCurrentAsConfiguration(name: name)
                store.activeConfigurationName = name
                saveConfigName = ""
            }
            .disabled(saveConfigName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { saveConfigName = "" }
        } message: {
            Text("Enter a name for this configuration.")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(statusColor)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text("ImpossiBLE Mock")
                        .font(.headline)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()

                Button(server.status == .stopped ? "Start" : "Stop") {
                    server.status == .stopped ? server.start() : server.stop()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(statusColor)
                .help(server.status == .stopped ? "Start mock server" : "Stop mock server")
            }

            HStack(spacing: 8) {
                Label(deviceSummary, systemImage: "antenna.radiowaves.left.and.right.circle")
                    .controlSize(.small)
                Spacer()
                Text("/tmp/impossible.sock")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if !server.lastActivity.isEmpty {
                HStack {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(server.lastActivity)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                }
            }
        }
        .padding(12)
    }

    private var statusColor: Color {
        switch server.status {
            case .stopped:         .secondary
            case .listening:       .blue
            case .clientConnected: .green
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
            case .listening:        "Listening on /tmp/impossible.sock"
            case .clientConnected:  "Client connected"
        }
    }

    // MARK: - Configuration Bar

    private var configBar: some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    showConfigs.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showConfigs ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                    Image(systemName: "folder")
                        .font(.caption)
                    if !store.activeConfigurationName.isEmpty {
                        Text(store.activeConfigurationName)
                            .font(.caption)
                            .lineLimit(1)
                    } else {
                        Text("Configurations")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                saveConfigName = store.activeConfigurationName
                showSaveAlert = true
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Save current devices as configuration")
            .disabled(store.devices.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
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
        .frame(maxHeight: .infinity)
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
        HStack(spacing: 8) {
            Image(systemName: isStock ? "star.fill" : "folder.fill")
                .font(.caption2)
                .foregroundStyle(isStock ? .orange : .blue)
                .frame(width: 14, alignment: .trailing)

            VStack(alignment: .leading, spacing: 1) {
                Text(config.name)
                    .font(.caption)
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
                        DeviceRow(device: $device, store: store)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button {
                store.addDevice()
            } label: {
                Label("Add Device", systemImage: "plus")
                    .font(.caption)
            }
            .buttonStyle(.borderless)

            Spacer()

            Button("Quit") {
                server.stop()
                EditorWindowController.shared.closeAll()
                NSApplication.shared.terminate(nil)
            }
            .font(.caption)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .padding(12)
    }
}

// MARK: - Device Row

struct DeviceRow: View {
    @Binding var device: MockDevice
    @ObservedObject var store: MockStore

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wave.3.right")
                .font(.caption)
                .foregroundColor(device.isEnabled ? .blue : .gray.opacity(0.3))
                .frame(width: 16, alignment: .trailing)

            VStack(alignment: .leading, spacing: 1) {
                Text(device.name)
                    .font(.subheadline)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(device.services.count == 1 ? "1 service" : "\(device.services.count) services")
                    Text("RSSI \(device.rssi)")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                EditorWindowController.shared.openEditor(for: device.id, store: store)
            } label: {
                Image(systemName: "pencil.circle")
                    .font(.body)
            }
            .buttonStyle(.borderless)
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
                EditorWindowController.shared.openEditor(for: device.id, store: store)
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
}
