import Foundation

actor ForecastCoordinator {
    private let client: ForecastFetching
    private let cache: ForecastCaching
    private var primary: PrimaryForecast?
    private var fast: FastForecastSignal?
    private var refreshTask: Task<ForecastFetchBatch, Never>?

    init(client: ForecastFetching, cache: ForecastCaching) {
        self.client = client
        self.cache = cache
        primary = cache.load()
    }

    func current(now: Date) -> ForecastDisplaySnapshot {
        ForecastPolicy.resolve(primary: primary, fast: fast, now: now)
    }

    func refresh(now: Date) async -> ForecastDisplaySnapshot {
        let task: Task<ForecastFetchBatch, Never>
        if let refreshTask {
            task = refreshTask
        } else {
            let client = self.client
            let newTask = Task {
                async let primary = fetchPrimary(using: client)
                async let fast = fetchFast(using: client, now: now)
                return await ForecastFetchBatch(primary: primary, fast: fast)
            }
            refreshTask = newTask
            task = newTask
        }

        let batch = await task.value
        refreshTask = nil

        if case .success(let value) = batch.primary {
            primary = value
            cache.save(value)
        }
        switch batch.fast {
        case .success(let value):
            fast = value
        case .failure:
            fast = nil
        }
        return ForecastPolicy.resolve(primary: primary, fast: fast, now: now)
    }
}

private struct ForecastFetchBatch {
    let primary: Result<PrimaryForecast, Error>
    let fast: Result<FastForecastSignal, Error>
}

private func fetchPrimary(using client: ForecastFetching) async -> Result<PrimaryForecast, Error> {
    do {
        return .success(try await client.fetchPrimary())
    } catch {
        return .failure(error)
    }
}

private func fetchFast(
    using client: ForecastFetching,
    now: Date
) async -> Result<FastForecastSignal, Error> {
    do {
        return .success(try await client.fetchFast(now: now))
    } catch {
        return .failure(error)
    }
}
