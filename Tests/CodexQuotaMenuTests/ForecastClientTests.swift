import XCTest
@testable import CodexQuotaMenu

final class ForecastClientTests: XCTestCase {
    func testRequestUsesExactResetMonitorContract() async throws {
        let json = #"{"reset":{"calibrationState":"experimental","score48h":82,"unit":"probability"}}"#
        let loader = RecordingHTTPDataLoader(data: Data(json.utf8), statusCode: 200)
        let client = ForecastClient(loader: loader, appVersion: "1.6.1")
        let now = Date(timeIntervalSince1970: 123_456)

        let value = try await client.fetch(now: now)

        XCTAssertEqual(value.probability48h, 82)
        XCTAssertEqual(value.fetchedAt, now)
        let request = try XCTUnwrap(loader.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://codexreset.org/api/monitor-summary")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.timeoutInterval, 10)
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "CodexQuotaMenu/1.6.1")
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(loader.requests.count, 1)
    }

    func testRejectsNonSuccessHTTPStatus() async {
        let loader = RecordingHTTPDataLoader(data: Data("server error".utf8), statusCode: 503)
        let client = ForecastClient(loader: loader, appVersion: "1.6.1")

        do {
            _ = try await client.fetch(now: Date(timeIntervalSince1970: 1))
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
