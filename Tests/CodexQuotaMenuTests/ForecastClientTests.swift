import XCTest
@testable import CodexQuotaMenu

final class ForecastClientTests: XCTestCase {
    func testRequestUsesExactWillCodexResetContractWithoutCredentials() async throws {
        let json = #"{"code":0,"data":{"updatedAt":"2026-09-04T02:42:22.950Z","probability48h":82}}"#
        let loader = RecordingHTTPDataLoader(data: Data(json.utf8), statusCode: 200)
        let client = ForecastClient(loader: loader, appVersion: "1.6.1")
        let now = Date(timeIntervalSince1970: 123_456)
        let sourceUpdatedAtFormatter = ISO8601DateFormatter()
        sourceUpdatedAtFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let sourceUpdatedAt = try XCTUnwrap(sourceUpdatedAtFormatter.date(from: "2026-09-04T02:42:22.950Z"))

        let value = try await client.fetch(now: now)

        XCTAssertEqual(value.probability48h, 82)
        XCTAssertEqual(value.sourceUpdatedAt, sourceUpdatedAt)
        XCTAssertEqual(value.fetchedAt, now)
        let request = try XCTUnwrap(loader.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://willcodexreset.com/api/reset-radar")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.timeoutInterval, 10)
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "CodexQuotaMenu/1.6.1")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
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

    func testRejectsForecastResponseLargerThan64KiB() async {
        let loader = RecordingHTTPDataLoader(
            data: Data(repeating: 0x41, count: 65_537),
            statusCode: 200
        )
        let client = ForecastClient(loader: loader, appVersion: "1.6.1")

        do {
            _ = try await client.fetch(now: Date(timeIntervalSince1970: 1))
            XCTFail("Expected oversized response to be rejected")
        } catch {
            XCTAssertEqual(error as? ForecastNetworkError, .responseTooLarge)
        }
    }

    func testURLSessionLoaderStopsAtEventsBoundaryBeforeLargeTail() async throws {
        let configuration = forecastURLProtocolConfiguration()
        ForecastURLProtocol.install(
            prefix: Data(
                #"{"code":0,"data":{"updatedAt":"2026-09-04T02:42:22.950Z","probability48h":99,"events":["#.utf8
            ),
            tail: Data(repeating: 0x41, count: 128 * 1_024)
        )
        defer { ForecastURLProtocol.reset() }

        let client = ForecastClient(
            loader: URLSessionHTTPDataLoader(configurationFactory: { configuration }),
            appVersion: "1.6.1"
        )

        let value = try await client.fetch(now: Date(timeIntervalSince1970: 1))
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(value.probability48h, 99)
        XCTAssertTrue(ForecastURLProtocol.wasStopped)
        XCTAssertFalse(ForecastURLProtocol.didDeliverTail)
    }

    func testTransportFailureAfterSummaryDoesNotBecomeSuccess() async {
        ForecastURLProtocol.install(
            prefix: Data(
                #"{"code":0,"data":{"updatedAt":"2026-09-04T02:42:22.950Z","probability48h":99,"events":["#.utf8
            ),
            tail: Data(),
            postPrefixErrorCode: .timedOut
        )
        defer { ForecastURLProtocol.reset() }
        let client = ForecastClient(
            loader: URLSessionHTTPDataLoader(configurationFactory: forecastURLProtocolConfiguration),
            appVersion: "1.6.1"
        )

        do {
            _ = try await client.fetch(now: Date(timeIntervalSince1970: 1))
            XCTFail("Expected the transport error to win over an internal summary cancellation")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
        } catch {
            XCTFail("Expected URLError.timedOut, got \(error)")
        }
    }

    func testNonInternalCancellationDoesNotBecomeSuccess() async {
        ForecastURLProtocol.install(
            prefix: Data(),
            tail: Data(),
            immediateErrorCode: .cancelled
        )
        defer { ForecastURLProtocol.reset() }
        let client = ForecastClient(
            loader: URLSessionHTTPDataLoader(configurationFactory: forecastURLProtocolConfiguration),
            appVersion: "1.6.1"
        )

        do {
            _ = try await client.fetch(now: Date(timeIntervalSince1970: 1))
            XCTFail("Expected a cancellation without a summary to fail")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cancelled)
        } catch {
            XCTFail("Expected URLError.cancelled, got \(error)")
        }
    }

