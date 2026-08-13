import Foundation
import XCTest
@testable import CodexQuotaMenu

final class WidgetPreferencesTests: XCTestCase {
    func testWidgetServerIsDisabledByDefault() {
        withPreferences { preferences in
            XCTAssertFalse(preferences.isServerEnabled)
        }
    }

    func testWidgetServerPreferencePersists() {
        let suiteName = "CodexQuotaMenuTests.WidgetPreferences.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = WidgetPreferences(defaults: defaults)
        first.isServerEnabled = true

        let second = WidgetPreferences(defaults: defaults)
        XCTAssertTrue(second.isServerEnabled)
        XCTAssertEqual(defaults.object(forKey: WidgetPreferences.serverEnabledKey) as? Bool, true)
    }

    private func withPreferences(_ body: (WidgetPreferences) -> Void) {
        let suiteName = "CodexQuotaMenuTests.WidgetPreferences.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(WidgetPreferences(defaults: defaults))
    }
}
