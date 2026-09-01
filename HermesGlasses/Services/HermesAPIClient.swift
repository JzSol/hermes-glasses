//
// HermesAPIClient.swift
//
// WebSocket client for communicating with Hermes Agent's voice endpoint.
// Handles bidirectional audio streaming: sends captured audio from glasses,
// receives STT transcripts, agent text responses, and TTS audio.
//

import Foundation
import os

enum HermesAPIClientError: LocalizedError, Equatable, Sendable {
    case missingToken
    case invalidEndpoint(HermesEndpointValidationError)

    var errorDescription: String? {
        switch self {
        case .missingToken:
            return "Hermes bridge credentials are not configured."
        case .invalidEndpoint(let error):
            return error.localizedDescription
        }
    }
}

/// Capabilities advertised by the bridge in its first welcome frame.
struct HermesBridgeCapabilities: Equatable, Sendable {
    var vision = false
}

/// WebSocket-based client for Hermes Agent voice API
final class HermesAPIClient: NSObject, @unchecked Sendable {
    // MARK: - Callbacks

    var onTranscript: ((String) -> Void)?
    /// (text, bridgeWillSendAudio) - when the second value is false, the
    /// app speaks the text itself with on-device TTS
    var onResponse: ((String, Bool) -> Void)?
    /// Strict clients can correlate a reply to the command that produced it.
    /// Older bridges omit the id, so it remains optional at this shared layer.
    var onResponseWithRequestID: ((String, Bool, String?) -> Void)?
    var onAudioResponse: ((Data) -> Void)?
    var onPlaybackComplete: (() -> Void)?
    var onError: ((String) -> Void)?
    /// Called after the welcome frame has been parsed.
    var onCapabilities: ((HermesBridgeCapabilities) -> Void)?
    /// Called when the WebSocket disconnects
    var onDisconnected: (() -> Void)?
    /// Bridge asks the app to take a photo with the glasses
    var onCapturePhotoRequested: (() -> Void)?
    /// Bridge confirmed the conversation was reset
    var onSessionReset: (() -> Void)?

    // MARK: - Private

    private let endpoint: String
    private let token: String?
    private let locale: VoiceLocale
    private let validationMode: HermesEndpointValidationMode
    private var webSocket: URLSessionWebSocketTask?
    private var session: URLSession?
    /// Behind a lock because the receive loop clears it from a background
    /// executor while the view model reads it on the main actor to decide
    /// whether an utterance can be sent. A plain `Bool` was a data race; an
    /// actor hop would have made `disconnect()` land after callers had
    /// already read the stale value.
    private let connectedFlag = OSAllocatedUnfairLock(initialState: false)
    var isConnected: Bool { connectedFlag.withLock { $0 } }
    private(set) var capabilities = HermesBridgeCapabilities()
    /// The locale carried on every query frame.
    var selectedLocale: VoiceLocale { locale }
    private var receiveTask: Task<Void, Never>?
    private var isFinalized: Bool = false
    /// TTS audio accumulated between audio_start and audio_end
    private var ttsBuffer = Data()

    /// Create a client with a Keychain-loaded bearer token. The token remains
    /// in memory only; it is put in the Authorization header, never in the
    /// endpoint URL or a query item.
    init(
        endpoint: String,
        token: String,
        locale: VoiceLocale = .englishUS,
        validationMode: HermesEndpointValidationMode = HermesEndpointValidator.currentMode
    ) {
        self.endpoint = endpoint
        self.token = token
        self.locale = locale
        self.validationMode = validationMode
        super.init()
    }

    /// Compatibility initializer for the existing camera target. Older builds
    /// stored `?token=` in the endpoint; consume that value in memory and strip
    /// it before URLSession ever sees the URL. New settings use Keychain only.
    convenience init(endpoint: String) {
        let migrated = Self.migrateLegacyEndpoint(endpoint)
        let scopedCredentials = BridgeCredentials(endpoint: migrated.endpoint)
        var storedToken = (try? scopedCredentials.load()) ?? nil
        if migrated.token != nil {
            _ = try? Self.migrateLegacyEndpointToKeychain(endpoint)
        } else if storedToken == nil,
                  let legacyToken = (try? BridgeCredentials().load()) ?? nil {
            // Builds between URL-token auth and endpoint-scoped Keychain auth
            // used one global item. Move it once to the currently selected
            // endpoint instead of copying that credential to every preset.
            if (try? scopedCredentials.save(token: legacyToken)) != nil {
                try? BridgeCredentials().delete()
                storedToken = legacyToken
            }
        }
        self.init(
            endpoint: migrated.endpoint,
            token: migrated.token ?? storedToken ?? ""
        )
    }

