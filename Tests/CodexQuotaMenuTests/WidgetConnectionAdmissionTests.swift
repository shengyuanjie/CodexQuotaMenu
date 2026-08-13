import XCTest
@testable import CodexQuotaMenu

final class WidgetConnectionAdmissionTests: XCTestCase {
    func testRejectsConnectionsBeyondCapacityUntilOneFinishes() {
        var admission = WidgetConnectionAdmission(capacity: 2)

        XCTAssertTrue(admission.tryAcquire())
        XCTAssertTrue(admission.tryAcquire())
        XCTAssertFalse(admission.tryAcquire())

        admission.release()
        XCTAssertTrue(admission.tryAcquire())
    }
}
