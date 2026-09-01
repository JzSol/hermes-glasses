//
// AdamVoiceSession.swift
//
// The camera-free voice loop for the Adam prototype.  This target deliberately
// owns no wearables, camera, location, or display objects: the only hardware
// it opens is AVAudioSession through HermesAudioManager.
//

import Foundation
import Observation

@MainActor
@Observable
final class AdamVoiceSession {
    enum Status: Equatable {
        case idle
        case connecting
        case reconnecting
        case listening
        case awaitingCommand
        case processing
        case speaking
        case failed

        var label: String {
            switch self {
            case .idle:
                return "Ready"
            case .connecting:
                return "Connecting to Adam…"
            case .reconnecting:
                return "Bridge offline — retrying…"
            case .listening:
                return "Listening for Adam"
            case .awaitingCommand:
                return "Listening for your command"
            case .processing:
                return "Adam is thinking…"
            case .speaking:
                return "Adam is speaking"
            case .failed:
                return "Needs attention"
            }
        }
    }

    /// The route is intentionally an observed value so the UI can tell the
    /// wearer whether the requested glasses HFP route actually materialized.
    var status: Status = .idle
    var endpoint: String
    var locale: VoiceLocale
    var tokenConfigured = false
    var bridgeConnected = false
    var lastCommand = ""
    var lastResponse = ""
    var liveTranscript = ""
    var micRoute = "Not started"
    var outputRoute = "Not started"
    var micLevel: Float = 0
    var micWarning: String?
    var errorMessage: String?
    var isOnDeviceSpeechSupported = false
    var isVoiceSupported = false
    var selectedVoiceDescription: String {
        [voiceProvider, voiceName].filter { !$0.isEmpty }.joined(separator: " · ")
    }
    var voiceNotice: String? {
        locale == .englishGB
            ? "British male speech is generated locally on your Mac."
            : "Latvian currently uses the Nils neural fallback voice."
    }
    var voiceProvider = "Kokoro MLX"
    var voiceName = "George · British male"
    var vocabulary = "Janis, Hermes, Ray-Ban, Tailscale"
    var reconnectAttempt = 0
    var isRunning = false
    var listeningSoundsEnabled: Bool

    static let endpointKey = "hermes_endpoint"
    static let localeKey = "adam_voice_locale"
    static let listeningSoundsKey = "adam_listening_sounds"
    static let vocabularyKey = "adam_voice_vocabulary"
    /// A neutral development value.  The real Tailscale host belongs in the
    /// user's settings and is deliberately not part of the source tree.
    static let defaultEndpoint = "ws://127.0.0.1:8765/voice"

    private static let commandWindow: TimeInterval = 8
    private static let reconnectDelays: [UInt64] = [1, 2, 4, 8, 16, 30]
    private static let speechResumeGrace: UInt64 = 700_000_000
    private static let responseTimeout: UInt64 = 110_000_000_000
    private static let bridgeAudioTimeout: UInt64 = 30_000_000_000

    @ObservationIgnored private let audioManager = HermesAudioManager()
    @ObservationIgnored private let soundscape = AdamSoundscapeManager()
    @ObservationIgnored private var bridgeClient: HermesAPIClient?
    @ObservationIgnored private var speechRecognizer: HermesSpeechRecognizer
    @ObservationIgnored private var speechSynthesizer: HermesSpeechSynthesizer
    @ObservationIgnored private let credentials = BridgeCredentials()
    @ObservationIgnored private var wakeGate = WakeWordGate()
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var commandWindowTask: Task<Void, Never>?
    @ObservationIgnored private var responseTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var pendingRequestID: String?
    @ObservationIgnored private var speechResumeTask: Task<Void, Never>?
    @ObservationIgnored private var bridgeGeneration = 0
    @ObservationIgnored private var runGeneration = 0
    @ObservationIgnored private var isOpeningBridge = false
    @ObservationIgnored private var pendingBridgeAudio = false
    @ObservationIgnored private var outputKind: OutputKind?
    @ObservationIgnored private var cancellingOutput = false
    /// Stop callbacks are delivered asynchronously by AVSpeechSynthesizer /
    /// AVAudioPlayer. Count an interrupted callback so it cannot finish a
    /// newer reply if the wearer speaks again immediately.
    @ObservationIgnored private var ignoredOutputCompletions = 0
    @ObservationIgnored private var preRollAudio = Data()
    @ObservationIgnored private var utteranceAudio = Data()
    @ObservationIgnored private var lastUtteranceAudio = Data()
    @ObservationIgnored private var isCapturingUtterance = false
    @ObservationIgnored private var playbackSampleRate = 24_000
    @ObservationIgnored private var restoringCapture = false

    private static let preRollBytes = 32_000
    private static let maximumUtteranceBytes = 960_000

    private enum OutputKind {
        case localSpeech
        case bridgeAudio
    }

