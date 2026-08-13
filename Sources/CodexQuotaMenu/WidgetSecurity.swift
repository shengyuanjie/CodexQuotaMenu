import Foundation
import Security

protocol WidgetTokenStoring {
    func load() throws -> String?
    func save(_ token: String) throws
}

enum WidgetSecurityError: Error {
    case randomGenerationFailed(OSStatus)
    case keychainFailed(OSStatus)
    case invalidStoredToken
}

enum WidgetToken {
    static func generate() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw WidgetSecurityError.randomGenerationFailed(status)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func securelyEquals(_ lhs: String, _ rhs: String) -> Bool {
        let lhsBytes = Array(lhs.utf8)
        let rhsBytes = Array(rhs.utf8)
        let count = max(lhsBytes.count, rhsBytes.count)
        var difference = lhsBytes.count ^ rhsBytes.count

        for index in 0..<count {
            let lhsByte = index < lhsBytes.count ? lhsBytes[index] : 0
            let rhsByte = index < rhsBytes.count ? rhsBytes[index] : 0
            difference |= Int(lhsByte ^ rhsByte)
        }
        return difference == 0
    }
}

struct KeychainWidgetTokenStore: WidgetTokenStoring {
    static let service = "com.local.codexquotamenu.widget"
    static let account = "bearer-token"

    func load() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw WidgetSecurityError.keychainFailed(status)
        }
        guard let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            throw WidgetSecurityError.invalidStoredToken
        }
        return token
    }

    func save(_ token: String) throws {
        let tokenData = Data(token.utf8)
        let update = [kSecValueData as String: tokenData]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)

        if updateStatus == errSecItemNotFound {
            var item = baseQuery
            item[kSecValueData as String] = tokenData
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw WidgetSecurityError.keychainFailed(addStatus)
            }
            return
        }
        guard updateStatus == errSecSuccess else {
            throw WidgetSecurityError.keychainFailed(updateStatus)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account
        ]
    }
}
