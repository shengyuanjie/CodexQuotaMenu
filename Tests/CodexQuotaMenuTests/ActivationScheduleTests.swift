import XCTest
@testable import CodexQuotaMenu

final class ActivationScheduleTests: XCTestCase {
    func testTimeValidationFormattingSortingAndDuplicates() throws {
        let six = try ActivationTime(hour: 6, minute: 0)
        let eleven = try ActivationTime(hour: 11, minute: 2)
        XCTAssertEqual(six.displayValue, "06:00")
        XCTAssertEqual([eleven, six].sorted(), [six, eleven])
        XCTAssertThrowsError(try ActivationTime(hour: 24, minute: 0))
        let entry = ActivationScheduleEntry(time: six)
        XCTAssertThrowsError(try ActivationScheduleEntry.normalized([entry, entry]))
    }

    func testOnlyExactManagedNamesAreOwned() throws {
        XCTAssertEqual(
            ManagedAutomationPolicy.managedTime(from: "CodexQuotaMenu · 06:00"),
            try ActivationTime(hour: 6, minute: 0)
        )
        XCTAssertNil(ManagedAutomationPolicy.managedTime(from: "CodexQuotaMenu · backup"))
        XCTAssertNil(ManagedAutomationPolicy.managedTime(from: "CodexQuotaMenu · 06:00 copy"))
        XCTAssertNil(ManagedAutomationPolicy.managedTime(from: "Personal reminder"))
    }

    func testNormalizationRejectsDuplicateStableIDs() throws {
        let id = UUID()
        let entries = [
            ActivationScheduleEntry(
                id: id,
                time: try ActivationTime(hour: 6, minute: 0)
            ),
            ActivationScheduleEntry(
                id: id,
                time: try ActivationTime(hour: 11, minute: 2)
            )
        ]

        XCTAssertThrowsError(try ActivationScheduleEntry.normalized(entries))
    }
}
