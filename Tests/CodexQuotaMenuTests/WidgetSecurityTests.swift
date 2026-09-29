import XCTest
@testable import CodexQuotaMenu

final class WidgetSecurityTests: XCTestCase {
    func testGeneratedTokenIsSixtyFourLowercaseHexCharacters() throws {
        let token = try WidgetToken.generate()

        XCTAssertEqual(token.count, 64)
        XCTAssertNotNil(token.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression))
        XCTAssertFalse(token.contains(where: { $0.isWhitespace }))
    }

    func testGeneratedTokensAreDifferent() throws {
        XCTAssertNotEqual(try WidgetToken.generate(), try WidgetToken.generate())
    }

    func testSecureComparisonHandlesEqualDifferentAndDifferentLengthTokens() {
        XCTAssertTrue(WidgetToken.securelyEquals("abc123", "abc123"))
        XCTAssertFalse(WidgetToken.securelyEquals("abc123", "abc124"))
        XCTAssertFalse(WidgetToken.securelyEquals("abc123", "abc1230"))
        XCTAssertFalse(WidgetToken.securelyEquals("", "abc123"))
    }

    func testTokenCacheKeepsTokenAvailableWithoutReadingKeychainAgain() {
        let cache = WidgetTokenCache()

        XCTAssertNil(cache.current())
        cache.replace(with: "first-token")
        XCTAssertEqual(cache.current(), "first-token")
        cache.replace(with: "replacement-token")
        XCTAssertEqual(cache.current(), "replacement-token")
    }
}
