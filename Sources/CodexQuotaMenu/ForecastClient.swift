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

struct ForecastPrefixAccumulator {
    private enum LexerState {
        case idle
        case string(escaped: Bool)
        case scalar
    }

    private enum Token {
        case string(String)
        case scalar(Data)
        case symbol(UInt8)
    }

    private enum ContainerKind {
        case object
        case array
    }

    private enum ObjectRole {
        case root
        case data
        case other
    }

    private enum ParseState {
        case firstKeyOrEnd
        case key
        case colon
        case objectValue
        case objectCommaOrEnd
        case firstArrayValueOrEnd
        case arrayValue
        case arrayCommaOrEnd
    }

    private struct Frame {
        let kind: ContainerKind
        let role: ObjectRole
        var state: ParseState
        var key: String?
    }

    private let capacity: Int
    private static let maximumTokenBytes = 4 * 1_024
    private static let maximumNestingDepth = 32
    private var scannedByteCount = 0
    private var lexerState = LexerState.idle
    private var tokenBytes = Data()
    private var stack: [Frame] = []
    private var rootStarted = false
    private var sawCode = false
    private var sawData = false
    private var sawUpdatedAt = false
    private var sawProbability48h = false
    private var sawEvents = false
    private var code: Int?
    private var updatedAt: String?
    private var probability48h: Int?

    init(capacity: Int = URLSessionHTTPDataLoader.maximumResponseBytes) {
        self.capacity = capacity
    }

    mutating func append(_ chunk: Data) throws -> Data? {
        for byte in chunk {
            guard scannedByteCount < capacity - 1 else {
                throw ForecastNetworkError.responseTooLarge
            }
            scannedByteCount += 1
            if let compact = try consume(byte) {
                return compact
            }
        }
        return nil
    }

    private mutating func consume(_ byte: UInt8) throws -> Data? {
        switch lexerState {
        case .idle:
            return try consumeIdle(byte)
        case let .string(escaped):
            try appendTokenByte(byte)
            if escaped {
                lexerState = .string(escaped: false)
            } else if byte == Self.backslash {
                lexerState = .string(escaped: true)
            } else if byte == Self.quote {
                let raw = tokenBytes
                tokenBytes = Data()
                lexerState = .idle
                guard let value = try? JSONDecoder().decode(String.self, from: raw) else {
                    throw ForecastNetworkError.invalidResponse
                }
                return try process(.string(value))
            }
            return nil
        case .scalar:
            if Self.isWhitespace(byte) || Self.isStructural(byte) {
                let raw = tokenBytes
                tokenBytes = Data()
                lexerState = .idle
                if let compact = try process(.scalar(raw)) {
                    return compact
                }
                return try consumeIdle(byte)
            }
            try appendTokenByte(byte)
            return nil
        }
    }

    private mutating func consumeIdle(_ byte: UInt8) throws -> Data? {
        if Self.isWhitespace(byte) {
            return nil
        }
        if Self.isStructural(byte) {
            return try process(.symbol(byte))
        }
        if byte == Self.quote {
            tokenBytes = Data([byte])
            lexerState = .string(escaped: false)
            return nil
        }
        tokenBytes = Data([byte])
        lexerState = .scalar
        return nil
    }

    private mutating func process(_ token: Token) throws -> Data? {
        guard !stack.isEmpty else {
            guard !rootStarted, case .symbol(Self.openBrace) = token else {
                throw ForecastNetworkError.invalidResponse
            }
            rootStarted = true
            stack.append(Frame(kind: .object, role: .root, state: .firstKeyOrEnd))
            return nil
        }

        let index = stack.index(before: stack.endIndex)
        switch stack[index].state {
        case .firstKeyOrEnd:
            if case .symbol(Self.closeBrace) = token {
                return try closeContainer(expected: .object)
            }
            return try acceptObjectKey(token, at: index)
        case .key:
            return try acceptObjectKey(token, at: index)
        case .colon:
            guard case .symbol(Self.colon) = token else {
                throw ForecastNetworkError.invalidResponse
            }
            stack[index].state = .objectValue
            return nil
        case .objectValue:
            return try acceptObjectValue(token, at: index)
        case .objectCommaOrEnd:
            if case .symbol(Self.comma) = token {
                stack[index].state = .key
                return nil
            }
            guard case .symbol(Self.closeBrace) = token else {
                throw ForecastNetworkError.invalidResponse
            }
            return try closeContainer(expected: .object)
        case .firstArrayValueOrEnd:
            if case .symbol(Self.closeBracket) = token {
                return try closeContainer(expected: .array)
            }
            return try acceptArrayValue(token, at: index)
        case .arrayValue:
            return try acceptArrayValue(token, at: index)
        case .arrayCommaOrEnd:
            if case .symbol(Self.comma) = token {
                stack[index].state = .arrayValue
                return nil
            }
            guard case .symbol(Self.closeBracket) = token else {
                throw ForecastNetworkError.invalidResponse
            }
            return try closeContainer(expected: .array)
        }
    }

