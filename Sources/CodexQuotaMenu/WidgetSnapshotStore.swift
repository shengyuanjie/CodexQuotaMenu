import Foundation

final class WidgetSnapshotStore: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: Data

    init() {
        let payload = WidgetPayloadBuilder.build(
            usage: nil,
            tasks: nil,
            forecast: .unavailable,
            generatedAt: Date()
        )
        snapshot = (try? JSONEncoder.widgetEncoder.encode(payload)) ?? Data(
            #"{"forecast":null,"forecastStatus":"unavailable","generatedAt":"1970-01-01T00:00:00Z","quota":null,"quotaStatus":"unavailable","schemaVersion":2,"tasks":{"runningCount":0}}"#.utf8
        )
    }

    func replace(with data: Data) {
        lock.lock()
        snapshot = data
        lock.unlock()
    }

    func current() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }
}
