//
// BridgeCredentials.swift
//
// Keychain storage for an optional Hermes bridge bearer token. Tokens are
// scoped by endpoint so multiple bridge presets cannot overwrite each other.
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
        let path = components.percentEncodedPath.isEmpty
            ? "/" : components.percentEncodedPath
        return "endpoint-v1|\(scheme)|\(host)|\(normalizedPort)|\(path)"
    }

    func save(token: String) throws {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw BridgeCredentialsError.emptyToken }

        var item = query
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: Data(value.utf8)] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw BridgeCredentialsError.keychain(updateStatus)
        }

        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw BridgeCredentialsError.keychain(addStatus)
        }
    }

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

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
