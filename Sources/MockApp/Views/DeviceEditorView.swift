import SwiftUI
import AppKit

struct DeviceEditorView: View {
    @Binding var device: MockDevice
    var onSave: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                EditorSection("Peripheral") {
                    EditorRow(title: "Name") {
                        TextField("Name", text: $device.name)
                    }

                    EditorRow(title: "UUID") {
                        HStack(spacing: 8) {
                            Text(device.id.uuidString)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .foregroundStyle(.secondary)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(device.id.uuidString, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .help("Copy UUID")
                        }
                    }

                    EditorRow(title: "RSSI") {
                        HStack(spacing: 12) {
                            Slider(value: rssiBinding, in: -100...0)
                            Text("\(device.rssi) dBm")
                                .font(.system(.caption, design: .monospaced))
                                .frame(width: 60, alignment: .trailing)
                        }
                    }

                    EditorRow(title: "Connectable") {
                        Toggle("Connectable", isOn: $device.isConnectable)
                            .labelsHidden()
                    }
                }

                EditorSection("Pairing") {
                    EditorRow(title: "Mode") {
                        Picker("Mode", selection: $device.pairingMode) {
                            ForEach(PairingMode.allCases, id: \.self) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 260)
                    }
                    if device.pairingMode == .passkey {
                        EditorRow(title: "Passkey") {
                            TextField("6 digits", text: $device.passkey)
                                .font(.system(.body, design: .monospaced))
                                .frame(maxWidth: 180)
                        }
                    }
                }

                EditorSection("Advertisement") {
                    EditorRow(title: "Service UUIDs") {
                        TextField("e.g. 180A, 180D", text: advertisedUUIDsBinding)
                            .font(.system(.body, design: .monospaced))
                    }
                    EditorDivider()
                    EditorRow(title: "Manufacturer Data") {
                        TextField("e.g. FF010203", text: manufacturerDataBinding)
                            .font(.system(.body, design: .monospaced))
                    }
                }

                EditorSection("Services", trailingText: "\(device.services.count)") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach($device.services) { $service in
                            ServiceEditorView(service: $service, peripheralUUID: device.id.uuidString)
                        }
                        .onDelete { offsets in
                            device.services.remove(atOffsets: offsets)
                        }

                        Button {
                            device.services.append(MockService())
                        } label: {
                            Label("Add Service", systemImage: "plus")
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle(device.name)
        .onChange(of: device) { _, _ in
            onSave()
        }
    }

    private var rssiBinding: Binding<Double> {
        Binding(
            get: { Double(device.rssi) },
            set: { device.rssi = Int($0.rounded()) }
        )
    }

    private var advertisedUUIDsBinding: Binding<String> {
        Binding(
            get: { device.advertisedServiceUUIDs.joined(separator: ", ") },
            set: { new in
                device.advertisedServiceUUIDs = new
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
        )
    }

    private var manufacturerDataBinding: Binding<String> {
        Binding(
            get: { device.manufacturerData?.map { String(format: "%02X", $0) }.joined() ?? "" },
            set: { new in
                let hex = new.filter { $0.isHexDigit }
                var data = Data()
                var i = hex.startIndex
                while i < hex.endIndex {
                    guard let next = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex) else { break }
                    if let byte = UInt8(hex[i..<next], radix: 16) {
                        data.append(byte)
                    }
                    i = next
                }
                device.manufacturerData = data.isEmpty ? nil : data
            }
        )
    }
}

struct DeviceEditorWindowContent: View {
    let deviceId: UUID?
    @ObservedObject var store: MockStore

    var body: some View {
        if let deviceId, let idx = store.devices.firstIndex(where: { $0.id == deviceId }) {
            DeviceEditorView(device: $store.devices[idx], onSave: { store.save() })
        } else {
            VStack(spacing: 12) {
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("Device no longer exists")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct DeviceEditorWindowActivator: NSViewRepresentable {
    final class Coordinator {
        var didActivate = false
        var attempts = 0
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        activateWhenReady(view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        activateWhenReady(nsView, coordinator: context.coordinator)
    }

    private func activateWhenReady(_ view: NSView, coordinator: Coordinator) {
        guard !coordinator.didActivate, coordinator.attempts < 20 else { return }
        coordinator.attempts += 1

        DispatchQueue.main.async {
            guard let window = view.window else {
                activateWhenReady(view, coordinator: coordinator)
                return
            }

            coordinator.didActivate = true
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            NSRunningApplication.current.activate(options: [.activateAllWindows])
            NSApplication.shared.activate()
        }
    }
}
