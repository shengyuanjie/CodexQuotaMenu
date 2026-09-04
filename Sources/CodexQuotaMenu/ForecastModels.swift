import Foundation

struct ResetForecast: Codable, Equatable {
    let probability48h: Int
    let sourceUpdatedAt: Date
    let fetchedAt: Date

    var isValid: Bool {
        (0...100).contains(probability48h) &&
        sourceUpdatedAt.timeIntervalSinceReferenceDate.isFinite &&
        fetchedAt.timeIntervalSinceReferenceDate.isFinite
    }

    // Kept as a source-compatible view until the display model removes the
    // legacy calibration field. It is intentionally not persisted by Codable.
    var calibrationState: String? { nil }
}

enum ForecastParsingError: Error, Equatable {
    case invalidResponse
    case probabilityOutOfRange
}

enum ForecastParser {
    static func parse(_ data: Data, fetchedAt: Date) throws -> ResetForecast {
        do {
            let wire = try JSONDecoder().decode(WireResponse.self, from: data)
            guard wire.code == 0, let payload = wire.data else {
                throw ForecastParsingError.invalidResponse
            }
            guard (0...100).contains(payload.probability48h) else {
                throw ForecastParsingError.probabilityOutOfRange
            }
            guard let sourceUpdatedAt = parseISO8601(payload.updatedAt) else {
                throw ForecastParsingError.invalidResponse
            }
            let forecast = ResetForecast(
                probability48h: payload.probability48h,
                sourceUpdatedAt: sourceUpdatedAt,
                fetchedAt: fetchedAt
            )
            guard forecast.isValid else {
                throw ForecastParsingError.invalidResponse
            }
            return forecast
        } catch let error as ForecastParsingError {
            throw error
        } catch {
            throw ForecastParsingError.invalidResponse
        }
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }
}

private struct WireResponse: Decodable {
    let code: Int
    let data: DataPayload?
}

private struct DataPayload: Decodable {
    let updatedAt: String
    let probability48h: Int
}
