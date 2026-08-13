import Darwin
import Foundation

struct LocalInterfaceAddress: Equatable {
    let name: String
    let address: String
    let isUp: Bool
    let isLoopback: Bool
}

enum LocalNetworkAddress {
    static func current() -> String {
        select(
            from: interfaceAddresses(),
            fallbackHostname: ProcessInfo.processInfo.hostName
        )
    }

    static func select(
        from interfaces: [LocalInterfaceAddress],
        fallbackHostname: String
    ) -> String {
        let eligible = interfaces.filter {
            $0.isUp && !$0.isLoopback && isPrivateIPv4($0.address)
        }
        for preferredName in ["en0", "en1"] {
            if let preferred = eligible.first(where: { $0.name == preferredName }) {
                return preferred.address
            }
        }
        if let other = eligible.first {
            return other.address
        }

        let hostname = fallbackHostname
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let usableHostname = hostname.isEmpty ? "localhost" : hostname
        return usableHostname.lowercased().hasSuffix(".local")
            ? usableHostname
            : "\(usableHostname).local"
    }

    private static func isPrivateIPv4(_ address: String) -> Bool {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let octets = parts.compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }

        if octets[0] == 10 { return true }
        if octets[0] == 172, (16...31).contains(octets[1]) { return true }
        return octets[0] == 192 && octets[1] == 168
    }

    private static func interfaceAddresses() -> [LocalInterfaceAddress] {
        var firstAddress: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstAddress) == 0, let firstAddress else { return [] }
        defer { freeifaddrs(firstAddress) }

        var result: [LocalInterfaceAddress] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddress
        while let current = cursor {
            let interface = current.pointee
            defer { cursor = interface.ifa_next }
            guard let socketAddress = interface.ifa_addr,
                  socketAddress.pointee.sa_family == UInt8(AF_INET) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = getnameinfo(
                socketAddress,
                socklen_t(socketAddress.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard status == 0 else { continue }

            let flags = interface.ifa_flags
            result.append(LocalInterfaceAddress(
                name: String(cString: interface.ifa_name),
                address: String(cString: host),
                isUp: flags & UInt32(IFF_UP) != 0,
                isLoopback: flags & UInt32(IFF_LOOPBACK) != 0
            ))
        }
        return result
    }
}