    private mutating func acceptObjectKey(_ token: Token, at index: Int) throws -> Data? {
        guard case let .string(key) = token else {
            throw ForecastNetworkError.invalidResponse
        }
        switch (stack[index].role, key) {
        case (.root, "code"):
            guard !sawCode else { throw ForecastNetworkError.invalidResponse }
            sawCode = true
        case (.root, "data"):
            guard !sawData else { throw ForecastNetworkError.invalidResponse }
            sawData = true
        case (.data, "updatedAt"):
            guard !sawUpdatedAt else { throw ForecastNetworkError.invalidResponse }
            sawUpdatedAt = true
        case (.data, "probability48h"):
            guard !sawProbability48h else { throw ForecastNetworkError.invalidResponse }
            sawProbability48h = true
        case (.data, "events"):
            guard !sawEvents else { throw ForecastNetworkError.invalidResponse }
            sawEvents = true
        default:
            break
        }
        stack[index].key = key
        stack[index].state = .colon
        return nil
    }

    private mutating func acceptObjectValue(_ token: Token, at index: Int) throws -> Data? {
        let role = stack[index].role
        guard let key = stack[index].key else {
            throw ForecastNetworkError.invalidResponse
        }
        switch token {
        case let .string(value):
            if role == .data, key == "updatedAt" {
                updatedAt = value
            } else if Self.requiresScalarValue(role: role, key: key) {
                throw ForecastNetworkError.invalidResponse
            }
            finishObjectValue(at: index)
        case let .scalar(raw):
            try validateScalar(raw)
            if role == .root, key == "code" {
                code = try decodeInteger(raw)
            } else if role == .data, key == "probability48h" {
                probability48h = try decodeInteger(raw)
            } else if Self.requiresStringValue(role: role, key: key) ||
                        (role == .root && key == "data") {
                throw ForecastNetworkError.invalidResponse
            }
            finishObjectValue(at: index)
        case .symbol(Self.openBrace):
            if Self.requiresPrimitiveValue(role: role, key: key) {
                throw ForecastNetworkError.invalidResponse
            }
            let childRole: ObjectRole = role == .root && key == "data" ? .data : .other
            finishObjectValue(at: index)
            try ensureNestingCapacity()
            stack.append(Frame(kind: .object, role: childRole, state: .firstKeyOrEnd))
        case .symbol(Self.openBracket):
            if role == .data, key == "events" {
                return try makeCompactSummary()
            }
            if Self.requiresPrimitiveValue(role: role, key: key) ||
                (role == .root && key == "data") {
                throw ForecastNetworkError.invalidResponse
            }
            finishObjectValue(at: index)
            try ensureNestingCapacity()
            stack.append(Frame(kind: .array, role: .other, state: .firstArrayValueOrEnd))
        default:
            throw ForecastNetworkError.invalidResponse
        }
        return nil
    }

    private mutating func acceptArrayValue(_ token: Token, at index: Int) throws -> Data? {
        switch token {
        case .string:
            stack[index].state = .arrayCommaOrEnd
        case let .scalar(raw):
            try validateScalar(raw)
            stack[index].state = .arrayCommaOrEnd
        case .symbol(Self.openBrace):
            stack[index].state = .arrayCommaOrEnd
            try ensureNestingCapacity()
            stack.append(Frame(kind: .object, role: .other, state: .firstKeyOrEnd))
        case .symbol(Self.openBracket):
            stack[index].state = .arrayCommaOrEnd
            try ensureNestingCapacity()
            stack.append(Frame(kind: .array, role: .other, state: .firstArrayValueOrEnd))
        default:
            throw ForecastNetworkError.invalidResponse
        }
        return nil
    }

    private mutating func finishObjectValue(at index: Int) {
        stack[index].key = nil
        stack[index].state = .objectCommaOrEnd
    }

    private mutating func closeContainer(expected: ContainerKind) throws -> Data? {
        guard stack.last?.kind == expected else {
            throw ForecastNetworkError.invalidResponse
        }
        let closed = stack.removeLast()
        if closed.role == .root {
            throw ForecastNetworkError.invalidResponse
        }
        return nil
    }