    func testCancellingCallerCancelsDataTaskAndThrowsCancellationError() async throws {
        ForecastURLProtocol.install(prefix: Data(), tail: Data(), tailDelay: 0.5)
        defer { ForecastURLProtocol.reset() }
        let client = ForecastClient(
            loader: URLSessionHTTPDataLoader(configurationFactory: forecastURLProtocolConfiguration),
            appVersion: "1.6.1"
        )
        let task = Task { try await client.fetch(now: Date(timeIntervalSince1970: 1)) }

        for _ in 0..<50 where !ForecastURLProtocol.wasStarted {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(ForecastURLProtocol.wasStarted)
        task.cancel()

        switch await task.result {
        case .success:
            XCTFail("Expected caller cancellation to fail")
        case let .failure(error):
            XCTAssertTrue(error is CancellationError, "Expected CancellationError, got \(error)")
        }
        // URLSession reports stopLoading asynchronously after caller cancellation returns.
        for _ in 0..<100 where !ForecastURLProtocol.wasStopped {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(ForecastURLProtocol.wasStopped)
    }

    func testPrefixAccumulatorReturnsCompactSummaryWhenFedOneByteAtATime() throws {
        let response = #"{"code":0,"data":{"updatedAt":"2026-09-04T02:42:22.950Z","probability48h":99,"events":[{"payload":"must not be retained"}]}}"#
        var accumulator = ForecastPrefixAccumulator()
        var compact: Data?

        for byte in Data(response.utf8) {
            if let result = try accumulator.append(Data([byte])) {
                compact = result
                break
            }
        }

        XCTAssertEqual(
            compact.flatMap { String(data: $0, encoding: .utf8) },
            #"{"code":0,"data":{"updatedAt":"2026-09-04T02:42:22.950Z","probability48h":99}}"#
        )
    }

    func testPrefixAccumulatorHandlesArbitraryChunksAndIgnoresLargeEventsTailInBoundaryChunk() throws {
        let prefixChunks = [
            #"{"co"#,
            #"de":0,"data":{"updatedAt":"2026-09-04T02:42:22."#,
            #"950Z","probability48h":99,"eve"#
        ]
        var accumulator = ForecastPrefixAccumulator()
        for chunk in prefixChunks {
            XCTAssertNil(try accumulator.append(Data(chunk.utf8)))
        }
        var boundaryChunk = Data(#"nts":[{"payload":""#.utf8)
        boundaryChunk.append(Data(repeating: 0x41, count: 128 * 1_024))
        boundaryChunk.append(Data(#""}]}}"#.utf8))

        let compact = try XCTUnwrap(accumulator.append(boundaryChunk))

        XCTAssertEqual(
            String(data: compact, encoding: .utf8),
            #"{"code":0,"data":{"updatedAt":"2026-09-04T02:42:22.950Z","probability48h":99}}"#
        )
        XCTAssertLessThan(compact.count, 128)
    }

    func testEventsTextInsideQuotedValueIsNotTreatedAsBoundary() {
        let response = #"{"code":0,"data":{"updatedAt":"2026-09-04T02:42:22.950Z","probability48h":99,"note":"events is only text"}}"#
        var accumulator = ForecastPrefixAccumulator()

        XCTAssertThrowsError(try accumulator.append(Data(response.utf8))) { error in
            XCTAssertEqual(error as? ForecastNetworkError, .invalidResponse)
        }
    }

    func testEscapedQuotesDoNotCreateAFalseEventsKey() throws {
        let response = #"{"code":0,"data":{"note":"escaped: \"events\": [false]","updatedAt":"2026-09-04T02:42:22.950Z","probability48h":99,"events":[1]}}"#
        var accumulator = ForecastPrefixAccumulator()
        var compact: Data?

        for byte in Data(response.utf8) {
            if let result = try accumulator.append(Data([byte])) {
                compact = result
                break
            }
        }

        XCTAssertEqual(
            compact.flatMap { String(data: $0, encoding: .utf8) },
            #"{"code":0,"data":{"updatedAt":"2026-09-04T02:42:22.950Z","probability48h":99}}"#
        )
    }

    func testPrefixAccumulatorRejectsDuplicateRequiredKeys() {
        let fixtures = [
            #"{"code":0,"code":0,"data":{"updatedAt":"2026-09-04T02:42:22.950Z","probability48h":99,"events":[]}}"#,
            #"{"code":0,"data":{"updatedAt":"2026-09-04T02:42:22.950Z","probability48h":99},"data":{"events":[]}}"#,
            #"{"code":0,"data":{"updatedAt":"2026-09-04T02:42:22.950Z","updatedAt":"2026-09-04T02:42:22.950Z","probability48h":99,"events":[]}}"#,
            #"{"code":0,"data":{"updatedAt":"2026-09-04T02:42:22.950Z","probability48h":99,"probability48h":99,"events":[]}}"#
        ]

        for fixture in fixtures {
            var accumulator = ForecastPrefixAccumulator()
            XCTAssertThrowsError(try accumulator.append(Data(fixture.utf8)), fixture) { error in
                XCTAssertEqual(error as? ForecastNetworkError, .invalidResponse, fixture)
            }
        }
    }

    func testPrefixAccumulatorRejectsEventsAndSummaryAtWrongNesting() {
        let fixtures = [
            #"{"code":0,"data":{"updatedAt":"2026-09-04T02:42:22.950Z","probability48h":99,"metadata":{"events":[]}}}"#,
            #"{"code":0,"data":{"metadata":{"updatedAt":"2026-09-04T02:42:22.950Z","probability48h":99},"events":[]}}"#,
            #"{"code":0,"data":{"updatedAt":"2026-09-04T02:42:22.950Z","probability48h":99},"events":[]}"#
        ]

        for fixture in fixtures {
            var accumulator = ForecastPrefixAccumulator()
            XCTAssertThrowsError(try accumulator.append(Data(fixture.utf8)), fixture) { error in
                XCTAssertEqual(error as? ForecastNetworkError, .invalidResponse, fixture)
            }
        }
    }

    func testPrefixAccumulatorAllowsExactly64KiBButRejectsTheNextByte() throws {
        var accumulator = ForecastPrefixAccumulator()

        XCTAssertNil(try accumulator.append(Data(repeating: 0x20, count: 65_535)))
        XCTAssertNil(try accumulator.append(Data([0x20])))
        XCTAssertThrowsError(try accumulator.append(Data([0x20]))) { error in
            XCTAssertEqual(error as? ForecastNetworkError, .responseTooLarge)
        }
    }

    func testPrefixAccumulatorAcceptsEventsBoundaryAsByte65536() throws {
        let start = Data(
            #"{"code":0,"data":{"updatedAt":"2026-09-04T02:42:22.950Z","probability48h":99,"#.utf8
        )
        let end = Data(#""events":["#.utf8)
        let paddingCount = 65_536 - start.count - end.count
        XCTAssertGreaterThanOrEqual(paddingCount, 0)
        var prefix = start
        prefix.append(Data(repeating: 0x20, count: paddingCount))
        prefix.append(end)
        XCTAssertEqual(prefix.count, 65_536)
        var accumulator = ForecastPrefixAccumulator()

        let compact = try accumulator.append(prefix)

        XCTAssertEqual(
            compact.flatMap { String(data: $0, encoding: .utf8) },
            #"{"code":0,"data":{"updatedAt":"2026-09-04T02:42:22.950Z","probability48h":99}}"#
        )
    }

    func testPrefixAccumulatorRejectsCompletedResponseWithoutRequiredFieldsOrEvents() {
        let fixtures = [
            #"{"code":0,"data":{"updatedAt":"2026-09-04T02:42:22.950Z","events":[]}}"#,
            #"{"code":0,"data":{"updatedAt":"2026-09-04T02:42:22.950Z","probability48h":99}}"#
        ]

        for fixture in fixtures {
            var accumulator = ForecastPrefixAccumulator()
            XCTAssertThrowsError(try accumulator.append(Data(fixture.utf8)), fixture) { error in
                XCTAssertEqual(error as? ForecastNetworkError, .invalidResponse, fixture)
            }
        }
    }

    func testProductionSessionConfigurationIsPrivateAndShortLived() {
        let configuration = URLSessionHTTPDataLoader.makePrivateConfiguration()

        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 10)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 15)
    }

    private func forecastURLProtocolConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ForecastURLProtocol.self]
        return configuration
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

private final class ForecastURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var prefix = Data()
    private static var tail = Data()
    private static var immediateErrorCode: URLError.Code?
    private static var postPrefixErrorCode: URLError.Code?
    private static var tailDelay: TimeInterval = 0.05
    private static var _wasStarted = false
    private static var _wasStopped = false
    private static var _didDeliverTail = false

    static var wasStarted: Bool { read { _wasStarted } }
    static var wasStopped: Bool { read { _wasStopped } }
    static var didDeliverTail: Bool { read { _didDeliverTail } }

    static func install(
        prefix: Data,
        tail: Data,
        immediateErrorCode: URLError.Code? = nil,
        postPrefixErrorCode: URLError.Code? = nil,
        tailDelay: TimeInterval = 0.05
    ) {
        lock.lock()
        self.prefix = prefix
        self.tail = tail
        self.immediateErrorCode = immediateErrorCode
        self.postPrefixErrorCode = postPrefixErrorCode
        self.tailDelay = tailDelay
        _wasStarted = false
        _wasStopped = false
        _didDeliverTail = false
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        prefix = Data()
        tail = Data()
        immediateErrorCode = nil
        postPrefixErrorCode = nil
        tailDelay = 0.05
        _wasStarted = false
        _wasStopped = false
        _didDeliverTail = false
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let responseData = Self.prefix
        let immediateErrorCode = Self.immediateErrorCode
        let postPrefixErrorCode = Self.postPrefixErrorCode
        let tailDelay = Self.tailDelay
        Self._wasStarted = true
        Self.lock.unlock()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let immediateErrorCode {
            client?.urlProtocol(self, didFailWithError: URLError(immediateErrorCode))
            return
        }
        client?.urlProtocol(self, didLoad: responseData)
        if let postPrefixErrorCode {
            client?.urlProtocol(self, didFailWithError: URLError(postPrefixErrorCode))
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + tailDelay) { [weak self] in
            guard let self else { return }
            Self.lock.lock()
            let shouldDeliver = !Self._wasStopped
            let tail = Self.tail
            Self._didDeliverTail = shouldDeliver
            Self.lock.unlock()
            guard shouldDeliver else { return }
            self.client?.urlProtocol(self, didLoad: tail)
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        Self.lock.lock()
        Self._wasStopped = true
        Self.lock.unlock()
    }

    private static func read<T>(_ value: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return value()
    }
}
