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
}
