import SwiftUI

struct CharacteristicEditorView: View {
    @Binding var characteristic: MockCharacteristic

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Group {
                HStack {
                    Text("UUID")
                        .foregroundStyle(.secondary)
                    Spacer()
                    TextField("Char UUID", text: $characteristic.uuid)
                        .font(.system(.body, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 200)
                }

                propertiesSection

                VStack(alignment: .leading, spacing: 4) {
                    Text("Value (hex)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("e.g. 48656C6C6F", text: valueHexBinding)
                        .font(.system(.body, design: .monospaced))
                    if let data = characteristic.value, !data.isEmpty,
                       let str = String(data: data, encoding: .utf8) {
                        Text("UTF-8: \(str)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                descriptorsSection
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "tag")
                    .foregroundStyle(.blue)
                    .frame(width: 16, alignment: .trailing)
                VStack(alignment: .leading, spacing: 1) {
                    Text(wellKnownCharName ?? characteristic.uuid)
                        .font(.caption.weight(.medium))
                    if wellKnownCharName != nil {
                        Text(characteristic.uuid)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(propertiesSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Properties

    private var propertiesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Properties")
                .font(.caption)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 4) {
                ForEach(CharacteristicProperty.all) { prop in
                    Toggle(prop.name, isOn: propertyBinding(prop))
                        .toggleStyle(.checkbox)
                        .font(.caption)
                }
            }
        }
    }

    private func propertyBinding(_ prop: CharacteristicProperty) -> Binding<Bool> {
        Binding(
            get: { characteristic.properties & prop.rawValue != 0 },
            set: { new in
                if new {
                    characteristic.properties |= prop.rawValue
                } else {
                    characteristic.properties &= ~prop.rawValue
                }
            }
        )
    }

    private var propertiesSummary: String {
        var parts: [String] = []
        if characteristic.properties & 0x02 != 0 { parts.append("R") }
        if characteristic.properties & 0x08 != 0 { parts.append("W") }
        if characteristic.properties & 0x04 != 0 { parts.append("Wn") }
        if characteristic.properties & 0x10 != 0 { parts.append("N") }
        if characteristic.properties & 0x20 != 0 { parts.append("I") }
        return parts.isEmpty ? "none" : parts.joined(separator: "/")
    }

    // MARK: - Value

    private var valueHexBinding: Binding<String> {
        Binding(
            get: { characteristic.value?.map { String(format: "%02X", $0) }.joined() ?? "" },
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
                characteristic.value = data.isEmpty ? nil : data
            }
        )
    }

    // MARK: - Descriptors

    private var descriptorsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach($characteristic.descriptors) { $descriptor in
                DescriptorEditorView(descriptor: $descriptor)
            }
            .onDelete { offsets in
                characteristic.descriptors.remove(atOffsets: offsets)
            }

            Button {
                characteristic.descriptors.append(MockDescriptor())
            } label: {
                Label("Add Descriptor", systemImage: "plus")
                    .font(.caption)
            }
        }
    }

    private var wellKnownCharName: String? {
        WellKnownUUIDs.characteristics.first { $0.uuid.uppercased() == characteristic.uuid.uppercased() }?.name
    }
}
