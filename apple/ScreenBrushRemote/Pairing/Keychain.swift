import Foundation
import Security

/// The last Mac this device paired with, kept in the Keychain.
struct SavedPairing: Codable, Equatable {
    var target: MacTarget
    var token: String
    var macName: String
}

enum Keychain {
    private static let service = "io.paintscreen.ScreenBrushRemote"
    private static let account = "lastPairing"

    static func load() -> SavedPairing? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(SavedPairing.self, from: data)
    }

    static func save(_ pairing: SavedPairing) {
        guard let data = try? JSONEncoder().encode(pairing) else { return }
        delete()
        let attrs: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        SecItemAdd(attrs as CFDictionary, nil)
    }

    static func delete() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}
