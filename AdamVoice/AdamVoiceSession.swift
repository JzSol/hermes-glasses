//
// AdamVoiceSession.swift
//
// The camera-free voice loop for the Adam prototype.  This target deliberately
// owns no wearables, camera, location, or display objects: the only hardware
// it opens is AVAudioSession through HermesAudioManager.
//

import Foundation
import Observation
import os

@MainActor
@Observable
final class AdamVoiceSession {
    enum Status: Equatable {
        case idle
        case connecting
        case reconnecting
        case armed
        case wakeAcknowledged
        case hearingSpeech
        case transcribing
        case thinking
        case preparingVoice
        case speaking
        case failed

        // Kept for source compatibility with the first Adam target API.
        case listening
        case awaitingCommand
        case processing

        var label: String {
            switch self {
            case .idle:
                return "Ready"
            case .connecting:
                return "Connecting to Adam…"
            case .reconnecting:
                return "Bridge offline — retrying…"
            case .armed, .listening:
                return "Listening for Adam"
            case .wakeAcknowledged, .awaitingCommand:
                return self == .awaitingCommand
                    ? "Follow-up listening — say donzo to finish"
                    : "Wake acknowledged — listening"
            case .hearingSpeech:
                return "Hearing your command"
            case .transcribing:
                return "Transcribing your command…"
            case .thinking, .processing:
                return "Adam is thinking…"
            case .preparingVoice:
                return "Preparing Adam’s voice…"
            case .speaking:
                return "Adam is speaking"
            case .failed:
                return "Needs attention"
            }
        }

        var logName: String {
            switch self {
            case .idle: return "idle"
            case .connecting: return "connecting"
            case .reconnecting: return "reconnecting"
            case .armed, .listening: return "armed"
            case .wakeAcknowledged: return "wake_acknowledged"
            case .awaitingCommand: return "follow_up_listening"
            case .hearingSpeech: return "hearing_speech"
            case .transcribing: return "transcribing"
            case .thinking, .processing: return "thinking"
            case .preparingVoice: return "preparing_voice"
            case .speaking: return "speaking"
            case .failed: return "failed"
            }
        }
    }

    /// Explicit phase vocabulary for new callers. `status` remains the
    /// original property name so existing Adam integrations keep compiling.
    typealias Phase = Status

    /// The route is intentionally an observed value so the UI can tell the
    /// wearer whether the requested glasses HFP route actually materialized.
    var status: Status = .idle {
        didSet {
            guard oldValue != status else { return }
            let elapsed = Date().timeIntervalSince(statusEnteredAt)
            Self.logger.info(
                "Adam phase \(oldValue.logName, privacy: .public) -> \(self.status.logName, privacy: .public), previous_phase_ms=\(Int(max(0, elapsed) * 1000), privacy: .public)"
            )
            statusEnteredAt = Date()
        }
    }
    var phase: Phase { status }
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

    /// True for the phases where a user can stop the current turn without
    /// stopping the always-armed session.
    var canCancelTurn: Bool {
        switch status {
        case .transcribing, .thinking, .preparingVoice, .speaking, .processing:
            return pendingRequestID != nil
        default:
            return false
        }
    }

    var canRetryTurn: Bool { status == .failed && isRunning }

    private var isTurnInFlight: Bool {
        pendingRequestID != nil
    }

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
    private static let thinkingPulseDelay: UInt64 = 900_000_000
    private static let thinkingPulseInterval: UInt64 = 2_800_000_000

    private static let logger = Logger(
        subsystem: "com.flowsxr.hermesglasses",
        category: "adam-phase"
    )

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
    @ObservationIgnored private var followUpModeSupported = false
    @ObservationIgnored private var activeCaptureIsFollowUp = false
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
    @ObservationIgnored private var captureRestoreTask: Task<Void, Never>?
    @ObservationIgnored private var captureRestoreSerial = 0
    @ObservationIgnored private var statusEnteredAt = Date()
    @ObservationIgnored private var turnGeneration = 0

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
        statusEnteredAt = Date()
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

