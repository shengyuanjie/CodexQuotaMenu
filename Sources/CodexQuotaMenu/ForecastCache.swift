import Foundation

protocol ForecastCaching {
    func load() -> ResetForecast?
    func save(_ forecast: ResetForecast)
}

final class UserDefaultsForecastCache: ForecastCaching {
    static let storageKey = "globalReset.resetMonitorForecast.v2"
    static let legacyStorageKey = "globalReset.primaryForecast.v1"
    static let maximumCacheBytes = 64 * 1_024
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.removeObject(forKey: Self.legacyStorageKey)
    }

    func load() -> ResetForecast? {
        guard let data = defaults.data(forKey: Self.storageKey) else { return nil }
        guard data.count <= Self.maximumCacheBytes,
              let forecast = try? JSONDecoder().decode(ResetForecast.self, from: data),
              forecast.isValid else {
            defaults.removeObject(forKey: Self.storageKey)
            return nil
        }
        return forecast
    }

    func save(_ forecast: ResetForecast) {
        guard forecast.isValid,
              let data = try? JSONEncoder().encode(forecast),
              data.count <= Self.maximumCacheBytes else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
