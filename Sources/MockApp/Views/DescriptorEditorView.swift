import SwiftUI

struct DescriptorEditorView: View {
    @Binding var descriptor: MockDescriptor

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .foregroundStyle(.purple)
                .frame(width: 16, alignment: .trailing)
                .font(.caption2)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(wellKnownName ?? "Descriptor")
                        .font(.caption.weight(.medium))
                    Spacer()
                    TextField("UUID", text: $descriptor.uuid)
                        .font(.system(.caption, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 120)
                }
                TextField("Value (hex)", text: valueHexBinding)
                    .font(.system(.caption, design: .monospaced))
            }
        }
        .padding(.leading, 8)
    }

    private var valueHexBinding: Binding<String> {
        Binding(
            get: { descriptor.value?.map { String(format: "%02X", $0) }.joined() ?? "" },
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
                descriptor.value = data.isEmpty ? nil : data
            }
        )
    }

    private var wellKnownName: String? {
        WellKnownUUIDs.descriptors.first { $0.uuid.uppercased() == descriptor.uuid.uppercased() }?.name
    }
}
