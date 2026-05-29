import Foundation

enum AppPreferences {
    static let dismissControlWindowOnDeactivateKey = "DismissControlWindowOnDeactivate"
    static let controlWindowBehaviorDidChange = Notification.Name("ControlWindowBehaviorDidChange")

    /// When disabled (the default), the passthrough helper is stopped as the app
    /// quits so no orphaned background process keeps holding CoreBluetooth.
    static let keepHelperRunningOnQuitKey = "KeepHelperRunningOnQuit"

    static var dismissControlWindowOnDeactivate: Bool {
        UserDefaults.standard.bool(forKey: dismissControlWindowOnDeactivateKey)
    }

    static var keepHelperRunningOnQuit: Bool {
        UserDefaults.standard.bool(forKey: keepHelperRunningOnQuitKey)
    }
}
