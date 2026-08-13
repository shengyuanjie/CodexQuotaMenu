import Foundation

protocol HTTPDataLoading {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

protocol ForecastFetching {
    func fetch(now: Date) async throws -> ResetForecast
}

enum ForecastNetworkError: Error, Equatable {
    case httpStatus(Int)
    case invalidResponse
    case responseTooLarge
}

final class URLSessionHTTPDataLoader: HTTPDataLoading {
    static let maximumResponseBytes = 64 * 1_024
    private let configuration: URLSessionConfiguration

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        self.configuration = configuration
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let receiver = BoundedHTTPReceiver(
            configuration: configuration,
            maximumBytes: Self.maximumResponseBytes
        )
        return try await receiver.load(request)
    }
}

struct BoundedDataAccumulator {
    let capacity: Int
    private(set) var data = Data()

    mutating func append(_ chunk: Data) throws {
        guard chunk.count <= capacity,
              data.count <= capacity - chunk.count else {
            throw ForecastNetworkError.responseTooLarge
        }
        data.append(chunk)
    }
}

private final class BoundedHTTPReceiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let maximumBytes: Int
    private var accumulator: BoundedDataAccumulator
    private var response: HTTPURLResponse?
    private var oversized = false
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var session: URLSession?

    init(configuration: URLSessionConfiguration, maximumBytes: Int) {
        self.configuration = configuration
        self.maximumBytes = maximumBytes
        accumulator = BoundedDataAccumulator(capacity: maximumBytes)
    }

    func load(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.session = session
            session.dataTask(with: request).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        self.response = http
        if response.expectedContentLength > Int64(maximumBytes) {
            oversized = true
            completionHandler(.cancel)
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard !oversized else { return }
        do {
            try accumulator.append(chunk)
        } catch {
            oversized = true
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        self.session = nil
        session.finishTasksAndInvalidate()

        if oversized {
            continuation.resume(throwing: ForecastNetworkError.responseTooLarge)
        } else if let error {
            continuation.resume(throwing: error)
        } else if let response {
            continuation.resume(returning: (accumulator.data, response))
        } else {
            continuation.resume(throwing: ForecastNetworkError.invalidResponse)
        }
    }
}

final class ForecastClient: ForecastFetching {
    private static let forecastURL = URL(string: "https://codexreset.org/api/monitor-summary")!

    private let loader: HTTPDataLoading
    private let appVersion: String

    init(loader: HTTPDataLoading = URLSessionHTTPDataLoader(), appVersion: String) {
        self.loader = loader
        self.appVersion = appVersion
    }

    func fetch(now: Date) async throws -> ResetForecast {
        let data = try await load(Self.forecastURL)
        return try ForecastParser.parse(data, fetchedAt: now)
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
        guard data.count <= URLSessionHTTPDataLoader.maximumResponseBytes else {
            throw ForecastNetworkError.responseTooLarge
        }
        guard (200...299).contains(response.statusCode) else {
            throw ForecastNetworkError.httpStatus(response.statusCode)
        }
        return data
    }
}
