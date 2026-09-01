//
// HermesEndpointPolicy.swift
//
// Validation for the WebSocket endpoint. Release builds use TLS and an
// explicit host allow-list (or the standard Tailscale *.ts.net suffix). Debug
// builds may additionally use loopback ws:// for local development.
//

import Foundation

enum HermesEndpointValidationMode: Equatable, Sendable {
    case release(allowedHosts: Set<String> = [])
    case debug
}

enum HermesEndpointValidationError: LocalizedError, Equatable, Sendable {
    case malformed
    case unsupportedScheme
    case hostRequired
    case hostPinMissing
    case hostNotAllowed
    case queryNotAllowed
    case fragmentNotAllowed
    case userInfoNotAllowed

    var errorDescription: String? {
        switch self {
        case .malformed:
            return "Hermes endpoint is not a valid URL."
        case .unsupportedScheme:
            return "Hermes endpoint must use secure WebSockets (wss://)."
        case .hostRequired:
            return "Hermes endpoint must include a host."
        case .hostPinMissing:
            return "This Adam build is missing its pinned Hermes bridge host."
        case .hostNotAllowed:
            return "Hermes endpoint host is not allowed for this build."
        case .queryNotAllowed:
            return "Hermes endpoint must not contain query parameters."
        case .fragmentNotAllowed:
            return "Hermes endpoint must not contain a URL fragment."
        case .userInfoNotAllowed:
            return "Hermes endpoint must not contain URL credentials."
        }
    }
}

struct HermesEndpointValidator {
    #if DEBUG
    static let currentMode: HermesEndpointValidationMode = .debug
    #else
    static let currentMode: HermesEndpointValidationMode = .release()
    #endif

    /// Validate and return the endpoint URL that can safely be used to build
    /// a URLRequest. No secret is ever read or added here.
    static func validate(
        _ endpoint: String,
        mode: HermesEndpointValidationMode = currentMode
    ) throws -> URL {
        let candidate = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, let url = URL(string: candidate),
              url.scheme != nil else {
            throw HermesEndpointValidationError.malformed
        }
        guard let host = url.host, !host.isEmpty else {
            throw HermesEndpointValidationError.hostRequired
        }
        guard url.user == nil, url.password == nil else {
            throw HermesEndpointValidationError.userInfoNotAllowed
        }
        guard url.query == nil else {
            throw HermesEndpointValidationError.queryNotAllowed
        }
        guard url.fragment == nil else {
            throw HermesEndpointValidationError.fragmentNotAllowed
        }

        let normalizedScheme = url.scheme!.lowercased()
        switch mode {
        case .release(let allowedHosts):
            guard normalizedScheme == "wss" else {
                throw HermesEndpointValidationError.unsupportedScheme
            }
            let normalizedHost = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let explicitAllowed = Set(allowedHosts.map {
                $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            })
            // A Tailscale HTTPS/Serve name ends in ts.net. Explicit hosts are
            // for private DNS names or a test fixture, without hardcoding a
            // personal machine or tailnet address in the app.
            let hostAllowed = explicitAllowed.isEmpty
                ? normalizedHost.hasSuffix(".ts.net")
                : explicitAllowed.contains(normalizedHost)
            guard hostAllowed else {
                throw HermesEndpointValidationError.hostNotAllowed
            }
        case .debug:
            if normalizedScheme == "wss" {
                // Secure endpoints are still subject to the same host policy
                // in debug; local loopback WSS remains valid as a secure URL.
                let normalizedHost = host.lowercased()
                let isLoopback = isLoopbackHost(normalizedHost)
                guard isLoopback || normalizedHost.hasSuffix(".ts.net") else {
                    throw HermesEndpointValidationError.hostNotAllowed
                }
            } else if normalizedScheme == "ws" {
                guard isLoopbackHost(host.lowercased()) else {
                    throw HermesEndpointValidationError.unsupportedScheme
                }
            } else {
                throw HermesEndpointValidationError.unsupportedScheme
            }
        }

        return url
    }

    static func isAllowed(
        _ endpoint: String,
        mode: HermesEndpointValidationMode = currentMode
    ) -> Bool {
        (try? validate(endpoint, mode: mode)) != nil
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1"
            || host == "[::1]"
    }
}
