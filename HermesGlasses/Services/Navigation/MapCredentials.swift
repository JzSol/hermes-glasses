//
// MapCredentials.swift
//
// Keychain storage for the Mapbox access token (used to build static-map
// image URLs). Mirrors DirectClient's per-provider key storage.
//

import Foundation
import Security
import os

enum MapCredentials {
    private static let account = "mapbox_access_token"
    private static let logger = Logger(
        subsystem: "com.flowsxr.hermesglasses", category: "map-credentials"
    )

    static func storeToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
        ]
        // Logged, never surfaced: a keychain that refuses the write turns
        // into "the map just stopped working" with nothing to go on, and
        // errSecItemNotFound on the delete is the normal first-save case.
        let deleteStatus = SecItemDelete(query as CFDictionary)
        if deleteStatus != errSecSuccess, deleteStatus != errSecItemNotFound {
            logger.error("Token delete failed: OSStatus \(deleteStatus, privacy: .public)")
        }
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return }
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        if addStatus != errSecSuccess {
            logger.error("Token store failed: OSStatus \(addStatus, privacy: .public)")
        }
    }

    static func loadToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8), !token.isEmpty
        else { return nil }
        return token
    }

    static var hasToken: Bool { loadToken() != nil }
}
