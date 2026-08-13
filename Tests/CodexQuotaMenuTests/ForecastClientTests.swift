import XCTest
@testable import CodexQuotaMenu

final class ForecastClientTests: XCTestCase {
    func testPrimaryRequestUsesExactPublicAPIContract() async throws {
        let json = #"{"updated_at":"2026-08-13T02:43:49Z","probabilities":{"rounded_24h":30,"rounded_48h":50},"confidence":"medium","last_reset_at":null}"#
        let loader = RecordingHTTPDataLoader(data: Data(json.utf8), statusCode: 200)
        let client = ForecastClient(loader: loader, appVersion: "1.6.0")

        let value = try await client.fetchPrimary()

        XCTAssertEqual(value.probability24h, 30)
        let request = try XCTUnwrap(loader.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://codex-reset.com/api/forecast")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.timeoutInterval, 10)
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "CodexQuotaMenu/1.6.0")
        XCTAssertNil(request.httpBody)
    }

    func testFastRequestUsesExactPublicAPIContract() async throws {
        let json = #"{"reset":{"calibrationState":"experimental","score48h":99,"unit":"probability"}}"#
        let loader = RecordingHTTPDataLoader(data: Data(json.utf8), statusCode: 200)
        let client = ForecastClient(loader: loader, appVersion: "1.6.0")
        let now = Date(timeIntervalSince1970: 123_456)

        let value = try await client.fetchFast(now: now)

        XCTAssertEqual(value.fetchedAt, now)
        XCTAssertEqual(
            loader.requests.first?.url?.absoluteString,
            "https://codexreset.org/api/monitor-summary"
        )
    }

    func testRejectsNonSuccessHTTPStatus() async {
        let loader = RecordingHTTPDataLoader(data: Data("server error".utf8), statusCode: 503)
        let client = ForecastClient(loader: loader, appVersion: "1.6.0")

        do {
            _ = try await client.fetchPrimary()
            XCTFail("Expected the request to fail")
        } catch {
            XCTAssertEqual(error as? ForecastNetworkError, .httpStatus(503))
        }
    }
}

private final class RecordingHTTPDataLoader: HTTPDataLoading {
    private let data: Data
    private let statusCode: Int
    private(set) var requests: [URLRequest] = []

    init(data: Data, statusCode: Int) {
        self.data = data
        self.statusCode = statusCode
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (data, response)
    }
}
