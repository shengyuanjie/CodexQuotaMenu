import Foundation
import XCTest
@testable import CodexQuotaMenu

final class WidgetServerIntegrationTests: XCTestCase {
    func testRealLoopbackRequestsRequireBearerTokenAndReturnPayload() async throws {
        let ready = expectation(description: "listener ready")
        let startState = ListenerStartState()
        let token = "test-token-not-a-production-secret"
        let payload = Data(#"{"schemaVersion":2}"#.utf8)
        let server = WidgetServer(
            tokenProvider: { token },
            payloadProvider: { payload },
            stateHandler: { state in
                guard state == .ready || state == .failed else { return }
                Task {
                    if await startState.record(state) {
                        ready.fulfill()
                    }
                }
            }
        )
        try server.start()
        defer { server.stop() }
        await fulfillment(of: [ready], timeout: 3)
        let listenerState = await startState.value
        guard listenerState == .ready else {
            throw XCTSkip("The execution sandbox does not allow loopback listeners")
        }

        let unauthorized = try await request(token: nil)
        XCTAssertEqual(unauthorized.statusCode, 401)

        let authorized = try await request(token: token)
        XCTAssertEqual(authorized.statusCode, 200)
        XCTAssertEqual(authorized.data, payload)
        XCTAssertEqual(authorized.contentLength, payload.count)
    }

    private func request(token: String?) async throws -> (
        statusCode: Int,
        contentLength: Int,
        data: Data
    ) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(WidgetServer.port)/v1/widget")!)
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        return (
            statusCode: http.statusCode,
            contentLength: Int(http.value(forHTTPHeaderField: "Content-Length") ?? "") ?? -1,
            data: data
        )
    }
}

private actor ListenerStartState {
    private(set) var value: WidgetServerState?

    func record(_ state: WidgetServerState) -> Bool {
        guard value == nil else { return false }
        value = state
        return true
    }
}
