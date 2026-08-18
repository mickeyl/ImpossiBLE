import Foundation

enum AppPreferences {
    static let dismissControlWindowOnDeactivateKey = "DismissControlWindowOnDeactivate"
    static let controlWindowBehaviorDidChange = Notification.Name("ControlWindowBehaviorDidChange")

    static var dismissControlWindowOnDeactivate: Bool {
        UserDefaults.standard.bool(forKey: dismissControlWindowOnDeactivateKey)
    }
}
