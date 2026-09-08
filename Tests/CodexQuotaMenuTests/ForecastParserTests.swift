import XCTest
@testable import CodexQuotaMenu

final class ForecastParserTests: XCTestCase {
    func testParsesWillCodexResetSummaryAndPreservesBothTimestamps() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let isoDate = ISO8601DateFormatter()
        isoDate.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let sourceUpdatedAt = try XCTUnwrap(isoDate.date(from: "2026-09-04T02:42:22.950Z"))
        let data = Data(#"{"code":0,"data":{"updatedAt":"2026-09-04T02:42:22.950Z","probability48h":99}}"#.utf8)

        let value = try ForecastParser.parse(data, fetchedAt: fetchedAt)

        XCTAssertEqual(value.probability48h, 99)
        XCTAssertEqual(value.sourceUpdatedAt, sourceUpdatedAt)
        XCTAssertEqual(value.fetchedAt, fetchedAt)
    }

    func testAcceptsProbabilityBoundaries() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1)
        for score in [0, 100] {
            let data = Data(#"{"code":0,"data":{"updatedAt":"2026-09-04T02:42:22.950Z","probability48h":\#(score)}}"#.utf8)
            XCTAssertEqual(try ForecastParser.parse(data, fetchedAt: fetchedAt).probability48h, score)
        }
    }

    func testRejectsOutOfRangeProbability() {
        for score in [-1, 101] {
            let data = Data(#"{"code":0,"data":{"updatedAt":"2026-09-04T02:42:22.950Z","probability48h":\#(score)}}"#.utf8)
            XCTAssertThrowsError(try ForecastParser.parse(data, fetchedAt: Date())) { error in
                XCTAssertEqual(error as? ForecastParsingError, .probabilityOutOfRange)
            }
        }
    }

    func testRejectsNonzeroCode() {
        let data = Data(#"{"code":1,"data":{"updatedAt":"2026-09-04T02:42:22.950Z","probability48h":99}}"#.utf8)
        XCTAssertThrowsError(try ForecastParser.parse(data, fetchedAt: Date()))
    }

    func testRejectsMissingData() {
        let data = Data(#"{"code":0}"#.utf8)
        XCTAssertThrowsError(try ForecastParser.parse(data, fetchedAt: Date()))
    }

    func testRejectsMissingOrInvalidUpdatedAt() {
        let fixtures = [
            #"{"code":0,"data":{"probability48h":99}}"#,
            #"{"code":0,"data":{"updatedAt":"not-a-date","probability48h":99}}"#
        ]

        for fixture in fixtures {
            XCTAssertThrowsError(try ForecastParser.parse(Data(fixture.utf8), fetchedAt: Date()))
        }
    }

    func testRejectsMissingStringAndFractionalProbability() {
        let fixtures = [
            #"{"code":0,"data":{"updatedAt":"2026-09-04T02:42:22.950Z"}}"#,
            #"{"code":0,"data":{"updatedAt":"2026-09-04T02:42:22.950Z","probability48h":"99"}}"#,
            #"{"code":0,"data":{"updatedAt":"2026-09-04T02:42:22.950Z","probability48h":99.5}}"#
        ]

        for fixture in fixtures {
            XCTAssertThrowsError(try ForecastParser.parse(Data(fixture.utf8), fetchedAt: Date()))
        }
    }

    func testRejectsMalformedJSON() {
        XCTAssertThrowsError(try ForecastParser.parse(Data("not-json".utf8), fetchedAt: Date()))
    }

    func testIgnoresUnrelatedUnknownKeys() throws {
        let data = Data(#"{"code":0,"requestId":"abc","data":{"updatedAt":"2026-09-04T02:42:22.950Z","probability48h":99,"events":[{"private":"ignored"}]},"extra":true}"#.utf8)

        XCTAssertEqual(try ForecastParser.parse(data, fetchedAt: Date()).probability48h, 99)
    }
}
