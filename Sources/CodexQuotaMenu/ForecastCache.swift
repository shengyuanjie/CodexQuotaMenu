import Foundation

protocol ForecastCaching {
    func load() -> PrimaryForecast?
    func save(_ forecast: PrimaryForecast)
}

final class UserDefaultsForecastCache: ForecastCaching {
    static let storageKey = "globalReset.primaryForecast.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> PrimaryForecast? {
        guard let data = defaults.data(forKey: Self.storageKey) else { return nil }
        return try? JSONDecoder().decode(PrimaryForecast.self, from: data)
    }

    func save(_ forecast: PrimaryForecast) {
        guard let data = try? JSONEncoder().encode(forecast) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