        if enabled, isRunning, status == .wakeAcknowledged {
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
            status = bridgeConnected ? .armed : .reconnecting
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
        let requestID = pendingRequestID
        let shouldRestoreCapture = outputKind == .bridgeAudio
            || captureRestoreTask != nil
        if let requestID {
            _ = bridgeClient?.sendCancelTurn(requestID: requestID)
        }
        soundscape.stopImmediately()
        responseTimeoutTask?.cancel()
        responseTimeoutTask = nil
        turnGeneration &+= 1
        pendingRequestID = nil
        activeCaptureIsFollowUp = false
        commandWindowTask?.cancel()
        commandWindowTask = nil
        pendingBridgeAudio = false
        stopCurrentOutput()
        _ = wakeGate.failed()
        speechRecognizer.isSuspended = false
        isCapturingUtterance = false
        utteranceAudio.removeAll(keepingCapacity: true)
        lastUtteranceAudio.removeAll(keepingCapacity: true)
        preRollAudio.removeAll(keepingCapacity: true)
        bridgeClient?.sendNewSession()
        if isRunning, shouldRestoreCapture {
            restoreCaptureAfterPlayback(generation: turnGeneration)
        } else if isRunning {
            status = bridgeConnected ? .armed : .reconnecting
        }
        lastCommand = ""
        lastResponse = ""
        liveTranscript = ""
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        let previousRestore = captureRestoreTask
        previousRestore?.cancel()
        captureRestoreTask = nil
        captureRestoreSerial &+= 1
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
        followUpModeSupported = false
        activeCaptureIsFollowUp = false
        turnGeneration &+= 1
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
            if let previousRestore {
                await previousRestore.value
            }
            guard !Task.isCancelled else { return }
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
        audioManager.mediaDuckingEnabled = false

        _ = wakeGate.cancel()
        pendingBridgeAudio = false
        activeCaptureIsFollowUp = false
        outputKind = nil
        cancellingOutput = false
        ignoredOutputCompletions = 0
        captureRestoreTask?.cancel()
        captureRestoreSerial &+= 1
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
            audioManager.mediaDuckingEnabled = true
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
            status = .armed
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
                self.status = .thinking
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
                if self.pendingRequestID != nil {
                    self.failResponse(message)
                } else {
                    self.errorMessage = message
                }
            }
        }
        client.onErrorWithRequestID = {
            [weak self, weak client] message, requestID in
            Task { @MainActor [weak self, weak client] in
                guard let self, let client,
                      self.isCurrentBridge(client, generation: generation),
                      requestID == nil || requestID == self.pendingRequestID else {
                    return
                }
                if self.pendingRequestID != nil {
                    self.failResponse(message)
                } else {
                    self.errorMessage = message
                }
            }
        }
        client.onCapabilities = { [weak self] capabilities in
            Task { @MainActor [weak self] in
                self?.followUpModeSupported = capabilities.followUpMode
                guard capabilities.audioUpload,
                      capabilities.serverSTT,
                      capabilities.streamingTTS else {
                    self?.errorMessage = "Update the Adam bridge on your Mac for server speech."
                    return
                }
            }
        }
        client.onTurnCancelled = { [weak self, weak client] requestID in
            Task { @MainActor [weak self, weak client] in
                guard let self, let client,
                      self.isCurrentBridge(client, generation: generation),
                      requestID == nil || requestID == self.pendingRequestID else { return }
                // Local cancellation already returns to listening. This
                // callback is intentionally idempotent for remote confirms.
                self.errorMessage = nil
            }
        }
        client.onFollowUpEnded = { [weak self, weak client] requestID in
            Task { @MainActor [weak self, weak client] in
                guard let self, let client,
                      self.isCurrentBridge(client, generation: generation),
                      let pendingRequestID = self.pendingRequestID,
                      requestID == nil || requestID == pendingRequestID else { return }
                self.finishFollowUpMode(playCompletionCue: false)
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
        followUpModeSupported = false
        commandWindowTask?.cancel()
        commandWindowTask = nil
        _ = wakeGate.cancel()
        client.onDisconnected = nil
        bridgeClient = nil
        bridgeGeneration += 1

        if outputKind == nil, isTurnInFlight {
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
            client.onErrorWithRequestID = nil
            client.onCapabilities = nil
            client.onCapturePhotoRequested = nil
            client.onSessionReset = nil
            client.onAttention = nil
            client.onTurnCancelled = nil
            client.onFollowUpEnded = nil
            client.disconnect()
        }
        bridgeClient = nil
        bridgeConnected = false
        followUpModeSupported = false
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
                self.status = self.outputKind == nil ? .armed : .speaking
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
        // authoritative command transcript comes from Hermes's configured STT.
        let action = wakeGate.handlePartial(text)
        if action == .rearmed || wakeGate.timeout() {
            finishListeningSoundscape()
            commandWindowTask?.cancel()
            commandWindowTask = nil
            liveTranscript = ""
            status = bridgeConnected ? .armed : .reconnecting
        }
    }

    private func handleFinal(_ text: String) {
        guard isRunning else { return }
        if pendingRequestID != nil {
            if status == .transcribing || status == .thinking,
               Self.isVoiceCancelCommand(text) {
                cancelTurn()
            }
            return
        }
        guard outputKind == nil else { return }
        // A2DP is playback-only on iOS. There is no safe voice barge-in path
        // once capture has been released for high-quality response audio.
        guard status != .speaking || audioManager.isUsingBluetoothInput else { return }
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
            status = .wakeAcknowledged
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
            status = bridgeConnected ? .armed : .reconnecting
        case .followUpOpened:
            status = .awaitingCommand
            armCommandWindowTimeout()
        case .followUpEnded:
            finishFollowUpMode(playCompletionCue: true)
        }
    }

    private func armCommandWindowTimeout() {
        commandWindowTask?.cancel()
        guard let remaining = wakeGate.remainingCommandWindow(), remaining > 0 else {
            commandWindowTask = nil
            let wasFollowUp = wakeGate.state.isFollowUp
            if wakeGate.timeout() {
                finishListeningSoundscape(playCompletionIfIdle: wasFollowUp)
                liveTranscript = ""
                status = bridgeConnected ? .armed : .reconnecting
            }
            return
        }
        let nanoseconds = UInt64((remaining * 1_000_000_000).rounded(.up))
        commandWindowTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled, let self, self.isRunning else { return }
            self.commandWindowTask = nil
            let wasFollowUp = self.wakeGate.state.isFollowUp
            if self.wakeGate.timeout() {
                self.finishListeningSoundscape(playCompletionIfIdle: wasFollowUp)
                self.liveTranscript = ""
                self.isCapturingUtterance = false
                self.activeCaptureIsFollowUp = false
                self.utteranceAudio.removeAll(keepingCapacity: true)
                self.lastUtteranceAudio.removeAll(keepingCapacity: true)
                self.status = self.bridgeConnected ? .armed : .reconnecting
            } else if self.wakeGate.state.isAwaitingCommand {
                // A clock tick can wake a fraction before the deadline. Keep
                // waiting rather than losing the command window.
                self.armCommandWindowTimeout()
            }
        }
    }

    private func submitRecordedUtterance() {
        commandWindowTask?.cancel()
        commandWindowTask = nil
        let isFollowUp = followUpModeSupported
            && (activeCaptureIsFollowUp || wakeGate.state.isFollowUp)
        activeCaptureIsFollowUp = false
        _ = wakeGate.cancel()
        let audio = takeRecordedUtterance()
        guard audio.count >= 640, audioHasMeaningfulEnergy(audio) else {
            soundscape.stopImmediately()
            _ = wakeGate.failed()
            errorMessage = "I did not receive enough audio. Say Adam and try again."
            status = bridgeConnected ? .armed : .reconnecting
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

        status = .transcribing
        pendingBridgeAudio = false
        let requestID = UUID().uuidString
        pendingRequestID = requestID
        turnGeneration &+= 1
        let requestGeneration = turnGeneration
        if listeningSoundsEnabled {
            soundscape.scheduleThinkingPulse(
                startAfter: Double(Self.thinkingPulseDelay) / 1_000_000_000,
                repeatEvery: Double(Self.thinkingPulseInterval) / 1_000_000_000
            )
        }
        responseTimeoutTask?.cancel()
        responseTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.responseTimeout)
            guard !Task.isCancelled, let self, self.isRunning,
                  self.pendingRequestID == requestID,
                  self.status == .transcribing || self.status == .thinking
                    || self.status == .preparingVoice else { return }
            self.failResponse("Adam did not answer before the request timed out.")
        }

        // Keep the HFP recognizer alive only for the exact "Adam stop"
        // cancellation command while Hermes is thinking. Phone/A2DP routes
        // cannot provide a safe input path here, so their recognizer stays
        // suspended until capture resumes.
        speechRecognizer.isSuspended = !audioManager.isUsingBluetoothInput
        let terms = vocabulary.split(separator: ",").map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        Task { @MainActor [weak self, weak client] in
            guard let self, let client,
                  self.isRunning, self.pendingRequestID == requestID,
                  self.turnGeneration == requestGeneration else { return }
            do {
                try await client.uploadAudioCapture(
                    audio,
                    requestID: requestID,
                    vocabulary: terms,
                    followUp: isFollowUp
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
            status = .preparingVoice
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
        // The first actual PCM reply ends the thinking feedback, even when
        // the bridge sends response text before opening its audio stream.
        soundscape.stopThinkingPulse()
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
        soundscape.stopThinkingPulse()
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
        status = .preparingVoice
        speechRecognizer.isSuspended = true

        audioManager.beginResponseStream()
        audioManager.enqueueResponseSegment(data, sampleRate: sampleRate)

        // Release HFP before playback so iOS can route full-band audio over
        // A2DP. The physical route transition is allowed up to 1.5 seconds;
        // if it does not appear we still play, but report the fallback.
        audioManager.stopCapture()
        let requestGeneration = turnGeneration
        Task { @MainActor [weak self] in
            guard let self, self.isRunning,
                  self.outputKind == .bridgeAudio,
                  self.turnGeneration == requestGeneration else { return }
            do {
                try self.audioManager.prepareHighQualityPlayback()
                for _ in 0..<15 where !self.audioManager.outputIsBluetooth {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            } catch {
                self.micWarning = "High-quality playback was unavailable; using the current output."
            }
            guard self.isRunning, self.outputKind == .bridgeAudio,
                  self.turnGeneration == requestGeneration else { return }
            self.refreshAudioRoute()
            if !self.audioManager.outputIsBluetooth {
                self.micWarning = "Ray-Ban A2DP did not connect; Adam is using \(self.outputRoute)."
            }
            guard self.isRunning, self.outputKind == .bridgeAudio,
                  self.turnGeneration == requestGeneration else { return }
            self.status = .speaking
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

    private func restoreCaptureAfterPlayback(
        generation: Int? = nil,
        completeTurn: Bool = true
    ) {
        let expectedGeneration = generation ?? turnGeneration
        let previousRestore = captureRestoreTask
        previousRestore?.cancel()
        captureRestoreSerial &+= 1
        let restoreSerial = captureRestoreSerial
        captureRestoreTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if let previousRestore {
                await previousRestore.value
            }
            guard !Task.isCancelled, self.isRunning,
                  self.turnGeneration == expectedGeneration,
                  self.captureRestoreSerial == restoreSerial else {
                return
            }
            do {
                _ = try await self.audioManager.startCapture(route: .glassesMic)
                guard !Task.isCancelled, self.isRunning,
                      self.turnGeneration == expectedGeneration,
                      self.captureRestoreSerial == restoreSerial else {
                    self.audioManager.stopCapture()
                    return
                }
                self.refreshAudioRoute()
                self.speechRecognizer.restartCycle()
                self.micWarning = nil
                self.captureRestoreTask = nil
                if completeTurn {
                    self.finishResponse()
                } else {
                    self.status = .failed
                }
            } catch is CancellationError {
                return
            } catch {
                guard self.captureRestoreSerial == restoreSerial,
                      self.turnGeneration == expectedGeneration else { return }
                self.captureRestoreTask = nil
                self.errorMessage =
                    "The Ray-Ban microphone did not reconnect. Start Adam again."
                self.status = .failed
            }
        }
    }

    private func finishResponse() {
        soundscape.stopThinkingPulse()
        pendingBridgeAudio = false
        responseTimeoutTask?.cancel()
        responseTimeoutTask = nil
        pendingRequestID = nil
        let shouldOpenFollowUp = bridgeConnected && followUpModeSupported
        if !shouldOpenFollowUp { _ = wakeGate.cancel() }
        status = bridgeConnected ? .armed : .reconnecting
        scheduleSpeechResume(openFollowUp: shouldOpenFollowUp)
        if !bridgeConnected { scheduleReconnect() }
    }

    private func finishFollowUpMode(playCompletionCue: Bool) {
        soundscape.stopThinkingPulse()
        responseTimeoutTask?.cancel()
        responseTimeoutTask = nil
        commandWindowTask?.cancel()
        commandWindowTask = nil
        pendingRequestID = nil
        pendingBridgeAudio = false
        activeCaptureIsFollowUp = false
        isCapturingUtterance = false
        utteranceAudio.removeAll(keepingCapacity: true)
        lastUtteranceAudio.removeAll(keepingCapacity: true)
        _ = wakeGate.cancel()
        speechRecognizer.isSuspended = false
        if playCompletionCue, listeningSoundsEnabled {
            soundscape.playCompletionCue()
        }
        status = bridgeConnected ? .armed : .reconnecting
        if !bridgeConnected { scheduleReconnect() }
    }

    private func failResponse(_ message: String) {
        let shouldRestoreCapture = outputKind == .bridgeAudio
            || captureRestoreTask != nil
        soundscape.stopImmediately()
        stopCurrentOutput()
        responseTimeoutTask?.cancel()
        responseTimeoutTask = nil
        pendingRequestID = nil
        pendingBridgeAudio = false
        activeCaptureIsFollowUp = false
        errorMessage = message
        _ = wakeGate.failed()
        turnGeneration &+= 1
        status = .failed
        speechRecognizer.isSuspended = false
        if shouldRestoreCapture {
            restoreCaptureAfterPlayback(
                generation: turnGeneration,
                completeTurn: false
            )
        }
        if !bridgeConnected { scheduleReconnect() }
    }

    /// Stop the active turn while keeping the always-armed session alive.
    /// The bridge request is best-effort and only sent to bridges that
    /// advertised the additive cancellation capability; local teardown never
    /// waits for that response.
    func cancelTurn() {
        guard canCancelTurn, let requestID = pendingRequestID else { return }
        let shouldRestoreCapture = outputKind == .bridgeAudio
            || captureRestoreTask != nil
        _ = bridgeClient?.sendCancelTurn(requestID: requestID)

        turnGeneration &+= 1
        responseTimeoutTask?.cancel()
        responseTimeoutTask = nil
        pendingRequestID = nil
        pendingBridgeAudio = false
        activeCaptureIsFollowUp = false
        commandWindowTask?.cancel()
        commandWindowTask = nil
        soundscape.stopImmediately()
        stopCurrentOutput()
        _ = wakeGate.cancel()
        speechRecognizer.isSuspended = false
        isCapturingUtterance = false
        utteranceAudio.removeAll(keepingCapacity: true)
        lastUtteranceAudio.removeAll(keepingCapacity: true)
        preRollAudio.removeAll(keepingCapacity: true)

        if shouldRestoreCapture {
            restoreCaptureAfterPlayback(generation: turnGeneration)
        } else {
            status = bridgeConnected ? .armed : .reconnecting
            if !bridgeConnected { scheduleReconnect() }
        }
    }

    /// Recover from a failed turn without dropping the running audio session.
    func retryTurn() {
        guard canRetryTurn else { return }
        turnGeneration &+= 1
        let expectedGeneration = turnGeneration
        _ = wakeGate.failed()
        status = .connecting
        Task { @MainActor [weak self] in
            guard let self, self.isRunning,
                  self.turnGeneration == expectedGeneration else { return }
            do {
                _ = try await self.audioManager.startCapture(route: .glassesMic)
                guard self.isRunning,
                      self.turnGeneration == expectedGeneration else {
                    self.audioManager.stopCapture()
                    return
                }
                self.refreshAudioRoute()
                self.speechRecognizer.restartCycle()
                self.speechRecognizer.isSuspended = false
                self.micWarning = nil
                self.errorMessage = nil
                self.status = self.bridgeConnected ? .armed : .reconnecting
                if !self.bridgeConnected { self.scheduleReconnect() }
            } catch {
                guard self.turnGeneration == expectedGeneration else { return }
                self.errorMessage =
                    "The microphone could not restart. Stop and start Adam."
                self.status = .failed
            }
        }
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

    private func scheduleSpeechResume(openFollowUp: Bool = false) {
        speechResumeTask?.cancel()
        speechResumeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.speechResumeGrace)
            guard !Task.isCancelled, let self, self.isRunning else { return }
            self.speechResumeTask = nil
            self.speechRecognizer.isSuspended = false
            guard openFollowUp, self.bridgeConnected,
                  self.followUpModeSupported else {
                _ = self.wakeGate.cancel()
                return
            }
            let action = self.wakeGate.completed()
            if action == .followUpOpened {
                self.status = .awaitingCommand
                self.armCommandWindowTimeout()
            }
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
              pendingRequestID == nil,
              status == .armed || status == .wakeAcknowledged
                || status == .awaitingCommand else { return }
        activeCaptureIsFollowUp = wakeGate.state.isFollowUp
        utteranceAudio = preRollAudio
        isCapturingUtterance = true
        if wakeGate.state.isAwaitingCommand {
            commandWindowTask?.cancel()
            commandWindowTask = nil
            status = .hearingSpeech
        }
        if wakeGate.state.isAwaitingCommand, listeningSoundsEnabled {
            soundscape.playSpeechStartCue()
        }
    }

    private func handleSpeechEnded() {
        guard isCapturingUtterance else { return }
        isCapturingUtterance = false
        lastUtteranceAudio = utteranceAudio
        utteranceAudio.removeAll(keepingCapacity: true)
        if wakeGate.state.isAwaitingCommand {
            // VAD has observed 650 ms of silence. Do not wait for Apple's
            // final recognition callback; the bridge performs authoritative
            // transcription from this complete PCM capture.
            submitRecordedUtterance()
        } else if status == .hearingSpeech {
            // A single "Adam plus question" utterance still waits for
            // Apple's final text so WakeWordGate can strip the wake prefix.
            status = .armed
            activeCaptureIsFollowUp = false
        }
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

    /// Reject silence and near-digital noise before it can become a bridge
    /// turn. This check is intentionally metadata-only: it never logs or
    /// exposes the samples.
    private func audioHasMeaningfulEnergy(_ data: Data) -> Bool {
        let count = data.count / MemoryLayout<Int16>.size
        guard count > 0 else { return false }
        return data.withUnsafeBytes { raw in
            var sum: Double = 0
            for index in 0..<count {
                let offset = index * 2
                let bits = UInt16(raw[offset]) | (UInt16(raw[offset + 1]) << 8)
                let normalized = Double(Int16(bitPattern: bits)) / 32768
                sum += normalized * normalized
            }
            return sqrt(sum / Double(count)) > 0.0025
        }
    }

    private static func isVoiceCancelCommand(_ text: String) -> Bool {
        let words = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        return words == ["adam", "stop"]
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
                if self.status == .wakeAcknowledged {
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
                guard let self else { return }
                if self.pendingRequestID != nil {
                    self.failResponse(message)
                } else {
                    self.errorMessage = message
                }
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
