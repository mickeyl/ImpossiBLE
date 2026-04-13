import SwiftUI

struct ServiceEditorView: View {
    @Binding var service: MockService
    var peripheralUUID: String

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Group {
                HStack {
                    Text("UUID")
                        .foregroundStyle(.secondary)
                    Spacer()
                    TextField("Service UUID", text: $service.uuid)
                        .font(.system(.body, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 200)
                }

                Toggle("Primary", isOn: $service.isPrimary)

                ForEach($service.characteristics) { $characteristic in
                    CharacteristicEditorView(characteristic: $characteristic)
                }
                .onDelete { offsets in
                    service.characteristics.remove(atOffsets: offsets)
                }

                Button {
                    service.characteristics.append(MockCharacteristic())
                } label: {
                    Label("Add Characteristic", systemImage: "plus")
                        .font(.caption)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "shippingbox")
                    .foregroundStyle(.orange)
                    .frame(width: 16, alignment: .trailing)
                VStack(alignment: .leading, spacing: 1) {
                    Text(wellKnownServiceName ?? service.uuid)
                        .font(.subheadline.weight(.medium))
                    if wellKnownServiceName != nil {
                        Text(service.uuid)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text("\(service.characteristics.count) char")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var wellKnownServiceName: String? {
        WellKnownUUIDs.services.first { $0.uuid.uppercased() == service.uuid.uppercased() }?.name
    }
}
