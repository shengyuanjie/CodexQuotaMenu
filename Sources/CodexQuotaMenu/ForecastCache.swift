import Foundation

protocol ForecastCaching {
    func load() -> ResetForecast?
    func save(_ forecast: ResetForecast)
}

final class UserDefaultsForecastCache: ForecastCaching {
    static let storageKey = "globalReset.resetMonitorForecast.v2"
    static let legacyStorageKey = "globalReset.primaryForecast.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.removeObject(forKey: Self.legacyStorageKey)
    }

    func load() -> ResetForecast? {
        guard let data = defaults.data(forKey: Self.storageKey) else { return nil }
        return try? JSONDecoder().decode(ResetForecast.self, from: data)
    }

    func save(_ forecast: ResetForecast) {
        guard let data = try? JSONEncoder().encode(forecast) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