    /// Pure migration helper kept visible to the standalone endpoint tests.
    /// It never persists or logs the legacy credential.
    static func migrateLegacyEndpoint(
        _ endpoint: String
    ) -> (endpoint: String, token: String?) {
        guard var components = URLComponents(string: endpoint) else {
            return (endpoint, nil)
        }
        let items = components.queryItems ?? []
        let token = items.first {
            $0.name == "token" && !($0.value ?? "").isEmpty
        }?.value
        guard token != nil else { return (endpoint, nil) }

        let retained = items.filter { $0.name != "token" }
        components.queryItems = retained.isEmpty ? nil : retained
        return (components.string ?? endpoint, token)
    }

    /// One-time migration for old settings that embedded `?token=`. Persist
    /// the credential first, then scrub both the active endpoint and any
    /// matching preset. If Keychain fails, the caller keeps the original
    /// value so it can retry without silently losing the credential.
    static func migrateLegacyEndpointToKeychain(
        _ endpoint: String
    ) throws -> String {
        let migrated = migrateLegacyEndpoint(endpoint)
        guard let token = migrated.token else { return endpoint }
        let scopedCredentials = BridgeCredentials(endpoint: migrated.endpoint)
        try scopedCredentials.save(token: token)
        if scopedCredentials.account != BridgeCredentials.defaultAccount {
            // The former single global item is ambiguous once presets can use
            // different bridges. A successfully imported endpoint token is
            // now authoritative for this endpoint, so discard the old slot.
            try? BridgeCredentials().delete()
        }

        let defaults = UserDefaults.standard
        if defaults.string(forKey: "hermes_endpoint") == endpoint {
            defaults.set(migrated.endpoint, forKey: "hermes_endpoint")
        }
        if var presets = defaults.dictionary(
            forKey: "endpoint_presets"
        ) as? [String: String] {
            var changed = false
            for (name, value) in presets where value == endpoint {
                presets[name] = migrated.endpoint
                changed = true
            }
            if changed { defaults.set(presets, forKey: "endpoint_presets") }
        }
        return migrated.endpoint
    }

