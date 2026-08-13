import Foundation

protocol HTTPDataLoading {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

protocol ForecastFetching {
    func fetchPrimary() async throws -> PrimaryForecast
    func fetchFast(now: Date) async throws -> FastForecastSignal
}

enum ForecastNetworkError: Error, Equatable {
    case httpStatus(Int)
    case invalidResponse
}

final class URLSessionHTTPDataLoader: HTTPDataLoading {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 10
        session = URLSession(configuration: configuration)
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw ForecastNetworkError.invalidResponse
        }
        return (data, response)
    }
}

final class ForecastClient: ForecastFetching {
    private static let primaryURL = URL(string: "https://codex-reset.com/api/forecast")!
    private static let fastURL = URL(string: "https://codexreset.org/api/monitor-summary")!

    private let loader: HTTPDataLoading
    private let appVersion: String

    init(loader: HTTPDataLoading = URLSessionHTTPDataLoader(), appVersion: String) {
        self.loader = loader
        self.appVersion = appVersion
    }

    func fetchPrimary() async throws -> PrimaryForecast {
        let data = try await load(Self.primaryURL)
        return try ForecastParser.parsePrimary(data)
    }

    func fetchFast(now: Date) async throws -> FastForecastSignal {
        let data = try await load(Self.fastURL)
        return try ForecastParser.parseFast(data, fetchedAt: now)
    }

    private func load(_ url: URL) async throws -> Data {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 10
        )
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodexQuotaMenu/\(appVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await loader.data(for: request)
        guard (200...299).contains(response.statusCode) else {
            throw ForecastNetworkError.httpStatus(response.statusCode)
        }
        return data
    }
}
