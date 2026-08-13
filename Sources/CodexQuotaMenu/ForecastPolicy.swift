import Foundation

enum ForecastDisplayStatus: String, Codable, Equatable {
    case fresh
    case cached
    case unavailable
}

struct ForecastDisplaySnapshot: Equatable {
    let status: ForecastDisplayStatus
    let probability48h: Int?
    let calibrationState: String?
    let updatedAt: Date?
    let isCached: Bool

    static let unavailable = ForecastDisplaySnapshot(
        status: .unavailable,
        probability48h: nil,
        calibrationState: nil,
        updatedAt: nil,
        isCached: false
    )
}

enum ForecastPolicy {
    static let normalAge: TimeInterval = 15 * 60
    static let maximumAge: TimeInterval = 2 * 60 * 60
    static let futureTolerance: TimeInterval = 5 * 60

    static func resolve(forecast: ResetForecast?, now: Date) -> ForecastDisplaySnapshot {
        guard let forecast else { return .unavailable }
        let age = now.timeIntervalSince(forecast.fetchedAt)
        guard age >= -futureTolerance, age <= maximumAge else { return .unavailable }
        let isCached = age > normalAge
        return ForecastDisplaySnapshot(
            status: isCached ? .cached : .fresh,
            probability48h: forecast.probability48h,
            calibrationState: forecast.calibrationState,
            updatedAt: forecast.fetchedAt,
            isCached: isCached
        )
    }
}
