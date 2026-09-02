//
// BridgeCredentials.swift
//
// Small Keychain wrapper for the Hermes bridge bearer token. The query uses a
// normal generic-password item and deliberately omits kSecAttrAccessGroup:
// this app does not need a custom keychain sharing entitlement.
//

import Foundation
import Security

enum BridgeCredentialsError: LocalizedError, Equatable, Sendable {
    case emptyToken
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .emptyToken:
            return "Hermes bridge token cannot be empty."
        case .keychain(let status):
            return "Could not access the Hermes bridge token in Keychain (status \(status))."
        }
    }
}

/// Stores exactly one bridge bearer token per service/account pair.
struct BridgeCredentials: Sendable {
    static let defaultService = "com.flowsxr.hermesglasses.bridge"
    static let defaultAccount = "bearer-token"

    let service: String
    let account: String

    init(
        service: String = BridgeCredentials.defaultService,
        account: String = BridgeCredentials.defaultAccount
    ) {
        self.service = service
        self.account = account
    }

    /// The camera-capable app supports named bridge presets. Give each
    /// endpoint its own Keychain item so importing two old `?token=` URLs
    /// cannot make the last migrated token overwrite every other preset.
    /// Adam itself uses the default account because its bridge is pinned.
    init(
        endpoint: String,
        service: String = BridgeCredentials.defaultService
    ) {
        self.service = service
        self.account = Self.endpointAccount(endpoint)
    }

    static func endpointAccount(_ endpoint: String) -> String {
        guard let components = URLComponents(string: endpoint),
              let host = components.host?.lowercased(), !host.isEmpty else {
            return defaultAccount
        }
        let scheme = components.scheme?.lowercased() ?? "wss"
        let normalizedPort = components.port
            ?? (scheme == "wss" ? 443 : (scheme == "ws" ? 80 : -1))
        let port = String(normalizedPort)
        let path = components.percentEncodedPath.isEmpty
            ? "/" : components.percentEncodedPath
        return "endpoint-v1|\(scheme)|\(host)|\(port)|\(path)"
    }

    /// Save or replace the token. No UserDefaults write or URL construction is
    /// involved, and no access-group entitlement is requested.
    func save(token: String) throws {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw BridgeCredentialsError.emptyToken }

        var update = query
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: Data(value.utf8)] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw BridgeCredentialsError.keychain(updateStatus)
        }

        update[kSecValueData as String] = Data(value.utf8)
        update[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(update as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw BridgeCredentialsError.keychain(addStatus)
        }
    }

    /// Read the token, returning nil for a missing item. Missing credentials
    /// are not an exceptional condition during first-run onboarding.
    func load() throws -> String? {
        var read = query
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw BridgeCredentialsError.keychain(status)
        }
        guard let data = result as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty else {
            throw BridgeCredentialsError.keychain(errSecDecode)
        }
        return token
    }

    /// Remove the token when the user signs out or rotates the bridge secret.
    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw BridgeCredentialsError.keychain(status)
        }
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
