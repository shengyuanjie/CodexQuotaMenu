import XCTest
@testable import CodexQuotaMenu

final class ForecastCoordinatorTests: XCTestCase {
    func testSuccessfulRefreshSavesAndDisplaysSingleForecast() async {
        let now = Date(timeIntervalSince1970: 100_000)
        let forecast = ResetForecast(probability48h: 82, calibrationState: "experimental", fetchedAt: now)
        let fetcher = StubForecastFetcher(result: .success(forecast))
        let cache = RecordingForecastCache()
        let coordinator = ForecastCoordinator(client: fetcher, cache: cache)

        let value = await coordinator.refresh(now: now)

        XCTAssertEqual(value.status, .fresh)
        XCTAssertEqual(value.probability48h, 82)
        XCTAssertEqual(cache.saved, forecast)
    }

    func testFailurePreservesValidCachedForecast() async {
        let now = Date(timeIntervalSince1970: 100_000)
        let cached = ResetForecast(probability48h: 77, calibrationState: "experimental", fetchedAt: now.addingTimeInterval(-1_800))
        let coordinator = ForecastCoordinator(client: StubForecastFetcher(result: .failure(TestFailure.failed)), cache: RecordingForecastCache(loaded: cached))
        let value = await coordinator.refresh(now: now)
        XCTAssertEqual(value.status, .cached)
        XCTAssertEqual(value.probability48h, 77)
    }

    func testConcurrentRefreshesShareOneRequest() async {
        let now = Date(timeIntervalSince1970: 100_000)
        let forecast = ResetForecast(probability48h: 82, calibrationState: "experimental", fetchedAt: now)
        let fetcher = StubForecastFetcher(result: .success(forecast), delayNanoseconds: 50_000_000)
        let coordinator = ForecastCoordinator(client: fetcher, cache: RecordingForecastCache())
        async let first = coordinator.refresh(now: now)
        async let second = coordinator.refresh(now: now)
        _ = await (first, second)
        let calls = await fetcher.callCount()
        XCTAssertEqual(calls, 1)
    }
}

private enum TestFailure: Error { case failed }

private actor StubForecastFetcher: ForecastFetching {
    let result: Result<ResetForecast, Error>
    let delayNanoseconds: UInt64
    var calls = 0
    init(result: Result<ResetForecast, Error>, delayNanoseconds: UInt64 = 0) { self.result = result; self.delayNanoseconds = delayNanoseconds }
    func fetch(now: Date) async throws -> ResetForecast {
        calls += 1
        if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds) }
        return try result.get()
    }
    func callCount() -> Int { calls }
}

private final class RecordingForecastCache: ForecastCaching {
    let loaded: ResetForecast?
    private(set) var saved: ResetForecast?
    init(loaded: ResetForecast? = nil) { self.loaded = loaded }
    func load() -> ResetForecast? { loaded }
    func save(_ forecast: ResetForecast) { saved = forecast }
}
