import Foundation

enum ForecastDisplayStatus: String, Codable, Equatable {
    case recentlyReset
    case strongSignal
    case forecast
    case cached
    case unavailable
}

struct ForecastDisplaySnapshot: Equatable {
    let status: ForecastDisplayStatus
    let probability24h: Int?
    let probability48h: Int?
    let confidence: ForecastConfidence?
    let strongSignal: Bool
    let lastResetAt: Date?
    let updatedAt: Date?
    let isCached: Bool

    static let unavailable = ForecastDisplaySnapshot(
        status: .unavailable,
        probability24h: nil,
        probability48h: nil,
        confidence: nil,
        strongSignal: false,
        lastResetAt: nil,
        updatedAt: nil,
        isCached: false
    )
}

enum ForecastPolicy {
    static let normalAge: TimeInterval = 15 * 60
    static let maximumAge: TimeInterval = 2 * 60 * 60
    static let recentResetAge: TimeInterval = 6 * 60 * 60
    static let fastSignalMaximumAge: TimeInterval = 10 * 60
    static let futureTolerance: TimeInterval = 5 * 60

    static func resolve(
        primary: PrimaryForecast?,
        fast: FastForecastSignal?,
        now: Date
    ) -> ForecastDisplaySnapshot {
        let usablePrimary = primary.flatMap { value -> (PrimaryForecast, TimeInterval)? in
            let age = now.timeIntervalSince(value.updatedAt)
            guard age >= -futureTolerance, age <= maximumAge else { return nil }
            return (value, age)
        }

        let recentlyReset = usablePrimary?.0.lastResetAt.map { resetAt in
            let resetAge = now.timeIntervalSince(resetAt)
            return resetAge >= -futureTolerance && resetAge <= recentResetAge
        } ?? false

        let strongSignal = !recentlyReset && fast.map { value in
            let age = now.timeIntervalSince(value.fetchedAt)
            return value.calibrationState == "experimental"
                && value.score48h >= 90
                && age >= -futureTolerance
                && age <= fastSignalMaximumAge
        } ?? false

        let status: ForecastDisplayStatus
        let isCached: Bool
        if recentlyReset {
            status = .recentlyReset
            isCached = usablePrimary.map { $0.1 > normalAge } ?? false
        } else if strongSignal {
            status = .strongSignal
            isCached = usablePrimary.map { $0.1 > normalAge } ?? false
        } else if let usablePrimary {
            isCached = usablePrimary.1 > normalAge
            status = isCached ? .cached : .forecast
        } else {
            return .unavailable
        }

        return ForecastDisplaySnapshot(
            status: status,
            probability24h: usablePrimary?.0.probability24h,
            probability48h: usablePrimary?.0.probability48h,
            confidence: usablePrimary?.0.confidence,
            strongSignal: strongSignal,
            lastResetAt: usablePrimary?.0.lastResetAt,
            updatedAt: usablePrimary?.0.updatedAt,
            isCached: isCached
        )
    }
}
