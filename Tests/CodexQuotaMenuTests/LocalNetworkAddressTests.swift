import XCTest
@testable import CodexQuotaMenu

final class LocalNetworkAddressTests: XCTestCase {
    func testPrefersActivePrivateEn0ThenEn1Addresses() {
        let interfaces = [
            LocalInterfaceAddress(name: "utun4", address: "10.8.0.2", isUp: true, isLoopback: false),
            LocalInterfaceAddress(name: "en1", address: "192.168.2.10", isUp: true, isLoopback: false),
            LocalInterfaceAddress(name: "en0", address: "192.168.1.10", isUp: true, isLoopback: false)
        ]

        XCTAssertEqual(
            LocalNetworkAddress.select(from: interfaces, fallbackHostname: "mac-mini"),
            "192.168.1.10"
        )
    }

    func testFallsBackToAnotherActivePrivateIPv4Address() {
        let interfaces = [
            LocalInterfaceAddress(name: "en0", address: "203.0.113.5", isUp: true, isLoopback: false),
            LocalInterfaceAddress(name: "bridge100", address: "172.20.10.2", isUp: true, isLoopback: false)
        ]

        XCTAssertEqual(
            LocalNetworkAddress.select(from: interfaces, fallbackHostname: "mac-mini"),
            "172.20.10.2"
        )
    }

    func testIgnoresDownLoopbackAndPublicAddressesThenUsesLocalHostname() {
        let interfaces = [
            LocalInterfaceAddress(name: "en0", address: "192.168.1.10", isUp: false, isLoopback: false),
            LocalInterfaceAddress(name: "lo0", address: "127.0.0.1", isUp: true, isLoopback: true),
            LocalInterfaceAddress(name: "en1", address: "8.8.8.8", isUp: true, isLoopback: false)
        ]

        XCTAssertEqual(
            LocalNetworkAddress.select(from: interfaces, fallbackHostname: "mac-mini"),
            "mac-mini.local"
        )
        XCTAssertEqual(
            LocalNetworkAddress.select(from: [], fallbackHostname: "mac-mini.local"),
            "mac-mini.local"
        )
    }
}
