import SwiftUI

struct DeviceEditorView: View {
    @Binding var device: MockDevice
    var onSave: () -> Void

    var body: some View {
        Form {
            Section("Peripheral") {
                TextField("Name", text: $device.name)
                HStack {
                    Text("UUID")
                        .foregroundStyle(.secondary)
                    Spacer()
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
                HStack {
                    Text("RSSI")
                    Slider(value: rssiBinding, in: -100...0, step: 1) {
                        Text("RSSI")
                    }
                    Text("\(device.rssi) dBm")
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 60, alignment: .trailing)
                }
                Toggle("Connectable", isOn: $device.isConnectable)
            }

            Section("Advertisement") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Service UUIDs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("e.g. 180A, 180D", text: advertisedUUIDsBinding)
                        .font(.system(.body, design: .monospaced))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Manufacturer Data (hex)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("e.g. FF010203", text: manufacturerDataBinding)
                        .font(.system(.body, design: .monospaced))
                }
            }

            Section {
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
            } header: {
                HStack {
                    Text("Services")
                    Spacer()
                    Text("\(device.services.count)")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.visible)
        .navigationTitle(device.name)
        .onChange(of: device) { _, _ in
            onSave()
        }
    }

    private var rssiBinding: Binding<Double> {
        Binding(
            get: { Double(device.rssi) },
            set: { device.rssi = Int($0) }
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
