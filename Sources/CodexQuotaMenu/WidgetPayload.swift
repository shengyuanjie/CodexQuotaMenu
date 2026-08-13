import Foundation

enum WidgetQuotaStatus: String, Encodable {
    case fresh
    case unavailable
}

struct WidgetQuota: Encodable {
    let weeklyRemainingPercent: Int?
    let weeklyResetsAt: Date?
    let shortRemainingPercent: Int?
    let shortResetsAt: Date?
}

struct WidgetTaskSummary: Encodable {
    let runningCount: Int
}

struct WidgetForecast: Encodable {
    let probability48h: Int?
    let calibrationState: String?
    let updatedAt: Date?
    let isCached: Bool
    let source: String
}

struct WidgetPayload: Encodable {
    let schemaVersion: Int
    let generatedAt: Date
    let quotaStatus: WidgetQuotaStatus
    let quota: WidgetQuota?
    let tasks: WidgetTaskSummary
    let forecastStatus: ForecastDisplayStatus
    let forecast: WidgetForecast?

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case generatedAt
        case quotaStatus
        case quota
        case tasks
        case forecastStatus
        case forecast
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(generatedAt, forKey: .generatedAt)
        try container.encode(quotaStatus, forKey: .quotaStatus)
        if let quota {
            try container.encode(quota, forKey: .quota)
        } else {
            try container.encodeNil(forKey: .quota)
        }
        try container.encode(tasks, forKey: .tasks)
        try container.encode(forecastStatus, forKey: .forecastStatus)
        if let forecast {
            try container.encode(forecast, forKey: .forecast)
        } else {
            try container.encodeNil(forKey: .forecast)
        }
    }
}

enum WidgetPayloadBuilder {
    static func build(
        usage: UsageSnapshot?,
        tasks: TaskSnapshot?,
        forecast: ForecastDisplaySnapshot,
        generatedAt: Date
    ) -> WidgetPayload {
        let quota = usage.map { snapshot in
            WidgetQuota(
                weeklyRemainingPercent: snapshot.weeklyWindow?.remainingPercent,
                weeklyResetsAt: snapshot.weeklyWindow?.resetsAt,
                shortRemainingPercent: snapshot.shortWindow?.remainingPercent,
                shortResetsAt: snapshot.shortWindow?.resetsAt
            )
        }
        let widgetForecast: WidgetForecast?
        if forecast.status == .unavailable {
            widgetForecast = nil
        } else {
            widgetForecast = WidgetForecast(
                probability48h: forecast.probability48h,
                calibrationState: forecast.calibrationState,
                updatedAt: forecast.updatedAt,
                isCached: forecast.isCached,
                source: "codexreset.org"
            )
        }
        return WidgetPayload(
            schemaVersion: 2,
            generatedAt: generatedAt,
            quotaStatus: usage == nil ? .unavailable : .fresh,
            quota: quota,
            tasks: WidgetTaskSummary(runningCount: tasks?.running.count ?? 0),
            forecastStatus: forecast.status,
            forecast: widgetForecast
        )
    }
}

extension JSONEncoder {
    static var widgetEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
