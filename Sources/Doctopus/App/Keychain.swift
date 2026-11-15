import Foundation
import Security

/// The login keychain, for the one thing the app holds that is a secret: the
/// key to a model server. Everything else it remembers is a preference.
enum Keychain {
    private static let service = "io.doctopus.app"

    private static func item(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// Nil when there is none, or when the keychain would not hand it over.
    static func read(_ account: String) -> String? {
        var query = item(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess,
              let data = found as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// An empty value removes the item. False when the keychain refused, so
    /// the caller can keep the value somewhere rather than lose it.
    static func write(_ value: String, _ account: String) -> Bool {
        let query = item(account)
        guard !value.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return status == errSecSuccess }
        var fresh = query
        fresh[kSecValueData as String] = data
        return SecItemAdd(fresh as CFDictionary, nil) == errSecSuccess
    }
}
