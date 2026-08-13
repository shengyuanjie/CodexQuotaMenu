import Foundation

enum ForecastConfidence: String, Codable, Equatable {
    case low
    case medium
    case high
}

struct PrimaryForecast: Codable, Equatable {
    let probability24h: Int
    let probability48h: Int
    let confidence: ForecastConfidence
    let updatedAt: Date
    let lastResetAt: Date?
}

struct FastForecastSignal: Equatable {
    let score48h: Int
    let calibrationState: String
    let fetchedAt: Date
}

enum ForecastParsingError: Error, Equatable {
    case invalidResponse
    case probabilityOutOfRange
}

enum ForecastParser {
    static func parsePrimary(_ data: Data) throws -> PrimaryForecast {
        do {
            let wire = try JSONDecoder().decode(PrimaryForecastWire.self, from: data)
            guard (0...100).contains(wire.probabilities.probability24h),
                  (0...100).contains(wire.probabilities.probability48h) else {
                throw ForecastParsingError.probabilityOutOfRange
            }
            guard let updatedAt = parseISO8601(wire.updatedAt) else {
                throw ForecastParsingError.invalidResponse
            }
            let lastResetAt: Date?
            if let rawLastReset = wire.lastResetAt {
                guard let parsed = parseISO8601(rawLastReset) else {
                    throw ForecastParsingError.invalidResponse
                }
                lastResetAt = parsed
            } else {
                lastResetAt = nil
            }
            return PrimaryForecast(
                probability24h: wire.probabilities.probability24h,
                probability48h: wire.probabilities.probability48h,
                confidence: wire.confidence,
                updatedAt: updatedAt,
                lastResetAt: lastResetAt
            )
        } catch let error as ForecastParsingError {
            throw error
        } catch {
            throw ForecastParsingError.invalidResponse
        }
    }

    static func parseFast(_ data: Data, fetchedAt: Date) throws -> FastForecastSignal {
        do {
            let wire = try JSONDecoder().decode(FastForecastWire.self, from: data)
            guard wire.reset.unit == "probability" else {
                throw ForecastParsingError.invalidResponse
            }
            guard (0...100).contains(wire.reset.score48h) else {
                throw ForecastParsingError.probabilityOutOfRange
            }
            return FastForecastSignal(
                score48h: wire.reset.score48h,
                calibrationState: wire.reset.calibrationState,
                fetchedAt: fetchedAt
            )
        } catch let error as ForecastParsingError {
            throw error
        } catch {
            throw ForecastParsingError.invalidResponse
        }
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }
}

private struct FastForecastWire: Decodable {
    struct Reset: Decodable {
        let calibrationState: String
        let score48h: Int
        let unit: String
    }

    let reset: Reset
}

private struct PrimaryForecastWire: Decodable {
    struct Probabilities: Decodable {
        let probability24h: Int
        let probability48h: Int

        enum CodingKeys: String, CodingKey {
            case probability24h = "rounded_24h"
            case probability48h = "rounded_48h"
        }
    }

    let updatedAt: String
    let probabilities: Probabilities
    let confidence: ForecastConfidence
    let lastResetAt: String?

    enum CodingKeys: String, CodingKey {
        case updatedAt = "updated_at"
        case probabilities
        case confidence
        case lastResetAt = "last_reset_at"
    }
}