    /// The URLRequest builder is public so endpoint/auth policy can be tested
    /// without opening a real WebSocket.
    func makeConnectRequest() throws -> URLRequest {
        let url: URL
        do {
            url = try HermesEndpointValidator.validate(endpoint, mode: validationMode)
        } catch let error as HermesEndpointValidationError {
            throw HermesAPIClientError.invalidEndpoint(error)
        }

        guard let token else { throw HermesAPIClientError.missingToken }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw HermesAPIClientError.missingToken }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        return request
    }

    /// Build the exact query frame without requiring a connected socket.
    func makeQueryData(
        _ text: String,
        bridgeTTS: Bool,
        requestID: String? = nil
    ) throws -> Data {
        var payload: [String: Any] = [
            "type": "query",
            "text": text,
            "locale": locale.rawValue,
            "tts": bridgeTTS,
        ]
        if let requestID, !requestID.isEmpty {
            payload["request_id"] = requestID
        }
        return try JSONSerialization.data(withJSONObject: payload)
    }

    /// Parse a welcome frame without exposing the raw JSON to UI code.
    static func parseCapabilities(from data: Data) -> HermesBridgeCapabilities? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["type"] as? String == "welcome" else {
            return nil
        }
        let capabilityJSON = json["capabilities"] as? [String: Any]
        return HermesBridgeCapabilities(vision: capabilityJSON?["vision"] as? Bool ?? false)
    }

    // MARK: - Public API

    /// Connect to the Hermes bridge and wait for its welcome message.
    /// Returns true once the bridge has confirmed the connection.
    @discardableResult
    func connect() async -> Bool {
        let request: URLRequest
        do {
            request = try makeConnectRequest()
        } catch {
            await reportError(error.localizedDescription)
            return false
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        let urlSession = URLSession(configuration: config)
        session = urlSession

        let ws = urlSession.webSocketTask(with: request)
        webSocket = ws
        ws.resume()

        do {
            // The bridge sends {"type":"welcome"} immediately on connect
            let first = try await ws.receive()
            setConnected(true)
            await handleMessage(first)

            receiveTask = Task { [weak self] in
                await self?.receiveLoop()
            }
            return true
        } catch {
            await reportError("Failed to connect to Hermes: \(error.localizedDescription)")
            disconnect()
            return false
        }
    }

    /// Disconnect from Hermes
    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        session?.invalidateAndCancel()
        session = nil
        setConnected(false)
        isFinalized = false
        Task { @MainActor in
            onDisconnected?()
        }
    }

    func sendAudioChunk(_ data: Data) {
        guard isConnected, let ws = webSocket, !isFinalized else { return }

        ws.send(.data(data)) { [weak self] error in
            if let error {
                Task { @MainActor in
                    self?.onError?("Send error: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Send a diagnostic message that the bridge prints to its log
    func sendDebug(_ message: String) {
        guard isConnected, let ws = webSocket else { return }
        let payload: [String: String] = ["type": "debug", "msg": message]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        ws.send(.string(text)) { _ in }
    }

    /// Ask the bridge to forget the conversation (same-day memory reset)
    func sendNewSession() {
        guard isConnected, let ws = webSocket else { return }
        ws.send(.string(#"{"type":"new_session"}"#)) { _ in }
    }

    /// Send an on-device-transcribed query. bridgeTTS asks the bridge to
    /// synthesize the reply voice (edge-tts); false = app speaks locally.
    func sendQuery(
        _ text: String,
        bridgeTTS: Bool,
        requestID: String? = nil
    ) {
        guard isConnected, let ws = webSocket else { return }
        guard let data = try? makeQueryData(
            text,
            bridgeTTS: bridgeTTS,
            requestID: requestID
        ),
              let json = String(data: data, encoding: .utf8) else { return }
        ws.send(.string(json)) { [weak self] error in
            if let error {
                Task { @MainActor in
                    self?.onError?("Query send error: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Send a captured JPEG as base64 JSON (binary frames are mic audio only)
    func sendPhoto(_ data: Data) {
        guard isConnected, let ws = webSocket else { return }
        let payload: [String: String] = [
            "type": "photo",
            "data": data.base64EncodedString(),
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: json, encoding: .utf8) else { return }
        ws.send(.string(text)) { [weak self] error in
            if let error {
                Task { @MainActor in
                    self?.onError?("Photo send error: \(error.localizedDescription)")
                }
            }
        }
    }

    func sendPhotoError(_ message: String) {
        guard isConnected, let ws = webSocket else { return }
        let payload: [String: String] = ["type": "photo_error", "message": message]
        guard let json = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: json, encoding: .utf8) else { return }
        ws.send(.string(text)) { _ in }
    }

    func finalizeAudio() async {
        guard isConnected, let ws = webSocket, !isFinalized else { return }
        isFinalized = true

        let endMarker = #"{"type":"end_of_audio"}"#
        ws.send(.string(endMarker)) { [weak self] error in
            if let error {
                Task { @MainActor in
                    self?.onError?("Finalize error: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Private

    private func setConnected(_ value: Bool) {
        connectedFlag.withLock { $0 = value }
    }

    private func receiveLoop() async {
        guard let ws = webSocket else { return }

        while !Task.isCancelled, ws.closeCode == .invalid {
            do {
                let message = try await ws.receive()
                await handleMessage(message)
            } catch {
                setConnected(false)
                if !Task.isCancelled {
                    await reportError("Connection lost: \(error.localizedDescription)")
                    await MainActor.run { [weak self] in
                        self?.onDisconnected?()
                    }
                }
                break
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) async {
        switch message {
        case .string(let text):
            await handleTextMessage(text)
        case .data(let data):
            // Binary from the bridge is a TTS chunk; play only when complete
            ttsBuffer.append(data)
        @unknown default:
            break
        }
    }

    private func handleTextMessage(_ text: String) async {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }

        await MainActor.run { [weak self] in
            switch type {
            case "welcome":
                if let capabilities = Self.parseCapabilities(from: data) {
                    self?.capabilities = capabilities
                    self?.onCapabilities?(capabilities)
                }
            case "transcript":
                if let transcript = json["text"] as? String {
                    self?.onTranscript?(transcript)
                }
            case "response":
                if let response = json["text"] as? String {
                    // Absent "tts" field = old bridge that always streams
                    // audio afterwards
                    let bridgeAudio = (json["tts"] as? Bool) ?? true
                    let requestID = json["request_id"] as? String
                    self?.onResponse?(response, bridgeAudio)
                    self?.onResponseWithRequestID?(response, bridgeAudio, requestID)
                }
            case "audio_start":
                self?.ttsBuffer.removeAll()
            case "audio_end":
                if let self, !self.ttsBuffer.isEmpty {
                    let audio = self.ttsBuffer
                    self.ttsBuffer.removeAll()
                    self.onAudioResponse?(audio)
                } else {
                    self?.onPlaybackComplete?()
                }
                self?.isFinalized = false
            case "error":
                if let msg = json["message"] as? String {
                    self?.onError?("Hermes: \(msg)")
                }
            case "capture_photo":
                self?.onCapturePhotoRequested?()
            case "session_reset":
                self?.onSessionReset?()
            default:
                break
            }
        }
    }

    private func reportError(_ message: String) async {
        await MainActor.run { [weak self] in
            self?.onError?(message)
        }
    }
}
