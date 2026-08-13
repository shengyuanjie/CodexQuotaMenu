import XCTest
@testable import CodexQuotaMenu

final class ForecastCoordinatorTests: XCTestCase {
    func testRefreshSavesSuccessfulPrimaryAndCombinesFastSignal() async {
        let now = Date(timeIntervalSince1970: 100_000)
        let primary = fixturePrimary(updatedAt: now, lastResetAt: nil)
        let fast = FastForecastSignal(
            score48h: 99,
            calibrationState: "experimental",
            fetchedAt: now
        )
        let fetcher = StubForecastFetcher(primary: .success(primary), fast: .success(fast))
        let cache = RecordingForecastCache()
        let coordinator = ForecastCoordinator(client: fetcher, cache: cache)

        let value = await coordinator.refresh(now: now)

        XCTAssertEqual(value.status, .strongSignal)
        XCTAssertEqual(cache.saved, primary)
    }

    func testPrimaryFailureUsesValidCacheWhileFastStillWorks() async {
        let now = Date(timeIntervalSince1970: 100_000)
        let cached = fixturePrimary(updatedAt: now.addingTimeInterval(-30 * 60), lastResetAt: nil)
        let fast = FastForecastSignal(
            score48h: 99,
            calibrationState: "experimental",
            fetchedAt: now
        )
        let fetcher = StubForecastFetcher(primary: .failure(TestFailure.failed), fast: .success(fast))
        let cache = RecordingForecastCache(loaded: cached)
        let coordinator = ForecastCoordinator(client: fetcher, cache: cache)

        let value = await coordinator.refresh(now: now)

        XCTAssertEqual(value.status, .strongSignal)
        XCTAssertEqual(value.probability24h, 30)
        XCTAssertTrue(value.isCached)
        XCTAssertNil(cache.saved)
    }

    func testFastFailureDoesNotHideSuccessfulPrimary() async {
        let now = Date(timeIntervalSince1970: 100_000)
        let primary = fixturePrimary(updatedAt: now, lastResetAt: nil)
        let fetcher = StubForecastFetcher(primary: .success(primary), fast: .failure(TestFailure.failed))
        let coordinator = ForecastCoordinator(client: fetcher, cache: RecordingForecastCache())

        let value = await coordinator.refresh(now: now)

        XCTAssertEqual(value.status, .forecast)
        XCTAssertFalse(value.strongSignal)
        XCTAssertEqual(value.probability48h, 50)
    }

    func testBothFailuresWithExpiredCacheBecomeUnavailable() async {
        let now = Date(timeIntervalSince1970: 100_000)
        let expired = fixturePrimary(updatedAt: now.addingTimeInterval(-(2 * 3_600 + 1)), lastResetAt: nil)
        let fetcher = StubForecastFetcher(primary: .failure(TestFailure.failed), fast: .failure(TestFailure.failed))
        let coordinator = ForecastCoordinator(
            client: fetcher,
            cache: RecordingForecastCache(loaded: expired)
        )

        let value = await coordinator.refresh(now: now)

        XCTAssertEqual(value, .unavailable)
    }

    func testConcurrentRefreshesShareOneRequestBatch() async {
        let now = Date(timeIntervalSince1970: 100_000)
        let primary = fixturePrimary(updatedAt: now, lastResetAt: nil)
        let fast = FastForecastSignal(
            score48h: 10,
            calibrationState: "experimental",
            fetchedAt: now
        )
        let fetcher = StubForecastFetcher(
            primary: .success(primary),
            fast: .success(fast),
            delayNanoseconds: 50_000_000
        )
        let coordinator = ForecastCoordinator(client: fetcher, cache: RecordingForecastCache())

        async let first = coordinator.refresh(now: now)
        async let second = coordinator.refresh(now: now)
        _ = await (first, second)
        let counts = await fetcher.callCounts()

        XCTAssertEqual(counts.primary, 1)
        XCTAssertEqual(counts.fast, 1)
    }
}

private extension ForecastCoordinatorTests {
    func fixturePrimary(updatedAt: Date, lastResetAt: Date?) -> PrimaryForecast {
        PrimaryForecast(
            probability24h: 30,
            probability48h: 50,
            confidence: .medium,
            updatedAt: updatedAt,
            lastResetAt: lastResetAt
        )
    }
}

private enum TestFailure: Error {
    case failed
}

private actor StubForecastFetcher: ForecastFetching {
    private let primaryResult: Result<PrimaryForecast, Error>
    private let fastResult: Result<FastForecastSignal, Error>
    private let delayNanoseconds: UInt64
    private var primaryCalls = 0
    private var fastCalls = 0

    init(
        primary: Result<PrimaryForecast, Error>,
        fast: Result<FastForecastSignal, Error>,
        delayNanoseconds: UInt64 = 0
    ) {
        primaryResult = primary
        fastResult = fast
        self.delayNanoseconds = delayNanoseconds
    }

    func fetchPrimary() async throws -> PrimaryForecast {
        primaryCalls += 1
        if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds) }
        return try primaryResult.get()
    }

    func fetchFast(now: Date) async throws -> FastForecastSignal {
        fastCalls += 1
        if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds) }
        return try fastResult.get()
    }

    func callCounts() -> (primary: Int, fast: Int) {
        (primaryCalls, fastCalls)
    }
}

private final class RecordingForecastCache: ForecastCaching {
    private let loaded: PrimaryForecast?
    private(set) var saved: PrimaryForecast?

    init(loaded: PrimaryForecast? = nil) {
        self.loaded = loaded
    }

    func load() -> PrimaryForecast? { loaded }

    func save(_ forecast: PrimaryForecast) {
        saved = forecast
    }
}
