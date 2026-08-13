import Foundation

struct ResetForecast: Codable, Equatable {
    let probability48h: Int
    let calibrationState: String
    let fetchedAt: Date
}

enum ForecastParsingError: Error, Equatable {
    case invalidResponse
    case probabilityOutOfRange
}

enum ForecastParser {
    static func parse(_ data: Data, fetchedAt: Date) throws -> ResetForecast {
        do {
            let wire = try JSONDecoder().decode(MonitorSummary.self, from: data)
            guard wire.reset.unit == "probability" else { throw ForecastParsingError.invalidResponse }
            guard (0...100).contains(wire.reset.score48h) else { throw ForecastParsingError.probabilityOutOfRange }
            return ResetForecast(probability48h: wire.reset.score48h, calibrationState: wire.reset.calibrationState, fetchedAt: fetchedAt)
        } catch let error as ForecastParsingError {
            throw error
        } catch {
            throw ForecastParsingError.invalidResponse
        }
    }
}

private struct MonitorSummary: Decodable {
    struct Reset: Decodable {
        let calibrationState: String
        let score48h: Int
        let unit: String
    }
    let reset: Reset
}
