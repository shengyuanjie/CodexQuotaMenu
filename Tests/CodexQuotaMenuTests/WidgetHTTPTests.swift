import Foundation
import XCTest
@testable import CodexQuotaMenu

final class WidgetHTTPTests: XCTestCase {
    private let token = "top-secret-token"
    private let payload = Data(#"{"schemaVersion":1}"#.utf8)

    func testAuthorizedGetReturnsPayloadWithExactContentLength() throws {
        let response = respond(
            "GET /v1/widget HTTP/1.1\r\nHost: mac.local\r\nAuthorization: Bearer \(token)\r\n\r\n"
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.body, payload)
        XCTAssertEqual(response.headers["Content-Type"], "application/json; charset=utf-8")
        XCTAssertEqual(response.headers["Content-Length"], String(payload.count))
        XCTAssertEqual(response.headers["Connection"], "close")

        let serialized = String(decoding: response.serialized(), as: UTF8.self)
        let parts = serialized.components(separatedBy: "\r\n\r\n")
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(Data(parts[1].utf8), payload)
    }

    func testMissingOrWrongAuthorizationReturnsUnauthorizedWithoutEchoingToken() {
        let missing = respond("GET /v1/widget HTTP/1.1\r\nHost: mac.local\r\n\r\n")
        let wrong = respond(
            "GET /v1/widget HTTP/1.1\r\nAuthorization: Bearer wrong-\(token)\r\n\r\n"
        )

        XCTAssertEqual(missing.statusCode, 401)
        XCTAssertEqual(wrong.statusCode, 401)
        XCTAssertFalse(String(decoding: wrong.serialized(), as: UTF8.self).contains(token))
    }

    func testUnknownPathReturnsNotFound() {
        let response = respond("GET /other HTTP/1.1\r\nAuthorization: Bearer \(token)\r\n\r\n")

        XCTAssertEqual(response.statusCode, 404)
    }

    func testUnsupportedMethodReturnsMethodNotAllowedAndAllowHeader() {
        let response = respond("POST /v1/widget HTTP/1.1\r\nAuthorization: Bearer \(token)\r\n\r\n")

        XCTAssertEqual(response.statusCode, 405)
        XCTAssertEqual(response.headers["Allow"], "GET")
    }

    func testOversizedMalformedAndDuplicateAuthorizationRequestsReturnBadRequest() {
        let oversized = Data(repeating: Character("x").asciiValue!, count: WidgetHTTP.maximumRequestBytes + 1)
        let malformed = Data("not-http\r\n\r\n".utf8)
        let duplicate = Data(
            "GET /v1/widget HTTP/1.1\r\nAuthorization: Bearer \(token)\r\nauthorization: Bearer another\r\n\r\n".utf8
        )

        for request in [oversized, malformed, duplicate] {
            let response = WidgetHTTP.respond(
                request: request,
                expectedToken: token,
                payload: payload
            )
            XCTAssertEqual(response.statusCode, 400)
            XCTAssertFalse(String(decoding: response.serialized(), as: UTF8.self).contains(token))
        }
    }

    private func respond(_ request: String) -> WidgetHTTPResponse {
        WidgetHTTP.respond(
            request: Data(request.utf8),
            expectedToken: token,
            payload: payload
        )
    }
}
