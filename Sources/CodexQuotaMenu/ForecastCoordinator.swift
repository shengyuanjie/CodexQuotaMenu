import Foundation

actor ForecastCoordinator {
    private let client: ForecastFetching
    private let cache: ForecastCaching
    private var forecast: ResetForecast?
    private var refreshTask: Task<Result<ResetForecast, Error>, Never>?

    init(client: ForecastFetching, cache: ForecastCaching) {
        self.client = client
        self.cache = cache
        forecast = cache.load()
    }

    func current(now: Date) -> ForecastDisplaySnapshot {
        ForecastPolicy.resolve(forecast: forecast, now: now)
    }

    func refresh(now: Date) async -> ForecastDisplaySnapshot {
        let task: Task<Result<ResetForecast, Error>, Never>
        if let refreshTask {
            task = refreshTask
        } else {
            let client = self.client
            let newTask = Task<Result<ResetForecast, Error>, Never> {
                do { return Result.success(try await client.fetch(now: now)) }
                catch { return Result.failure(error) }
            }
            refreshTask = newTask
            task = newTask
        }
        let result = await task.value
        refreshTask = nil
        if case .success(let value) = result {
            forecast = value
            cache.save(value)
        }
        return ForecastPolicy.resolve(forecast: forecast, now: now)
    }
}
