import Foundation

struct WidgetPreferences {
    static let serverEnabledKey = "widgetServer.enabled"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isServerEnabled: Bool {
        get { defaults.bool(forKey: Self.serverEnabledKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.serverEnabledKey) }
    }
}
