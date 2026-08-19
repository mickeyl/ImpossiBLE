import SwiftUI

struct ServiceEditorView: View {
    @Binding var service: MockService
    var peripheralUUID: String

    @State private var isExpanded = false

    var body: some View {
        EditorNestedBlock {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    EditorDivider()

                    EditorRow(title: "UUID", labelWidth: 96) {
                        TextField("Service UUID", text: $service.uuid)
                            .font(.system(.body, design: .monospaced))
                            .frame(maxWidth: 260)
                    }

                    EditorRow(title: "Primary", labelWidth: 96) {
                        Toggle("Primary", isOn: $service.isPrimary)
                            .labelsHidden()
                    }

                    VStack(alignment: .leading, spacing: 10) {
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
                        .padding(.leading, 22)
                    }
                }
                .padding(.top, 8)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "shippingbox")
                        .foregroundStyle(.orange)
                        .frame(width: 16, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(wellKnownServiceName ?? service.uuid)
                            .font(.subheadline.weight(.semibold))
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
    }

    private var wellKnownServiceName: String? {
        WellKnownUUIDs.services.first { $0.uuid.uppercased() == service.uuid.uppercased() }?.name
    }
}