    init() {
        let defaults = UserDefaults.standard
        let savedLocale = defaults.string(forKey: Self.localeKey)
            .flatMap(VoiceLocale.init(identifier:)) ?? .englishGB

        let savedEndpoint = defaults.string(forKey: Self.endpointKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let configuredEndpoint = (Bundle.main.object(
            forInfoDictionaryKey: "AdamBridgeDefaultEndpoint"
        ) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        endpoint = savedEndpoint?.isEmpty == false
            ? savedEndpoint!
            : configuredEndpoint?.isEmpty == false
                ? configuredEndpoint!
                : Self.defaultEndpoint
        locale = savedLocale
        listeningSoundsEnabled = defaults.object(
            forKey: Self.listeningSoundsKey
        ) as? Bool ?? true
        vocabulary = defaults.string(forKey: Self.vocabularyKey)
            ?? "Janis, Hermes, Ray-Ban, Tailscale"
        speechRecognizer = HermesSpeechRecognizer(locale: savedLocale)
        speechSynthesizer = HermesSpeechSynthesizer(locale: savedLocale)
        tokenConfigured = (try? credentials.load())?.map {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } ?? false
        isOnDeviceSpeechSupported = speechRecognizer.supportsOnDeviceRecognition
        isVoiceSupported = speechSynthesizer.isVoiceSupported
        if savedLocale == .latvianLV {
            voiceProvider = "Microsoft Edge"
            voiceName = "Nils · Latvian male"
        }

        wireServices()
        refreshAudioRoute()
    }

    /// Adam is a single-user prototype, so its release transport is pinned to
    /// the one bridge host supplied by the ignored local xcconfig. Merely
    /// ending in `.ts.net` is not sufficient: otherwise a mistyped or
    /// malicious tailnet hostname could receive the bearer credential.
    private var pinnedBridgeHost: String? {
        let value = (Bundle.main.object(
            forInfoDictionaryKey: "AdamBridgeAllowedHost"
        ) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value!.lowercased() : nil
    }

    private func endpointValidationMode(
        for candidate: String
    ) throws -> HermesEndpointValidationMode {
        #if DEBUG
        if let host = URL(string: candidate)?.host?.lowercased(),
           ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) {
            return .debug
        }
        #endif

        guard let pinnedBridgeHost else {
            throw HermesEndpointValidationError.hostPinMissing
        }
        return .release(allowedHosts: [pinnedBridgeHost])
    }

    // MARK: - Settings

    func setListeningSounds(_ enabled: Bool) {
        guard listeningSoundsEnabled != enabled else { return }
        listeningSoundsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.listeningSoundsKey)

        if enabled, isRunning, status == .awaitingCommand {
            startListeningSoundscape()
        } else if !enabled {
            soundscape.stopImmediately()
        }
    }

    func saveVocabulary(_ value: String) {
        vocabulary = value
        UserDefaults.standard.set(value, forKey: Self.vocabularyKey)
    }

    /// Persist only a validated endpoint. The exact private Tailscale host is
    /// supplied by the ignored machine-local xcconfig and pinned in this build.
    @discardableResult
    func saveEndpoint(_ value: String) -> Bool {
        let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else {
            errorMessage = "Enter the Hermes bridge WebSocket endpoint."
            return false
        }

        do {
            let mode = try endpointValidationMode(for: candidate)
            _ = try HermesEndpointValidator.validate(candidate, mode: mode)
        } catch {
            errorMessage = error.localizedDescription
            return false
        }

        endpoint = candidate
        UserDefaults.standard.set(candidate, forKey: Self.endpointKey)
        errorMessage = nil

        if isRunning {
            reconnectAttempt = 0
            reconnectTask?.cancel()
            reconnectTask = nil
            invalidateBridge()
            status = .reconnecting
            scheduleReconnect(immediate: true)
        }
        return true
    }

    @discardableResult
    func saveToken(_ value: String) -> Bool {
        do {
            try credentials.save(token: value)
            tokenConfigured = true
            errorMessage = nil
            if isRunning {
                reconnectAttempt = 0
                reconnectTask?.cancel()
                reconnectTask = nil
                invalidateBridge()
                status = .reconnecting
                scheduleReconnect(immediate: true)
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func clearToken() -> Bool {
        do {
            try credentials.delete()
            tokenConfigured = false
            errorMessage = nil
            if isRunning {
                stop()
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func setLocale(_ newLocale: VoiceLocale) -> Bool {
        guard newLocale != locale else { return true }
        let oldLocale = locale

        if isRunning, outputKind != nil {
            stopCurrentOutput()
            wakeGate.setSpeaking(false)
            status = bridgeConnected ? .listening : .reconnecting
        }

        do {
            try speechRecognizer.setLocale(newLocale)
            try speechSynthesizer.setLocale(newLocale)
        } catch {
            // Keep both services on the same language if the requested
            // recognizer or installed TTS voice is unavailable.
            _ = try? speechRecognizer.setLocale(oldLocale)
            _ = try? speechSynthesizer.setLocale(oldLocale)
            errorMessage = error.localizedDescription
            return false
        }

        locale = newLocale
        switch newLocale {
        case .englishGB:
            voiceProvider = "Kokoro MLX"
            voiceName = "George · British male"
        case .latvianLV:
            voiceProvider = "Microsoft Edge"
            voiceName = "Nils · Latvian male"
        }
        UserDefaults.standard.set(newLocale.rawValue, forKey: Self.localeKey)
        isOnDeviceSpeechSupported = speechRecognizer.supportsOnDeviceRecognition
        isVoiceSupported = speechSynthesizer.isVoiceSupported
        errorMessage = nil

        // HermesAPIClient carries the locale immutably on every query. Rotate
        // only the bridge connection so subsequent turns cannot keep using the
        // language that was selected when the session first started; audio and
        // speech recognition remain armed throughout the reconnect.
        if isRunning {
            soundscape.stopImmediately()
            reconnectAttempt = 0
            reconnectTask?.cancel()
            reconnectTask = nil
            invalidateBridge()
            commandWindowTask?.cancel()
            commandWindowTask = nil
            _ = wakeGate.cancel()
            status = .reconnecting
            scheduleReconnect(immediate: true)
        }
        return true
    }

    func resetConversation() {
        soundscape.stopImmediately()
        bridgeClient?.sendNewSession()
        pendingRequestID = nil
        responseTimeoutTask?.cancel()
        responseTimeoutTask = nil
        commandWindowTask?.cancel()
        commandWindowTask = nil
        pendingBridgeAudio = false
        _ = wakeGate.failed()
        speechRecognizer.isSuspended = false
        if isRunning {
            status = bridgeConnected ? .listening : .reconnecting
        }
        lastCommand = ""
        lastResponse = ""
        liveTranscript = ""
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        startTask?.cancel()
        reconnectTask?.cancel()
        reconnectTask = nil
        runGeneration += 1
        isRunning = true
        status = .connecting
        bridgeConnected = false
        errorMessage = nil
        liveTranscript = ""
        lastCommand = ""
        lastResponse = ""
        pendingRequestID = nil
        reconnectAttempt = 0
        wakeGate = WakeWordGate(
            commandWindow: Self.commandWindow
        )
        preRollAudio.removeAll(keepingCapacity: true)
        utteranceAudio.removeAll(keepingCapacity: true)
        lastUtteranceAudio.removeAll(keepingCapacity: true)
        isCapturingUtterance = false
        wireServices()

        let generation = runGeneration
        startTask = Task { @MainActor [weak self] in
            await self?.startSession(generation: generation)
        }
    }

    func stop() {
        guard isRunning || startTask != nil || bridgeClient != nil else {
            status = .idle
            return
        }

        runGeneration += 1
        isRunning = false
        startTask?.cancel()
        startTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        commandWindowTask?.cancel()
        commandWindowTask = nil
        responseTimeoutTask?.cancel()
        responseTimeoutTask = nil
        pendingRequestID = nil
        speechResumeTask?.cancel()
        speechResumeTask = nil

        // Clear callbacks before disconnect: HermesAPIClient deliberately
        // reports every disconnect asynchronously, including a user stop.
        invalidateBridge()
        stopCurrentOutput()
        soundscape.stopImmediately()
        speechRecognizer.stop()
        audioManager.stopCapture()
        clearAudioCallbacks()
        audioManager.recognitionConditioningEnabled = false
        audioManager.bridgeConditioningEnabled = false
        audioManager.maximumInputGainEnabled = false

        _ = wakeGate.cancel()
        pendingBridgeAudio = false
        outputKind = nil
        cancellingOutput = false
        ignoredOutputCompletions = 0
        restoringCapture = false
        isCapturingUtterance = false
        preRollAudio.removeAll(keepingCapacity: true)
        utteranceAudio.removeAll(keepingCapacity: true)
        lastUtteranceAudio.removeAll(keepingCapacity: true)
        bridgeConnected = false
        status = .idle
        liveTranscript = ""
        micLevel = 0
        micWarning = nil
        refreshAudioRoute()
    }

    private func startSession(generation: Int) async {
        defer {
            if generation == runGeneration {
                startTask = nil
            }
        }
        guard isRunning, generation == runGeneration else { return }

        guard loadToken() != nil else {
            failStartup("Add the Hermes bridge token before starting Adam.")
            return
        }
        do {
            let mode = try endpointValidationMode(for: endpoint)
            _ = try HermesEndpointValidator.validate(endpoint, mode: mode)
        } catch {
            failStartup(error.localizedDescription)
            return
        }

        // Open HFP first, so the actual route is visible before speech starts.
        // HermesAudioManager returns false when it had to use the iPhone mic;
        // this is reported honestly in the UI instead of being called glasses.
        do {
            // Adam alone opts into the copy-only recognition conditioner and
            // best-effort hardware gain. The original Hermes target leaves
            // both manager settings at their safe defaults.
            audioManager.recognitionConditioningEnabled = true
            audioManager.bridgeConditioningEnabled = true
            audioManager.maximumInputGainEnabled = true
            _ = try await audioManager.startCapture(route: .glassesMic)
            refreshAudioRoute()
        } catch is CancellationError {
            audioManager.stopCapture()
            return
        } catch {
            failStartup(error.localizedDescription)
            return
        }

        guard isRunning, generation == runGeneration else { return }
        let speechAllowed = await speechRecognizer.requestAuthorization()
        guard isRunning, generation == runGeneration, !Task.isCancelled else { return }
        guard speechAllowed else {
            failStartup(HermesSpeechError.notAuthorized.localizedDescription)
            return
        }
        do {
            try speechRecognizer.start()
            isOnDeviceSpeechSupported = speechRecognizer.supportsOnDeviceRecognition
        } catch {
            failStartup(error.localizedDescription)
            return
        }

        let connected = await openBridge()
        guard isRunning, generation == runGeneration else { return }
        if connected {
            status = .listening
        } else {
            status = .reconnecting
            scheduleReconnect()
        }
    }

    private func failStartup(_ message: String) {
        errorMessage = message
        status = .failed
        stop()
        status = .failed
    }

    // MARK: - Bridge connection and reconnect

    private func loadToken() -> String? {
        do {
            guard let token = try credentials.load() else {
                tokenConfigured = false
                return nil
            }
            let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                tokenConfigured = false
                return nil
            }
            tokenConfigured = true
            return value
        } catch {
            errorMessage = error.localizedDescription
            tokenConfigured = false
            return nil
        }
    }

    private func openBridge() async -> Bool {
        guard isRunning, let token = loadToken() else { return false }

        let validationMode: HermesEndpointValidationMode
        do {
            validationMode = try endpointValidationMode(for: endpoint)
            _ = try HermesEndpointValidator.validate(
                endpoint,
                mode: validationMode
            )
        } catch {
            errorMessage = error.localizedDescription
            return false
        }

        invalidateBridge()
        let client = HermesAPIClient(
            endpoint: endpoint,
            token: token,
            locale: locale,
            validationMode: validationMode
        )
        bridgeGeneration += 1
        let generation = bridgeGeneration
        bridgeClient = client
        installBridgeCallbacks(on: client, generation: generation)

        isOpeningBridge = true
        let connected = await client.connect()
        isOpeningBridge = false

        guard isRunning, bridgeClient === client, bridgeGeneration == generation else {
            client.onDisconnected = nil
            client.disconnect()
            return false
        }
        bridgeConnected = connected
        if connected {
            errorMessage = nil
            reconnectAttempt = 0
        }
        return connected
    }

    private func installBridgeCallbacks(on client: HermesAPIClient, generation: Int) {
        client.onTranscriptWithRequestID = { [weak self, weak client] text, requestID in
            Task { @MainActor [weak self, weak client] in
                guard let self, let client,
                      self.isCurrentBridge(client, generation: generation),
                      requestID == nil || requestID == self.pendingRequestID else { return }
                self.liveTranscript = text
                self.lastCommand = text
            }
        }
        client.onResponseStarted = { [weak self, weak client] requestID in
            Task { @MainActor [weak self, weak client] in
                guard let self, let client,
                      self.isCurrentBridge(client, generation: generation),
                      requestID == nil || requestID == self.pendingRequestID else { return }
                self.status = .processing
                // Protocol v2 can stream Kokoro PCM before the final response
                // frame. Mark it expected at response_start so early audio is
                // never discarded while Hermes is still generating text.
                self.pendingBridgeAudio = true
                self.lastResponse = ""
                self.liveTranscript = ""
            }
        }
        client.onResponseDelta = { [weak self, weak client] delta, requestID in
            Task { @MainActor [weak self, weak client] in
                guard let self, let client,
                      self.isCurrentBridge(client, generation: generation),
                      requestID == nil || requestID == self.pendingRequestID else { return }
                self.lastResponse += delta
            }
        }
        client.onResponseWithRequestID = {
            [weak self, weak client] text, bridgeWillSendAudio, requestID in
            Task { @MainActor [weak self, weak client] in
                guard let self, let client,
                      self.isCurrentBridge(client, generation: generation),
                      let pendingRequestID = self.pendingRequestID,
                      requestID == nil || requestID == pendingRequestID else { return }
                self.handleResponse(text, bridgeWillSendAudio: bridgeWillSendAudio)
            }
        }
        client.onAudioSegmentWithFormat = {
            [weak self, weak client] data, metadata, requestID in
            Task { @MainActor [weak self, weak client] in
                guard let self, let client,
                      self.isCurrentBridge(client, generation: generation),
                      requestID == nil || requestID == self.pendingRequestID else { return }
                self.handleBridgeAudio(data, metadata: metadata)
            }
        }
        client.onAudioStreamEnded = { [weak self, weak client] requestID in
            Task { @MainActor [weak self, weak client] in
                guard let self, let client,
                      self.isCurrentBridge(client, generation: generation),
                      requestID == nil || requestID == self.pendingRequestID else { return }
                if self.outputKind == .bridgeAudio {
                    self.audioManager.finishResponseStream()
                } else if self.pendingBridgeAudio {
                    self.pendingBridgeAudio = false
                    self.finishResponse()
                }
            }
        }
        client.onResponseMetadata = { [weak self] provider, voice in
            Task { @MainActor [weak self] in
                self?.applyVoiceMetadata(provider: provider, voice: voice)
            }
        }
        client.onAttention = { [weak self] message in
            Task { @MainActor [weak self] in self?.errorMessage = message }
        }
        client.onPlaybackComplete = { [weak self, weak client] in
            Task { @MainActor [weak self, weak client] in
                guard let self, let client,
                      self.isCurrentBridge(client, generation: generation) else { return }
                if self.pendingBridgeAudio {
                    self.pendingBridgeAudio = false
                    self.finishResponse()
                } else {
                    self.finishOutput()
                }
            }
        }
        client.onError = { [weak self, weak client] message in
            Task { @MainActor [weak self, weak client] in
                guard let self, let client,
                      self.isCurrentBridge(client, generation: generation) else { return }
                if self.pendingRequestID != nil, self.outputKind == nil {
                    self.failResponse(message)
                } else {
                    self.errorMessage = message
                }
            }
        }
        client.onCapabilities = { [weak self] capabilities in
            Task { @MainActor [weak self] in
                guard capabilities.audioUpload,
                      capabilities.serverSTT,
                      capabilities.streamingTTS else {
                    self?.errorMessage = "Update the Adam bridge on your Mac for server speech."
                    return
                }
            }
        }
        client.onCapturePhotoRequested = { [weak self, weak client] in
            Task { @MainActor [weak self, weak client] in
                guard let self, let client,
                      self.isCurrentBridge(client, generation: generation) else { return }
                client.sendPhotoError("Adam voice mode does not capture images.")
                self.errorMessage = "This voice-only build cannot capture images."
            }
        }
        client.onSessionReset = { [weak self, weak client] in
            Task { @MainActor [weak self, weak client] in
                guard let self, let client,
                      self.isCurrentBridge(client, generation: generation) else { return }
                self.lastCommand = ""
                self.lastResponse = ""
                self.liveTranscript = ""
            }
        }
        client.onDisconnected = { [weak self, weak client] in
            Task { @MainActor [weak self, weak client] in
                guard let self, let client,
                      self.isCurrentBridge(client, generation: generation) else { return }
                self.handleBridgeDisconnect(client, generation: generation)
            }
        }
    }

    private func isCurrentBridge(_ client: HermesAPIClient, generation: Int) -> Bool {
        isRunning && bridgeClient === client && bridgeGeneration == generation
    }

    private func handleBridgeDisconnect(_ client: HermesAPIClient, generation: Int) {
        guard isCurrentBridge(client, generation: generation) else { return }
        bridgeConnected = false
        client.onDisconnected = nil
        bridgeClient = nil
        bridgeGeneration += 1

        if outputKind == nil, status == .processing {
            pendingBridgeAudio = false
            responseTimeoutTask?.cancel()
            responseTimeoutTask = nil
            pendingRequestID = nil
            _ = wakeGate.failed()
            speechRecognizer.isSuspended = false
        }

        // A failed initial connect calls disconnect() internally.  The caller
        // handles that result; do not create a second retry task from this
        // callback while the attempt is still awaiting its return value.
        guard isRunning, !isOpeningBridge else { return }
        status = .reconnecting
        scheduleReconnect()
    }

    private func invalidateBridge() {
        bridgeGeneration += 1
        if let client = bridgeClient {
            client.onDisconnected = nil
            client.onTranscript = nil
            client.onTranscriptWithRequestID = nil
            client.onResponseStarted = nil
            client.onResponseDelta = nil
            client.onResponse = nil
            client.onResponseWithRequestID = nil
            client.onResponseMetadata = nil
            client.onAudioResponse = nil
            client.onAudioResponseWithFormat = nil
            client.onAudioSegmentWithFormat = nil
            client.onAudioStreamEnded = nil
            client.onPlaybackComplete = nil
            client.onError = nil
            client.onCapabilities = nil
            client.onCapturePhotoRequested = nil
            client.onSessionReset = nil
            client.onAttention = nil
            client.disconnect()
        }
        bridgeClient = nil
        bridgeConnected = false
        pendingBridgeAudio = false
        if pendingRequestID != nil {
            responseTimeoutTask?.cancel()
            responseTimeoutTask = nil
            pendingRequestID = nil
            _ = wakeGate.failed()
            speechRecognizer.isSuspended = false
        }
    }

    private func scheduleReconnect(immediate: Bool = false) {
        guard isRunning, reconnectTask == nil else { return }
        status = .reconnecting
        let attempt = reconnectAttempt
        reconnectAttempt = min(attempt + 1, Self.reconnectDelays.count)
        let delay: UInt64 = immediate
            ? 0
            : Self.reconnectDelays[min(attempt, Self.reconnectDelays.count - 1)]
        let generation = runGeneration

        reconnectTask = Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            }
            guard !Task.isCancelled, let self,
                  self.isRunning, self.runGeneration == generation else { return }
            self.reconnectTask = nil
            let connected = await self.openBridge()
            guard self.isRunning, self.runGeneration == generation else { return }
            if connected {
                self.status = self.outputKind == nil ? .listening : .speaking
            } else {
                self.scheduleReconnect()
            }
        }
    }

    // MARK: - Speech and wake loop

    private func handlePartial(_ text: String) {
        guard isRunning else { return }
        // Partial recognition is used only to keep Apple's on-device wake
        // cycle alive. It is deliberately not shown as "Heard" because the
        // authoritative command transcript comes from Hermes/faster-whisper.
        let action = wakeGate.handlePartial(text)
        if action == .rearmed || wakeGate.timeout() {
            finishListeningSoundscape()
            commandWindowTask?.cancel()
            commandWindowTask = nil
            liveTranscript = ""
            status = bridgeConnected ? .listening : .reconnecting
        }
    }

    private func handleFinal(_ text: String) {
        guard isRunning, outputKind == nil else { return }
        liveTranscript = ""
        let action = wakeGate.handleFinal(text)

        switch action {
        case .suppressed:
            break
        case .prompt:
            isCapturingUtterance = false
            utteranceAudio.removeAll(keepingCapacity: true)
            preRollAudio.removeAll(keepingCapacity: true)
            lastUtteranceAudio.removeAll(keepingCapacity: true)
            status = .awaitingCommand
            startListeningSoundscape()
            armCommandWindowTimeout()
            // Deliberately do not speak "Yes?" here.  Keeping recognition
            // live makes the immediately-following command reliable and
            // avoids the prompt being recognized as that command.
        case .submit:
            commandWindowTask?.cancel()
            commandWindowTask = nil
            submitRecordedUtterance()
        case .interrupt:
            break
        case .interruptAndSubmit:
            break
        case .rearmed:
            status = bridgeConnected ? .listening : .reconnecting
        }
    }

    private func armCommandWindowTimeout() {
        commandWindowTask?.cancel()
        guard let remaining = wakeGate.remainingCommandWindow(), remaining > 0 else {
            commandWindowTask = nil
            if wakeGate.timeout() {
                finishListeningSoundscape()
                liveTranscript = ""
                status = bridgeConnected ? .listening : .reconnecting
            }
            return
        }
        let nanoseconds = UInt64((remaining * 1_000_000_000).rounded(.up))
        commandWindowTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled, let self, self.isRunning else { return }
            self.commandWindowTask = nil
            if self.wakeGate.timeout() {
                self.finishListeningSoundscape()
                self.liveTranscript = ""
                self.isCapturingUtterance = false
                self.utteranceAudio.removeAll(keepingCapacity: true)
                self.lastUtteranceAudio.removeAll(keepingCapacity: true)
                self.status = self.bridgeConnected ? .listening : .reconnecting
            } else if self.wakeGate.state.isAwaitingCommand {
                // A clock tick can wake a fraction before the deadline. Keep
                // waiting rather than losing the command window.
                self.armCommandWindowTimeout()
            }
        }
    }

    private func submitRecordedUtterance() {
        let audio = takeRecordedUtterance()
        guard audio.count >= 640 else {
            _ = wakeGate.failed()
            errorMessage = "I did not receive enough audio. Say Adam and try again."
            status = bridgeConnected ? .listening : .reconnecting
            return
        }
        finishListeningSoundscape(playCompletionIfIdle: true)
        lastCommand = ""
        lastResponse = ""
        liveTranscript = ""

        guard let client = bridgeClient, client.isConnected else {
            _ = wakeGate.failed()
            errorMessage = "Adam is offline. I will keep listening and retry the bridge."
            scheduleReconnect()
            let feedback: String
            switch locale {
            case .englishGB:
                feedback = "Adam is offline. I am reconnecting."
            case .latvianLV:
                feedback = "Adam nav sasniedzams. Mēģinu savienoties vēlreiz."
            }
            lastResponse = feedback
            speakLocally(feedback)
            return
        }

        status = .processing
        pendingBridgeAudio = false
        let requestID = UUID().uuidString
        pendingRequestID = requestID
        responseTimeoutTask?.cancel()
        responseTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.responseTimeout)
            guard !Task.isCancelled, let self, self.isRunning,
                  self.status == .processing else { return }
            self.failResponse("Adam did not answer before the request timed out.")
        }

        // Do not feed trailing words from the command back into the wake
        // loop while the bridge is thinking.
        speechRecognizer.isSuspended = true
        let terms = vocabulary.split(separator: ",").map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        Task { @MainActor [weak self, weak client] in
            guard let self, let client,
                  self.isRunning, self.pendingRequestID == requestID else { return }
            do {
                try await client.uploadAudioCapture(
                    audio, requestID: requestID, vocabulary: terms
                )
            } catch {
                guard self.pendingRequestID == requestID else { return }
                self.failResponse("Adam could not send the recording. Please try again.")
            }
        }
    }

    private func handleResponse(_ text: String, bridgeWillSendAudio: Bool) {
        responseTimeoutTask?.cancel()
        responseTimeoutTask = nil
        lastResponse = text
        pendingBridgeAudio = bridgeWillSendAudio && outputKind != .bridgeAudio

        if bridgeWillSendAudio {
            // The PCM stream can begin before Hermes sends its final text.
            // Preserve the speaking state when that happens instead of
            // briefly regressing the UI to "thinking" mid-sentence.
            guard outputKind != .bridgeAudio else { return }
            status = .processing
            responseTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: Self.bridgeAudioTimeout)
                guard !Task.isCancelled, let self, self.isRunning,
                      self.pendingBridgeAudio, self.outputKind == nil else { return }
                self.failResponse("Adam's voice audio did not arrive. Please try again.")
            }
            return
        }
        speakLocally(text)
    }

    private func handleBridgeAudio(
        _ data: Data,
        metadata: HermesVoiceMetadata
    ) {
        guard pendingRequestID != nil else { return }
        pendingBridgeAudio = false
        playbackSampleRate = metadata.sampleRate
        applyVoiceMetadata(provider: metadata.provider, voice: metadata.voice)
        if outputKind == .bridgeAudio {
            audioManager.enqueueResponseSegment(
                data, sampleRate: metadata.sampleRate
            )
            return
        }
        beginHighQualityBridgeOutput(data, sampleRate: metadata.sampleRate)
    }

    private func applyVoiceMetadata(provider: String?, voice: String?) {
        if let provider, !provider.isEmpty {
            voiceProvider = provider == "kokoro-mlx" ? "Kokoro MLX" : provider
        }
        if let voice, !voice.isEmpty {
            switch voice {
            case "bm_george": voiceName = "George · British male"
            case "en-GB-RyanNeural": voiceName = "Ryan · British male"
            case "lv-LV-NilsNeural": voiceName = "Nils · Latvian male"
            default: voiceName = voice
            }
        }
    }

    private func speakLocally(_ text: String) {
        pendingBridgeAudio = false
        beginOutput(.localSpeech)
        _ = speechSynthesizer.speak(text)
    }

    private func beginHighQualityBridgeOutput(
        _ data: Data,
        sampleRate: Int
    ) {
        soundscape.stopImmediately()
        responseTimeoutTask?.cancel()
        responseTimeoutTask = nil
        outputKind = .bridgeAudio
        cancellingOutput = false
        wakeGate.setSpeaking(true)
        status = .speaking
        speechRecognizer.isSuspended = true

        audioManager.beginResponseStream()
        audioManager.enqueueResponseSegment(data, sampleRate: sampleRate)

        // Release HFP before playback so iOS can route full-band audio over
        // A2DP. The physical route transition is allowed up to 1.5 seconds;
        // if it does not appear we still play, but report the fallback.
        audioManager.stopCapture()
        Task { @MainActor [weak self] in
            guard let self, self.isRunning,
                  self.outputKind == .bridgeAudio else { return }
            do {
                try self.audioManager.prepareHighQualityPlayback()
                for _ in 0..<15 where !self.audioManager.outputIsBluetooth {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            } catch {
                self.micWarning = "High-quality playback was unavailable; using the current output."
            }
            guard self.isRunning, self.outputKind == .bridgeAudio else { return }
            self.refreshAudioRoute()
            if !self.audioManager.outputIsBluetooth {
                self.micWarning = "Ray-Ban A2DP did not connect; Adam is using \(self.outputRoute)."
            }
            self.audioManager.startResponseStreamPlayback()
        }
    }

    private func beginOutput(_ kind: OutputKind) {
        // Never let a listening cue or droplet render under Adam's reply.
        soundscape.stopImmediately()
        responseTimeoutTask?.cancel()
        responseTimeoutTask = nil
        outputKind = kind
        cancellingOutput = false
        wakeGate.setSpeaking(true)
        status = .speaking

        // HFP has hardware echo cancellation, so it can keep recognition
        // alive for a wake-word barge-in.  The phone fallback must suspend
        // recognition or it will hear its own speaker.
        speechRecognizer.isSuspended = !audioManager.isUsingBluetoothInput
    }

    private func finishOutput() {
        if ignoredOutputCompletions > 0 {
            ignoredOutputCompletions -= 1
            if cancellingOutput {
                outputKind = nil
                cancellingOutput = false
            }
            return
        }
        guard let kind = outputKind else { return }
        let wasCancelled = cancellingOutput
        outputKind = nil
        cancellingOutput = false
        if wasCancelled {
            return
        }

        if case .bridgeAudio = kind {
            restoreCaptureAfterPlayback()
        } else {
            finishResponse()
        }
    }

    private func restoreCaptureAfterPlayback() {
        guard !restoringCapture else { return }
        restoringCapture = true
        Task { @MainActor [weak self] in
            guard let self, self.isRunning else { return }
            do {
                _ = try await self.audioManager.startCapture(route: .glassesMic)
                guard self.isRunning else {
                    self.audioManager.stopCapture()
                    self.restoringCapture = false
                    return
                }
                self.refreshAudioRoute()
                self.speechRecognizer.restartCycle()
                self.micWarning = nil
                self.restoringCapture = false
                self.finishResponse()
            } catch {
                self.restoringCapture = false
                self.failResponse(
                    "Adam spoke, but the Ray-Ban microphone did not reconnect. Start Adam again."
                )
                self.status = .failed
            }
        }
    }

    private func finishResponse() {
        pendingBridgeAudio = false
        responseTimeoutTask?.cancel()
        responseTimeoutTask = nil
        pendingRequestID = nil
        if case .speaking = wakeGate.state {
            _ = wakeGate.completed()
        } else {
            wakeGate.setSpeaking(false)
        }
        status = bridgeConnected ? .listening : .reconnecting
        scheduleSpeechResume()
        if !bridgeConnected { scheduleReconnect() }
    }

    private func failResponse(_ message: String) {
        soundscape.stopImmediately()
        responseTimeoutTask?.cancel()
        responseTimeoutTask = nil
        pendingRequestID = nil
        pendingBridgeAudio = false
        errorMessage = message
        _ = wakeGate.failed()
        status = bridgeConnected ? .listening : .reconnecting
        speechRecognizer.isSuspended = false
        if !bridgeConnected { scheduleReconnect() }
    }

    private func stopOutputForInterruption() {
        guard let kind = outputKind else { return }
        cancellingOutput = true
        switch kind {
        case .localSpeech:
            if speechSynthesizer.isSpeaking {
                ignoredOutputCompletions += 1
                speechSynthesizer.stop()
            }
            if !speechSynthesizer.isSpeaking {
                outputKind = nil
                cancellingOutput = false
            }
        case .bridgeAudio:
            ignoredOutputCompletions += 1
            audioManager.stopPlayback()
            // `stopPlayback()` calls onPlaybackComplete when a clip exists.
            // If the clip already ended, no callback is possible.
            if !audioManager.isUsingBluetoothInput {
                speechRecognizer.isSuspended = false
            }
        }
        pendingBridgeAudio = false
    }

    private func stopCurrentOutput() {
        outputKind = nil
        cancellingOutput = true
        ignoredOutputCompletions = 0
        speechSynthesizer.stop()
        audioManager.stopPlayback()
        cancellingOutput = false
        pendingBridgeAudio = false
    }

    private func scheduleSpeechResume() {
        speechResumeTask?.cancel()
        speechResumeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.speechResumeGrace)
            guard !Task.isCancelled, let self, self.isRunning else { return }
            self.speechResumeTask = nil
            self.speechRecognizer.isSuspended = false
        }
    }

    private func startListeningSoundscape() {
        guard listeningSoundsEnabled else { return }
        // One short flute cue marks the opened command window. Silence while
        // the user speaks avoids contaminating the Ray-Ban HFP microphone.
        soundscape.startListening(loop: false)
    }

    private func finishListeningSoundscape(
        playCompletionIfIdle: Bool = false
    ) {
        guard listeningSoundsEnabled else {
            soundscape.stopImmediately()
            return
        }
        if soundscape.isListening {
            soundscape.finishListening()
        } else if playCompletionIfIdle {
            soundscape.playCompletionCue()
        }
    }

    // MARK: - Service wiring and route status

    private func handleAudioChunk(_ data: Data) {
        guard isRunning, !data.isEmpty else { return }
        preRollAudio.append(data)
        if preRollAudio.count > Self.preRollBytes {
            preRollAudio.removeFirst(preRollAudio.count - Self.preRollBytes)
        }
        guard isCapturingUtterance,
              utteranceAudio.count < Self.maximumUtteranceBytes else { return }
        let remaining = Self.maximumUtteranceBytes - utteranceAudio.count
        utteranceAudio.append(data.prefix(remaining))
    }

    private func handleSpeechStarted() {
        guard isRunning, outputKind == nil,
              status == .listening || status == .awaitingCommand else { return }
        utteranceAudio = preRollAudio
        isCapturingUtterance = true
    }

    private func handleSpeechEnded() {
        guard isCapturingUtterance else { return }
        isCapturingUtterance = false
        lastUtteranceAudio = utteranceAudio
        utteranceAudio.removeAll(keepingCapacity: true)
    }

    private func takeRecordedUtterance() -> Data {
        if isCapturingUtterance {
            isCapturingUtterance = false
            lastUtteranceAudio = utteranceAudio
            utteranceAudio.removeAll(keepingCapacity: true)
        }
        let result = lastUtteranceAudio
        lastUtteranceAudio.removeAll(keepingCapacity: true)
        preRollAudio.removeAll(keepingCapacity: true)
        return result
    }

    private func wireServices() {
        let recognizer = speechRecognizer
        audioManager.onRawBuffer = { [weak recognizer] buffer in
            recognizer?.append(buffer)
        }
        audioManager.onLevel = { [weak self] level in
            Task { @MainActor [weak self] in
                self?.micLevel = level
            }
        }
        audioManager.onAudioChunk = { [weak self] data in
            Task { @MainActor [weak self] in self?.handleAudioChunk(data) }
        }
        audioManager.onSpeechDetected = { [weak self] in
            Task { @MainActor [weak self] in self?.handleSpeechStarted() }
        }
        audioManager.onSilenceDetected = { [weak self] in
            Task { @MainActor [weak self] in self?.handleSpeechEnded() }
        }
        audioManager.onMicWarning = { [weak self] warning in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                self.micWarning = warning
            }
        }
        audioManager.onRouteChanged = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                self.refreshAudioRoute()
                if self.status == .awaitingCommand {
                    self.startListeningSoundscape()
                }
                self.speechRecognizer.restartCycle()
            }
        }
        audioManager.onCaptureRecoveryFailed = { [weak self] message in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                self.errorMessage = message
                self.stop()
                self.status = .failed
            }
        }
        audioManager.onPlaybackComplete = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                self.finishOutput()
            }
        }

        speechRecognizer.onPartial = { [weak self] text in
            Task { @MainActor [weak self] in
                self?.handlePartial(text)
            }
        }
        speechRecognizer.onFinal = { [weak self] text in
            Task { @MainActor [weak self] in
                self?.handleFinal(text)
            }
        }
        speechSynthesizer.onFinished = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                self.finishOutput()
            }
        }
        speechSynthesizer.onError = { [weak self] message in
            Task { @MainActor [weak self] in
                self?.errorMessage = message
            }
        }
    }

    private func clearAudioCallbacks() {
        audioManager.onRawBuffer = nil
        audioManager.onAudioChunk = nil
        audioManager.onSpeechDetected = nil
        audioManager.onSilenceDetected = nil
        audioManager.onLevel = nil
        audioManager.onMicWarning = nil
        audioManager.onRouteChanged = nil
        audioManager.onCaptureRecoveryFailed = nil
        audioManager.onPlaybackComplete = nil
        speechRecognizer.onPartial = nil
        speechRecognizer.onFinal = nil
        speechSynthesizer.onFinished = nil
        speechSynthesizer.onError = nil
    }

    private func refreshAudioRoute() {
        let input = audioManager.currentInputName
        let output = audioManager.currentOutputName
        outputRoute = output
        if audioManager.isUsingBluetoothInput {
            if audioManager.isUsingGlassesInput {
                micRoute = "Ray-Ban HFP · \(input)"
            } else {
                micRoute = "Bluetooth HFP · \(input)"
            }
        } else if isRunning {
            micRoute = "iPhone microphone · Ray-Ban HFP unavailable"
        } else {
            micRoute = "Not started"
        }
    }
}