    private func makeCompactSummary() throws -> Data {
        guard sawCode, sawData, sawUpdatedAt, sawProbability48h, sawEvents,
              let code, let updatedAt, let probability48h else {
            throw ForecastNetworkError.invalidResponse
        }
        let encodedUpdatedAt: Data
        do {
            encodedUpdatedAt = try JSONEncoder().encode(updatedAt)
        } catch {
            throw ForecastNetworkError.invalidResponse
        }
        var result = Data("{\"code\":\(code),\"data\":{\"updatedAt\":".utf8)
        result.append(encodedUpdatedAt)
        result.append(Data(",\"probability48h\":\(probability48h)}}".utf8))
        return result
    }

    private func validateScalar(_ raw: Data) throws {
        do {
            _ = try JSONSerialization.jsonObject(with: raw, options: .fragmentsAllowed)
        } catch {
            throw ForecastNetworkError.invalidResponse
        }
    }

    private func decodeInteger(_ raw: Data) throws -> Int {
        guard let value = try? JSONDecoder().decode(Int.self, from: raw) else {
            throw ForecastNetworkError.invalidResponse
        }
        return value
    }

    private mutating func appendTokenByte(_ byte: UInt8) throws {
        guard tokenBytes.count < Self.maximumTokenBytes else {
            throw ForecastNetworkError.invalidResponse
        }
        tokenBytes.append(byte)
    }

    private func ensureNestingCapacity() throws {
        guard stack.count < Self.maximumNestingDepth else {
            throw ForecastNetworkError.invalidResponse
        }
    }

    private static func requiresPrimitiveValue(role: ObjectRole, key: String) -> Bool {
        (role == .root && key == "code") ||
        (role == .data && (key == "updatedAt" || key == "probability48h"))
    }

    private static func requiresScalarValue(role: ObjectRole, key: String) -> Bool {
        (role == .root && key == "code") || (role == .data && key == "probability48h")
    }

    private static func requiresStringValue(role: ObjectRole, key: String) -> Bool {
        role == .data && key == "updatedAt"
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private static func isStructural(_ byte: UInt8) -> Bool {
        byte == openBrace || byte == closeBrace || byte == openBracket ||
        byte == closeBracket || byte == colon || byte == comma
    }

    private static let quote: UInt8 = 0x22
    private static let backslash: UInt8 = 0x5C
    private static let openBrace: UInt8 = 0x7B
    private static let closeBrace: UInt8 = 0x7D
    private static let openBracket: UInt8 = 0x5B
    private static let closeBracket: UInt8 = 0x5D
    private static let colon: UInt8 = 0x3A
    private static let comma: UInt8 = 0x2C
}

final class URLSessionHTTPDataLoader: HTTPDataLoading {
    static let maximumResponseBytes = 64 * 1_024
    private let configuration: URLSessionConfiguration

    convenience init() {
        self.init(configuration: Self.privateConfiguration())
    }

    init(configuration: URLSessionConfiguration) {
        self.configuration = configuration
    }

    private static func privateConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        return configuration
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let receiver = ForecastPrefixHTTPReceiver(
            configuration: configuration,
            maximumBytes: Self.maximumResponseBytes
        )
        return try await receiver.load(request)
    }
}

private final class ForecastPrefixHTTPReceiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private var accumulator: ForecastPrefixAccumulator
    private var response: HTTPURLResponse?
    private var terminalError: Error?
    private var compactResponse: Data?
    private var cancelledAfterSummary = false
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var session: URLSession?

    init(configuration: URLSessionConfiguration, maximumBytes: Int) {
        self.configuration = configuration
        accumulator = ForecastPrefixAccumulator(capacity: maximumBytes)
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
            terminalError = ForecastNetworkError.invalidResponse
            completionHandler(.cancel)
            return
        }
        self.response = http
        if !(200...299).contains(http.statusCode) {
            terminalError = ForecastNetworkError.httpStatus(http.statusCode)
            completionHandler(.cancel)
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard terminalError == nil, compactResponse == nil else { return }
        do {
            if let compact = try accumulator.append(chunk) {
                compactResponse = compact
                cancelledAfterSummary = true
                dataTask.cancel()
            }
        } catch {
            terminalError = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        self.session = nil
        session.finishTasksAndInvalidate()

        if let terminalError {
            continuation.resume(throwing: terminalError)
        } else if let compactResponse, let response, cancelledAfterSummary {
            continuation.resume(returning: (compactResponse, response))
        } else if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume(throwing: ForecastNetworkError.invalidResponse)
        }
    }
}

final class ForecastClient: ForecastFetching {
    private static let forecastURL = URL(string: "https://willcodexreset.com/api/reset-radar")!

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
