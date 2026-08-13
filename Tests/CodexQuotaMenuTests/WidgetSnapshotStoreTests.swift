import Foundation
import XCTest
@testable import CodexQuotaMenu

final class WidgetSnapshotStoreTests: XCTestCase {
    func testDefaultSnapshotIsUnavailableSchemaVersionOnePayload() throws {
        let store = WidgetSnapshotStore()

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: store.current()) as? [String: Any]
        )

        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object["quotaStatus"] as? String, "unavailable")
        XCTAssertEqual(object["forecastStatus"] as? String, "unavailable")
        XCTAssertTrue(object["quota"] is NSNull)
        XCTAssertTrue(object["forecast"] is NSNull)
    }

    func testReplacePublishesCompleteSnapshot() {
        let store = WidgetSnapshotStore()
        let expected = Data("replacement".utf8)

        store.replace(with: expected)

        XCTAssertEqual(store.current(), expected)
    }

    func testConcurrentReadsAndWritesOnlyReturnCompleteSnapshots() {
        let store = WidgetSnapshotStore()
        let snapshots = (0..<50).map { Data(repeating: UInt8($0), count: 4_096) }
        let lock = NSLock()
        var incompleteRead = false

        DispatchQueue.concurrentPerform(iterations: 200) { index in
            if index.isMultiple(of: 2) {
                store.replace(with: snapshots[index % snapshots.count])
            } else {
                let current = store.current()
                let isDefaultPayload = (try? JSONSerialization.jsonObject(with: current)) != nil
                let isCompleteReplacement = snapshots.contains(current)
                if !isDefaultPayload && !isCompleteReplacement {
                    lock.lock()
                    incompleteRead = true
                    lock.unlock()
                }
            }
        }

        XCTAssertFalse(incompleteRead)
    }
}
