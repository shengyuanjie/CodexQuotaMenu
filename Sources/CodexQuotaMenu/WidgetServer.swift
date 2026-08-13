import Foundation
import Network

enum WidgetServerState: Equatable {
    case stopped
    case starting
    case ready
    case failed
}

enum WidgetServerError: Error {
    case invalidPort
}

final class WidgetServer: @unchecked Sendable {
    static let port: UInt16 = 47_821
    static let requestTimeout: TimeInterval = 5

    private let tokenProvider: @Sendable () -> String
    private let payloadProvider: @Sendable () -> Data
    private let stateHandler: @Sendable (WidgetServerState) -> Void
    private let queue = DispatchQueue(label: "com.local.codexquotamenu.widget-server")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    init(
        tokenProvider: @escaping @Sendable () -> String,
        payloadProvider: @escaping @Sendable () -> Data,
        stateHandler: @escaping @Sendable (WidgetServerState) -> Void = { _ in }
    ) {
        self.tokenProvider = tokenProvider
        self.payloadProvider = payloadProvider
        self.stateHandler = stateHandler
    }

    func start() throws {
        if queue.sync(execute: { listener != nil }) {
            return
        }
        guard let port = NWEndpoint.Port(rawValue: Self.port) else {
            throw WidgetServerError.invalidPort
        }

        let newListener = try NWListener(using: .tcp, on: port)
        newListener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        newListener.stateUpdateHandler = { [weak self, weak newListener] state in
            guard let self, let newListener else { return }
            self.handleListenerState(state, listener: newListener)
        }

        let shouldStart = queue.sync {
            guard listener == nil else { return false }
            listener = newListener
            return true
        }
        guard shouldStart else {
            newListener.cancel()
            return
        }

        emit(.starting)
        newListener.start(queue: queue)
    }

    func stop() {
        queue.sync {
            let activeConnections = Array(connections.values)
            connections.removeAll()
            for connection in activeConnections {
                connection.stateUpdateHandler = nil
                connection.cancel()
            }

            listener?.newConnectionHandler = nil
            listener?.stateUpdateHandler = nil
            listener?.cancel()
            listener = nil
        }
        emit(.stopped)
    }

    private func handleListenerState(_ state: NWListener.State, listener: NWListener) {
        switch state {
        case .ready:
            emit(.ready)
        case .failed:
            if self.listener === listener {
                self.listener = nil
            }
            listener.cancel()
            emit(.failed)
        case .cancelled:
            if self.listener === listener {
                self.listener = nil
            }
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        let identifier = ObjectIdentifier(connection)
        connections[identifier] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            if case .failed = state {
                self.finish(connection)
            } else if case .cancelled = state {
                self.finish(connection)
            }
        }
        connection.start(queue: queue)

        queue.asyncAfter(deadline: .now() + Self.requestTimeout) { [weak self, weak connection] in
            guard let self, let connection,
                  self.connections[identifier] != nil else { return }
            self.finish(connection)
        }
        receive(from: connection, accumulated: Data())
    }

    private func receive(from connection: NWConnection, accumulated: Data) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: WidgetHTTP.maximumRequestBytes + 1
        ) { [weak self, weak connection] content, _, isComplete, error in
            guard let self, let connection else { return }
            var request = accumulated
            if let content {
                request.append(content)
            }

            guard request.count <= WidgetHTTP.maximumRequestBytes else {
                self.finish(connection)
                return
            }
            if request.range(of: Data("\r\n\r\n".utf8)) != nil {
                let response = WidgetHTTP.respond(
                    request: request,
                    expectedToken: self.tokenProvider(),
                    payload: self.payloadProvider()
                )
                self.send(response, to: connection)
            } else if isComplete || error != nil {
                self.finish(connection)
            } else {
                self.receive(from: connection, accumulated: request)
            }
        }
    }

    private func send(_ response: WidgetHTTPResponse, to connection: NWConnection) {
        connection.send(content: response.serialized(), completion: .contentProcessed {
            [weak self, weak connection] _ in
            guard let self, let connection else { return }
            self.finish(connection)
        })
    }

    private func finish(_ connection: NWConnection) {
        let identifier = ObjectIdentifier(connection)
        guard connections.removeValue(forKey: identifier) != nil else { return }
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    private func emit(_ state: WidgetServerState) {
        stateHandler(state)
    }
}
