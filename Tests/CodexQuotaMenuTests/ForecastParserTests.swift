import XCTest
@testable import CodexQuotaMenu

final class ForecastParserTests: XCTestCase {
    func testParsesPrimaryForecast() throws {
        let json = #"{"updated_at":"2026-08-13T02:43:49.324Z","probabilities":{"rounded_24h":30,"rounded_48h":50},"confidence":"medium","last_reset_at":"2026-08-13T01:01:37.000Z"}"#

        let value = try ForecastParser.parsePrimary(Data(json.utf8))

        XCTAssertEqual(value.probability24h, 30)
        XCTAssertEqual(value.probability48h, 50)
        XCTAssertEqual(value.confidence, .medium)
        XCTAssertEqual(value.updatedAt, fractionalDate("2026-08-13T02:43:49.324Z"))
        XCTAssertEqual(value.lastResetAt, fractionalDate("2026-08-13T01:01:37.000Z"))
    }

    func testAcceptsProbabilityBoundariesAndNullLastReset() throws {
        let json = #"{"updated_at":"2026-08-13T02:43:49Z","probabilities":{"rounded_24h":0,"rounded_48h":100},"confidence":"low","last_reset_at":null}"#

        let value = try ForecastParser.parsePrimary(Data(json.utf8))

        XCTAssertEqual(value.probability24h, 0)
        XCTAssertEqual(value.probability48h, 100)
        XCTAssertNil(value.lastResetAt)
    }

    func testRejectsOutOfRangePrimaryProbability() {
        let json = #"{"updated_at":"2026-08-13T02:43:49Z","probabilities":{"rounded_24h":-1,"rounded_48h":101},"confidence":"high","last_reset_at":null}"#

        XCTAssertThrowsError(try ForecastParser.parsePrimary(Data(json.utf8))) { error in
            XCTAssertEqual(error as? ForecastParsingError, .probabilityOutOfRange)
        }
    }

    func testRejectsIncompleteOrInvalidPrimaryResponse() {
        let fixtures = [
            #"{"updated_at":"2026-08-13T02:43:49Z","probabilities":{"rounded_48h":50},"confidence":"medium"}"#,
            #"{"updated_at":"not-a-date","probabilities":{"rounded_24h":30,"rounded_48h":50},"confidence":"medium"}"#,
            #"{"updated_at":"2026-08-13T02:43:49Z","probabilities":{"rounded_24h":30,"rounded_48h":50},"confidence":"unknown"}"#,
            #"not-json"#
        ]

        for fixture in fixtures {
            XCTAssertThrowsError(try ForecastParser.parsePrimary(Data(fixture.utf8)))
        }
    }

    func testParsesFastSignalWithFetchTime() throws {
        let now = Date(timeIntervalSince1970: 1_786_589_031)
        let json = #"{"reset":{"calibrationState":"experimental","score48h":99,"unit":"probability"}}"#

        let value = try ForecastParser.parseFast(Data(json.utf8), fetchedAt: now)

        XCTAssertEqual(value.score48h, 99)
        XCTAssertEqual(value.calibrationState, "experimental")
        XCTAssertEqual(value.fetchedAt, now)
    }

    func testRejectsInvalidFastSignalResponse() {
        let fixtures = [
            #"{"reset":{"calibrationState":"experimental","score48h":101,"unit":"probability"}}"#,
            #"{"reset":{"calibrationState":"experimental","score48h":99,"unit":"score"}}"#,
            #"{"reset":{"score48h":99,"unit":"probability"}}"#,
            #"{}"#
        ]

        for fixture in fixtures {
            XCTAssertThrowsError(
                try ForecastParser.parseFast(Data(fixture.utf8), fetchedAt: Date(timeIntervalSince1970: 1))
            )
        }
    }
}

private extension ForecastParserTests {
    func fractionalDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}
