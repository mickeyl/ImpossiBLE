import Foundation

enum MockProviderMode: String, CaseIterable {
    case off
    case mock
    case passthrough

    private static let defaultsKey = "SelectedProviderMode"
    private static let legacyServerEnabledKey = "ServerEnabled"

    var title: String {
        switch self {
            case .off: "Off"
            case .mock: "Mock"
            case .passthrough: "Passthrough"
        }
    }

    static var persisted: MockProviderMode {
        if let rawValue = UserDefaults.standard.string(forKey: defaultsKey),
           let mode = MockProviderMode(rawValue: rawValue) {
            return mode
        }

        return UserDefaults.standard.bool(forKey: legacyServerEnabledKey) ? .mock : .off
    }

    func persist() {
        UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey)
    }
}
