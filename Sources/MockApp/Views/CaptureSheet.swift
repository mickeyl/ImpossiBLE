import SwiftUI

struct CaptureSheet: View {
    @ObservedObject var store: MockStore
    @ObservedObject var server: MockServer
    @ObservedObject var forwarder: ForwarderController
    var onClose: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @StateObject private var capture = CaptureSession()

    @State private var onlyConnectable = false
    @State private var showUnnamed = false
    @State private var nameContains = ""
    @State private var advertisingService = ""
    @State private var configurationName = Self.defaultConfigurationName()
    @State private var excludedDeviceIDs = Set<String>()
    @State private var startedFromMock = false
    @State private var startedFromOff = false
    @State private var isSavingConfiguration = false

    private var filteredDevices: [CapturedDevice] {
        capture.devices.filter(matchesFilters)
    }

    private var selectedDevices: [CapturedDevice] {
        filteredDevices.filter { !excludedDeviceIDs.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            filterControls
            Divider()
            deviceList
            Divider()
            inspectionStatus
            footer
        }
        .frame(width: 640, height: 560)
        .onDisappear {
            stopCaptureAndRestoreIfNeeded()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "record.circle")
                .font(.title2)
                .foregroundStyle(capture.isRunning ? .red : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text("Capture Nearby Devices")
                    .font(.headline)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(capture.isRunning ? "Stop" : "Start") {
                if capture.isRunning {
                    capture.stop()
                } else {
                    startCapture()
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(isSavingConfiguration || (!forwarder.canStart && !forwarder.isRunning))

            Button("Close") {
                close()
            }
            .disabled(isSavingConfiguration)
        }
        .padding(16)
    }

    private var filterControls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Toggle("Only Connectable", isOn: $onlyConnectable)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .disabled(isSavingConfiguration)

                Toggle("Show Unnamed", isOn: $showUnnamed)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .disabled(isSavingConfiguration)

                TextField("Name contains", text: $nameContains)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isSavingConfiguration)

                TextField("Advertising service UUID", text: $advertisingService)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isSavingConfiguration)
                    .onSubmit {
                        if capture.isRunning {
                            restartCapture()
                        }
                    }
            }

            HStack {
                Text("Service UUID changes apply on the next scan start.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(selectedDevices.count)/\(filteredDevices.count) selected")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var deviceList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if filteredDevices.isEmpty {
                    emptyState
                } else {
                    ForEach(filteredDevices) { device in
                        capturedDeviceRow(device)
                        Divider()
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: capture.isRunning ? "antenna.radiowaves.left.and.right" : "record.circle")
                .font(.largeTitle)
                .foregroundStyle(.secondary.opacity(0.35))
            Text(capture.isRunning ? "Listening for advertisements" : "Start a capture")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(showUnnamed ? "Filters are applied before saving." : "Unnamed devices are hidden.")
                .font(.caption)
                .foregroundStyle(.secondary.opacity(0.75))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 70)
    }

    private func capturedDeviceRow(_ device: CapturedDevice) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: selectionBinding(for: device))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(isSavingConfiguration)

            Image(systemName: device.isConnectable ? "link.circle" : "antenna.radiowaves.left.and.right.circle")
                .foregroundStyle(device.isConnectable ? .green : .secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(device.displayName)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    if device.manufacturerData != nil {
                        Image(systemName: "building.2")
                            .font(.caption)
                            .symbolRenderingMode(.monochrome)
                            .foregroundStyle(.secondary)
                            .frame(width: 14)
                            .accessibilityLabel("Manufacturer data present")
                            .help("Advertisement includes manufacturer-specific data")
                    }
                }

                Text(device.servicesSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text("\(device.rssi) dBm")
                    .font(.caption.weight(.semibold))
                Text("\(device.seenCount)x")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 64, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            TextField("Configuration name", text: $configurationName)
                .textFieldStyle(.roundedBorder)
                .disabled(isSavingConfiguration)

            Button(isSavingConfiguration ? "Inspecting..." : "Save Configuration") {
                saveConfiguration()
            }
            .disabled(
                isSavingConfiguration ||
                selectedDevices.isEmpty ||
                configurationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }
        .padding(16)
    }

    @ViewBuilder
    private var inspectionStatus: some View {
        if capture.inspectionProgress.isActive {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Inspecting \(capture.inspectionProgress.deviceName)")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    Text("\(min(capture.inspectionProgress.currentIndex + 1, capture.inspectionProgress.total))/\(capture.inspectionProgress.total)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                ProgressView(value: capture.inspectionProgress.fraction)

                Text(capture.inspectionProgress.phase)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private var statusText: String {
        switch capture.status {
            case .idle:
                capture.lastActivity.isEmpty ? "Ready" : capture.lastActivity
            case .connecting:
                "Connecting to impossible-helper"
            case .scanning:
                capture.lastActivity
            case .failed(let message):
                message
        }
    }

    private func selectionBinding(for device: CapturedDevice) -> Binding<Bool> {
        Binding(
            get: { !excludedDeviceIDs.contains(device.id) },
            set: { isSelected in
                if isSelected {
                    excludedDeviceIDs.remove(device.id)
                } else {
                    excludedDeviceIDs.insert(device.id)
                }
            }
        )
    }

    private func startCapture() {
        startedFromMock = server.status != .stopped
        startedFromOff = server.status == .stopped && !forwarder.isRunning
        excludedDeviceIDs.removeAll()

        server.stop {
            forwarder.start {
                capture.start(serviceUUIDs: requestedServiceUUIDs)
            }
        }
    }

    private func restartCapture() {
        capture.stop()
        excludedDeviceIDs.removeAll()
        capture.start(serviceUUIDs: requestedServiceUUIDs)
    }

    private func stopCaptureAndRestoreIfNeeded() {
        capture.stop()
        if startedFromMock {
            forwarder.stop {
                server.start()
            }
        } else if startedFromOff {
            forwarder.stop()
        }
    }

    private func saveConfiguration() {
        let name = configurationName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        isSavingConfiguration = true
        capture.inspectDevices(selectedDevices) { devices in
            store.saveConfiguration(name: name, devices: devices, loadImmediately: true)
            capture.stop()
            forwarder.stop {
                server.start()
            }
            startedFromMock = false
            startedFromOff = false
            isSavingConfiguration = false
            close()
        }
    }

    private func close() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }

    private var requestedServiceUUIDs: [String] {
        let service = advertisingService.trimmingCharacters(in: .whitespacesAndNewlines)
        return service.isEmpty ? [] : [service.uppercased()]
    }

    private func matchesFilters(_ device: CapturedDevice) -> Bool {
        if onlyConnectable && !device.isConnectable {
            return false
        }

        if !showUnnamed && !device.hasName {
            return false
        }

        let nameFilter = nameContains.trimmingCharacters(in: .whitespacesAndNewlines)
        if !nameFilter.isEmpty,
           device.displayName.range(of: nameFilter, options: [.caseInsensitive, .diacriticInsensitive]) == nil {
            return false
        }

        let serviceFilter = advertisingService.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if !serviceFilter.isEmpty,
           !device.advertisedServiceUUIDs.contains(where: { $0.uppercased() == serviceFilter }) {
            return false
        }

        return true
    }

    private static func defaultConfigurationName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return "Capture \(formatter.string(from: Date()))"
    }
}
