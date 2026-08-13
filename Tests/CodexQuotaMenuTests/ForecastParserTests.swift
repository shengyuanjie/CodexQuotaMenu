import XCTest
@testable import CodexQuotaMenu

final class ForecastParserTests: XCTestCase {
    func testParsesMonitorSummaryIntoSingleForecast() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let data = Data(#"{"reset":{"calibrationState":"experimental","score48h":82,"unit":"probability"}}"#.utf8)

        let value = try ForecastParser.parse(data, fetchedAt: fetchedAt)

        XCTAssertEqual(
            value,
            ResetForecast(
                probability48h: 82,
                calibrationState: "experimental",
                fetchedAt: fetchedAt
            )
        )
    }

    func testAcceptsProbabilityBoundaries() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1)
        for score in [0, 100] {
            let data = Data(#"{"reset":{"calibrationState":"experimental","score48h":\#(score),"unit":"probability"}}"#.utf8)
            XCTAssertEqual(try ForecastParser.parse(data, fetchedAt: fetchedAt).probability48h, score)
        }
    }

    func testRejectsOutOfRangeProbability() {
        for score in [-1, 101] {
            let data = Data(#"{"reset":{"calibrationState":"experimental","score48h":\#(score),"unit":"probability"}}"#.utf8)
            XCTAssertThrowsError(try ForecastParser.parse(data, fetchedAt: Date())) { error in
                XCTAssertEqual(error as? ForecastParsingError, .probabilityOutOfRange)
            }
        }
    }

    func testRejectsMalformedMonitorResponses() {
        let fixtures = [
            #"{"reset":{"calibrationState":"experimental","score48h":82,"unit":"percent"}}"#,
            #"{"reset":{"calibrationState":"experimental","score48h":"82","unit":"probability"}}"#,
            #"{"reset":{"score48h":82,"unit":"probability"}}"#,
            #"{}"#,
            #"not-json"#
        ]

        for fixture in fixtures {
            XCTAssertThrowsError(
                try ForecastParser.parse(Data(fixture.utf8), fetchedAt: Date(timeIntervalSince1970: 1))
            )
        }
    }

    func testRejectsCalibrationStateLongerThan64Characters() {
        let oversizedState = String(repeating: "a", count: 65)
        let fixture = #"{"reset":{"calibrationState":"\#(oversizedState)","score48h":82,"unit":"probability"}}"#

        XCTAssertThrowsError(
            try ForecastParser.parse(Data(fixture.utf8), fetchedAt: Date(timeIntervalSince1970: 1))
        ) { error in
            XCTAssertEqual(error as? ForecastParsingError, .invalidResponse)
        }
    }
}
