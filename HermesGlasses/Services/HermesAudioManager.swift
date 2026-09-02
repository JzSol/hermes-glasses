//
// HermesAudioManager.swift
//
// Manages audio capture from Meta Ray-Ban glasses and playback of
// Hermes Agent TTS responses. Uses AVAudioEngine for capture and reliable
// AVAudioPlayer clips for Bluetooth-safe response playback.
//

import AVFoundation
import Foundation
import os

/// Where voice capture (and, on Bluetooth, playback) is routed
enum CaptureRoute: Sendable {
    /// iPhone built-in mic; playback on the phone speaker
    case phoneMic
    /// Glasses over Bluetooth HFP - bidirectional, but on Display glasses
    /// the firmware shows its CALL SCREEN, covering the lens HUD
    case glassesMic
    /// Earbuds/headset over Bluetooth HFP - mic + voice in the ears while
    /// the glasses' lens stays free for the HUD
    case headsetMic
}

/// Manages audio capture and playback for the Hermes Glasses app
final class HermesAudioManager: NSObject, @unchecked Sendable {
    // MARK: - Callbacks
    //
    // Assigned on the main actor, read on the audio-render thread. They live
    // in one locked struct and the tap snapshots the whole set once per
    // buffer, so a mid-buffer reassignment can't be seen half-applied.

    private struct Callbacks {
        var onAudioChunk: ((Data) -> Void)?
        var onSpeechDetected: (() -> Void)?
        var onSilenceDetected: (() -> Void)?
        var onPlaybackComplete: (() -> Void)?
        var onDebug: ((String) -> Void)?
        var onRawBuffer: ((AVAudioPCMBuffer) -> Void)?
        var onLevel: ((Float) -> Void)?
        var onMicWarning: ((String?) -> Void)?
        var onRouteChanged: (() -> Void)?
        var onCaptureRecoveryFailed: ((String) -> Void)?
    }

    private let callbackLock = OSAllocatedUnfairLock(uncheckedState: Callbacks())

    var onAudioChunk: ((Data) -> Void)? {
        get { callbackLock.withLockUnchecked { $0.onAudioChunk } }
        set { callbackLock.withLockUnchecked { $0.onAudioChunk = newValue } }
    }
    var onSpeechDetected: (() -> Void)? {
        get { callbackLock.withLockUnchecked { $0.onSpeechDetected } }
        set { callbackLock.withLockUnchecked { $0.onSpeechDetected = newValue } }
    }
    var onSilenceDetected: (() -> Void)? {
        get { callbackLock.withLockUnchecked { $0.onSilenceDetected } }
        set { callbackLock.withLockUnchecked { $0.onSilenceDetected = newValue } }
    }
    var onPlaybackComplete: (() -> Void)? {
        get { callbackLock.withLockUnchecked { $0.onPlaybackComplete } }
        set { callbackLock.withLockUnchecked { $0.onPlaybackComplete = newValue } }
    }
    /// Diagnostic messages (mic route, levels) for remote debugging
    var onDebug: ((String) -> Void)? {
        get { callbackLock.withLockUnchecked { $0.onDebug } }
        set { callbackLock.withLockUnchecked { $0.onDebug = newValue } }
    }
    /// Raw tap buffer, pre-conversion - for on-device speech recognition
    var onRawBuffer: ((AVAudioPCMBuffer) -> Void)? {
        get { callbackLock.withLockUnchecked { $0.onRawBuffer } }
        set { callbackLock.withLockUnchecked { $0.onRawBuffer = newValue } }
    }
    /// Smoothed dBFS mic level (0...1), throttled to ~4/s - for the UI meter.
    var onLevel: ((Float) -> Void)? {
        get { callbackLock.withLockUnchecked { $0.onLevel } }
        set { callbackLock.withLockUnchecked { $0.onLevel = newValue } }
    }
    /// Sustained low-input warning, with `nil` clearing the current warning.
    /// The callback is delivered on the main queue and includes the active
    /// route (Ray-Ban HFP, another Bluetooth mic, or the iPhone mic).
    var onMicWarning: ((String?) -> Void)? {
        get { callbackLock.withLockUnchecked { $0.onMicWarning } }
        set { callbackLock.withLockUnchecked { $0.onMicWarning = newValue } }
    }
    /// Fired (on main) after a route/config change re-installed the tap.
    /// Consumers feeding SFSpeech MUST restart their recognition request -
    /// it cannot absorb a buffer-format change mid-request.
    var onRouteChanged: (() -> Void)? {
        get { callbackLock.withLockUnchecked { $0.onRouteChanged } }
        set { callbackLock.withLockUnchecked { $0.onRouteChanged = newValue } }
    }
    /// Fired after an iOS audio interruption when capture could not be
    /// restored. Consumers must leave their listening state; no live engine
    /// exists after this callback.
    var onCaptureRecoveryFailed: ((String) -> Void)? {
        get { callbackLock.withLockUnchecked { $0.onCaptureRecoveryFailed } }
        set { callbackLock.withLockUnchecked { $0.onCaptureRecoveryFailed = newValue } }
    }

    /// Converted PCM16 mono 16 kHz samples, delivered ON THE AUDIO THREAD and
    /// ungated by VAD - for `ConversationRecorder`.
    ///
    /// Deliberately NOT `onAudioChunk`, which hops to main: at ~47 buffers a
    /// second, routing a recording through the main queue makes the recording
    /// hostage to whatever the UI is doing. Handlers must not block; the
    /// recorder only enqueues onto its own serial queue.
    ///
    /// This one has its own lock, and it is the ONE callback invoked with a
    /// lock held. `finishConversationCapture` nils it out and then closes the
    /// recorder's file handle, so "no chunk can still be in flight once the
    /// setter returns" has to be a guarantee, not a hope - a snapshot taken
    /// one instruction before the nil-out would otherwise write into a closed
    /// handle. The contract above (enqueue and return, never block, never
    /// call back into this class) is what keeps that safe on a real-time
    /// thread.
    var onRecordChunk: ((Data) -> Void)? {
        get { recordChunkLock.withLockUnchecked { $0 } }
        set { recordChunkLock.withLockUnchecked { $0 = newValue } }
    }

    private let recordChunkLock = OSAllocatedUnfairLock<((Data) -> Void)?>(
        uncheckedState: nil
    )

    /// These knobs are intentionally off by default. Adam enables them for
    /// its own recognition path; the original Hermes target never touches
    /// them and therefore keeps receiving the source buffers unchanged.
    private struct AdamAudioSettings {
        var recognitionConditioningEnabled = false
        var bridgeConditioningEnabled = false
        var maximumInputGainEnabled = false
        var mediaDuckingEnabled = false
    }

    private let adamAudioSettingsLock = OSAllocatedUnfairLock(
        uncheckedState: AdamAudioSettings()
    )

    /// Apply Adam's bounded copy-only conditioner before on-device speech
    /// recognition. This is disabled by default for the original app.
    var recognitionConditioningEnabled: Bool {
        get { adamAudioSettingsLock.withLockUnchecked { $0.recognitionConditioningEnabled } }
        set { adamAudioSettingsLock.withLockUnchecked { $0.recognitionConditioningEnabled = newValue } }
    }

    /// Apply bounded adaptive gain to Adam's 16 kHz bridge upload. This is a
    /// separate opt-in because recordings and the original Hermes target must
    /// retain their source samples exactly.
    var bridgeConditioningEnabled: Bool {
        get { adamAudioSettingsLock.withLockUnchecked { $0.bridgeConditioningEnabled } }
        set { adamAudioSettingsLock.withLockUnchecked { $0.bridgeConditioningEnabled = newValue } }
    }

    /// Request the highest input gain supported by the active audio route.
    /// Bluetooth HFP ports frequently report this as unavailable, so callers
    /// must treat this as a best-effort enhancement rather than a guarantee.
    var maximumInputGainEnabled: Bool {
        get { adamAudioSettingsLock.withLockUnchecked { $0.maximumInputGainEnabled } }
        set {
            adamAudioSettingsLock.withLockUnchecked { $0.maximumInputGainEnabled = newValue }
            if newValue { applyMaximumInputGainIfPossible() }
        }
    }

    /// Ask iOS to lower audio from other apps while Adam's voice session is
    /// active. This remains opt-in so the original Hermes target preserves
    /// its existing mixing behavior.
    var mediaDuckingEnabled: Bool {
        get { adamAudioSettingsLock.withLockUnchecked { $0.mediaDuckingEnabled } }
        set { adamAudioSettingsLock.withLockUnchecked { $0.mediaDuckingEnabled = newValue } }
    }

    /// Pause only speech/silence transition callbacks. Raw capture keeps
    /// running so the audio route stays stable, while both boundaries discard
    /// in-progress VAD state so a local cue cannot leak into a real utterance.
    func setSpeechDetectionSuppressed(_ suppressed: Bool) {
        tapLock.withLockUnchecked { state in
            state.speechDetectionSuppressed = suppressed
            state.isSpeechActive = false
            state.silenceDuration = 0
        }
    }

    // MARK: - Private

    private let logger = Logger(subsystem: "com.flowsxr.hermesglasses", category: "audio")

    // Rebuilt fresh on every startCapture: AVAudioEngine caches the audio
    // graph/hardware formats of the previous route, and starting a stale
    // engine after an HFP route change fails with -10868
    // (kAudioUnitErr_FormatNotSupported). reset() is not enough.
    private var audioEngine = AVAudioEngine()
    private var inputNode: AVAudioNode { audioEngine.inputNode }
    private var outputNode: AVAudioNode { audioEngine.outputNode }
    private let captureFormat: AVAudioFormat

    private var isCapturing: Bool = false
    private var configChangeObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var interruptionRecoveryTask: Task<Void, Never>?
    private var requestedCaptureRoute: CaptureRoute = .phoneMic
    private var isInterrupted = false

    /// External-capture mode: no AVAudioEngine, no tap - buffers are pushed
    /// in through `ingest` by whoever owns the microphone (the AiSee kit).
    ///
    /// Written from the session actor and read on the SDK's audio thread at
    /// ~50 buffers a second, so it lives behind the same lock as the rest of
    /// the tap state rather than as a bare `Bool`.
    private var externalCapture: Bool {
        get { tapLock.withLockUnchecked { $0.externalCapture } }
        set { tapLock.withLockUnchecked { $0.externalCapture = newValue } }
    }

    /// Everything the tap block touches. `startCapture`/`rebuildEngine`/
    /// `stopCapture` run off the main actor (they are `async` on a
    /// non-isolated class) while the tap is live on the audio-render thread,
    /// so all of it is read and written concurrently.
    private struct TapState {
        // Lazy conversion state - rebuilt whenever the tap's buffer format changes
        var converter: AVAudioConverter?
        var converterInputFormat: AVAudioFormat?
        var bufferCount: Int = 0
        var lastDebugTime: TimeInterval = 0
        var lastLevelTime: TimeInterval = 0
        var smoothedLevel: Float = 0
        var lowInputSince: TimeInterval?
        var lowInputRoute: String?
        var lowInputWarningActive = false
        var ambientNoiseRMS: Float = 0.001
        // VAD
        var isSpeechActive: Bool = false
        var silenceDuration: TimeInterval = 0
        // Adam briefly closes VAD while its own wake cue is audible. Without
        // this, HFP loopback can turn the cue into a phantom command.
        var speechDetectionSuppressed = false
        // True while buffers arrive via `ingest` instead of an engine tap
        var externalCapture: Bool = false
    }

    private let tapLock = OSAllocatedUnfairLock(uncheckedState: TapState())

    // VAD tuning
    /// Endpoint on elapsed PCM time, not callback count. Audio callbacks have
    /// different frame sizes across HFP and phone routes.
    private let silenceDuration: TimeInterval = 0.650
    private let vadDisabled: Bool = true

    // A warning is deliberately slower and less sensitive than VAD. HFP
    // microphones can be quiet for a few buffers while a route settles, but a
    // sustained value below roughly -42 dBFS is a useful indication that the
    // wearer is speaking into the wrong mic or that the route is unhealthy.
    private let lowInputThreshold: Float = 0.008
    /// Do not treat ordinary room silence as a broken microphone. A warning
    /// starts only when there is sustained low-level activity below the
    /// healthy speech threshold.
    private let lowInputActivityFloor: Float = 0.0015
    private let lowInputWarningDelay: TimeInterval = 3

    // Playback - a self-contained clip player, independent of the engine
    private var clipPlayer: AVAudioPlayer?
    private struct QueuedResponseClip {
        let data: Data
        let sampleRate: Int
    }
    private var responseClipQueue: [QueuedResponseClip] = []
    private var responseStreamActive = false
    private var responseStreamOpen = false
    private var responseStreamReady = false

    override init() {
        // 16 kHz mono PCM16 - the format the bridge expects. This
        // initializer cannot fail for a standard PCM format.
        captureFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!

        super.init()
    }

    // MARK: - Public API

    var currentInputName: String {
        let session = AVAudioSession.sharedInstance()
        return session.currentRoute.inputs.first?.portName ?? "Unknown"
    }

    /// Where playback is going right now ("Speaker", "AiSee-G1", AirPods…).
    var currentOutputName: String {
        let outs = AVAudioSession.sharedInstance().currentRoute.outputs
        return outs.map(\.portName).joined(separator: ", ").isEmpty ? "Unknown" : outs.map(\.portName).joined(separator: ", ")
    }

    /// True when playback is on a Bluetooth output (A2DP/HFP/LE).
    var outputIsBluetooth: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains {
            [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE].contains($0.portType)
        }
    }

    var isUsingBluetoothInput: Bool {
        AVAudioSession.sharedInstance().currentRoute.inputs.contains {
            $0.portType == .bluetoothHFP || $0.portType == .bluetoothA2DP
        }
    }

    /// Heuristic: does this Bluetooth port belong to the glasses (vs
    /// earbuds/headset)? Used to keep headset mode off the glasses' HFP -
    /// their call screen would cover the lens HUD.
    private static let glassesNameMarkers = ["ray-ban", "rayban", "oakley", "meta", "glasses"]

    private static func looksLikeGlasses(_ port: AVAudioSessionPortDescription) -> Bool {
        let name = port.portName.lowercased()
        return glassesNameMarkers.contains { name.contains($0) }
    }

    /// True when the ACTIVE input is the glasses' hands-free link - the
    /// state in which Display glasses show their call screen over the HUD
    var isUsingGlassesInput: Bool {
        AVAudioSession.sharedInstance().currentRoute.inputs.contains {
            ($0.portType == .bluetoothHFP || $0.portType == .bluetoothA2DP)
                && Self.looksLikeGlasses($0)
        }
    }

    /// Start capturing on the requested route. Returns true when the
    /// requested Bluetooth route is actually active - false means the
    /// iPhone mic is in use (by choice, or as fallback when the Bluetooth
    /// route never appeared / no matching device was found).
    @discardableResult
    func startCapture(route: CaptureRoute = .phoneMic) async throws -> Bool {
        guard await requestMicrophonePermission() else {
            logger.error("Microphone permission denied")
            throw HermesAudioError.microphonePermissionDenied
        }
        try Task.checkCancellation()
        requestedCaptureRoute = route

        let session = AVAudioSession.sharedInstance()

        var wantBluetooth = false
        if route != .phoneMic {
            // Mode .default, NOT .voiceChat - its DSP gates speech to the
            // noise floor. HFP is bidirectional: TTS also moves to the
            // chosen device's speakers while this mode is active (by design).
            try configureAudioSessionCategory(
                session,
                .playAndRecord,
                mode: .default,
                options: [.allowBluetoothHFP]
            )

            let hfpInputs = (session.availableInputs ?? [])
                .filter { $0.portType == .bluetoothHFP }
            let target: AVAudioSessionPortDescription?
            switch route {
            case .glassesMic:
                // A generic fallback can silently choose AirPods or another
                // person's headset. If no Ray-Ban/Meta-labelled input exists,
                // use the explicitly reported iPhone fallback instead.
                target = hfpInputs.first(where: Self.looksLikeGlasses)
            case .headsetMic:
                // NEVER fall back to the glasses here - that would put the
                // call screen over the HUD the user chose this mode to keep
                target = hfpInputs.first { !Self.looksLikeGlasses($0) }
            case .phoneMic:
                target = nil
            }

            if let target {
                logger.info("Preferring Bluetooth input: \(target.portName, privacy: .public)")
                try session.setPreferredInput(target)
                try session.setActive(true)
                wantBluetooth = true

                // Wait up to 3s for the Bluetooth route, without blocking the thread
                for _ in 0..<30 where !requestedRouteIsActive(route) {
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                if !requestedRouteIsActive(route) { wantBluetooth = false }
            }

            if !wantBluetooth || !isUsingBluetoothInput {
                // Requested device absent or route never materialized -
                // fall back to the iPhone mic so the session still works.
                logger.warning("Bluetooth route unavailable for \(String(describing: route), privacy: .public) - falling back to iPhone mic")
                try? session.setPreferredInput(nil)
                try configureAudioSessionCategory(
                    session,
                    .playAndRecord,
                    mode: .default,
                    options: [.defaultToSpeaker]
                )
                try session.setActive(true)
            }
        } else {
            // iPhone mic only: no Bluetooth options, so iOS cannot
            // re-route input to the glasses and kill the tap.
            try configureAudioSessionCategory(
                session,
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker]
            )
            try session.setActive(true)
        }

        logger.info("Audio session active. Input route: \(self.currentInputName, privacy: .public)")

        // Route changes (especially to/from HFP) renegotiate the hardware
        // sample rate - let it settle before touching the engine.
        try await Task.sleep(nanoseconds: 300_000_000)
        try Task.checkCancellation()

        // Input gain is a best-effort route capability. Apply it only after
        // Bluetooth has settled so an HFP route that supports gain receives
        // the request, while unsupported routes simply continue normally.
        applyMaximumInputGainIfPossible()

        // Fresh engine every start: the old instance's cached graph is what
        // produces -10868 after a route change. The old player node dies
        // with the old engine (never detach - that raises NSException).
        rebuildEngine()

        var waited = 0
        while inputNode.outputFormat(forBus: 0).sampleRate == 0, waited < 10 {
            try await Task.sleep(nanoseconds: 200_000_000)
            waited += 1
        }
        try Task.checkCancellation()

        isCapturing = true
        tapLock.withLockUnchecked { state in
            state.bufferCount = 0
            state.smoothedLevel = 0
            state.lowInputSince = nil
            state.lowInputRoute = nil
            state.lowInputWarningActive = false
            state.ambientNoiseRMS = 0.001
            state.isSpeechActive = false
            state.silenceDuration = 0
            state.speechDetectionSuppressed = false
            // Defensive: an engine tap and `ingest` must never both feed the
            // pipeline. `stopCapture()` clears this, but a caller that switched
            // routes without one would otherwise leave `ingest` armed alongside
            // the tap installed below.
            state.externalCapture = false
        }
        observeConfigurationChanges()
        observeAudioInterruptions()
        installTap()
        do {
            try audioEngine.start()
        } catch {
            // One retry with another fresh engine - the first start can
            // race the route transition
            logger.warning("Engine start failed (\(error.localizedDescription, privacy: .public)) - rebuilding and retrying")
            try await Task.sleep(nanoseconds: 500_000_000)
            try Task.checkCancellation()
            rebuildEngine()
            observeConfigurationChanges()
            observeAudioInterruptions()
            installTap()
            try audioEngine.start()
        }
        if Task.isCancelled {
            stopCapture()
            throw CancellationError()
        }
        logger.info("Audio engine started")
        return isUsingBluetoothInput
    }

    /// Start a capture that is fed from OUTSIDE - the AiSee kit delivers its
    /// own 16 kHz PCM over Bluetooth, so there is no iOS input route to open.
    ///
    /// The audio session is configured like the phone route (`.playAndRecord`,
    /// so TTS still plays), plus `.allowBluetoothA2DP` so TTS can reach A2DP
    /// glasses/earbuds. No AVAudioEngine is built,
    /// no tap is installed and no configuration-change observer is registered:
    /// there is no engine whose graph a route change could invalidate. Buffers
    /// arrive through `ingest`.
    func startExternalCapture() async throws {
        guard await requestMicrophonePermission() else {
            logger.error("Microphone permission denied")
            throw HermesAudioError.microphonePermissionDenied
        }

        let session = AVAudioSession.sharedInstance()
        // .allowBluetoothA2DP (not HFP): the glasses' mic is NOT an iOS input
        // here, so nothing wants a hands-free link - but TTS should still be
        // able to land on A2DP glasses/earbuds when a pair is connected.
        try configureAudioSessionCategory(
            session,
            .playAndRecord,
            mode: .default,
            options: [.defaultToSpeaker, .allowBluetoothA2DP]
        )
        // Parity with the phone route's fallback: a preferred input left over
        // from a Bluetooth route would keep pointing the session at a mic this
        // capture does not use.
        try? session.setPreferredInput(nil)
        try session.setActive(true)

        // The incoming format belongs to the kit, not to the last iOS route -
        // drop any converter cached for that route.
        clearConverter()
        tapLock.withLockUnchecked { state in
            state.bufferCount = 0
            state.smoothedLevel = 0
            state.lowInputSince = nil
            state.lowInputRoute = nil
            state.lowInputWarningActive = false
            state.isSpeechActive = false
            state.silenceDuration = 0
            state.speechDetectionSuppressed = false
            state.externalCapture = true
        }
        isCapturing = true

        logger.info("External capture active (buffers arrive via ingest). Output route: \(session.currentRoute.outputs.first?.portName ?? "none", privacy: .public)")
        sendDebug("external capture started")
    }

    /// Feed one buffer into the same pipeline the engine tap uses.
    ///
    /// Called on the provider's audio thread (~50 buffers/s). Everything
    /// downstream is already written for the audio-render thread, so this is
    /// safe from any thread; it must never be called on the main actor's
    /// behalf expecting main-actor isolation.
    func ingest(_ buffer: AVAudioPCMBuffer) {
        guard externalCapture else { return }
        processInputBuffer(buffer)
    }

    /// Replace the engine with a fresh instance, discarding all cached
    /// graph state. The old engine (and its attached player) is released.
    private func rebuildEngine() {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        audioEngine.stop()
        clearConverter()
        audioEngine = AVAudioEngine()
    }

    /// Drop the cached converter so the next tap buffer rebuilds one for the
    /// new route's format.
    private func clearConverter() {
        tapLock.withLockUnchecked { state in
            state.converter = nil
            state.converterInputFormat = nil
        }
    }

    func stopCapture() {
        let wasExternal = externalCapture
        isCapturing = false
        isInterrupted = false
        externalCapture = false
        interruptionRecoveryTask?.cancel()
        interruptionRecoveryTask = nil
        clipPlayer?.stop()
        clipPlayer = nil
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
            interruptionObserver = nil
        }
        // External capture never built an engine or installed a tap.
        // `inputNode` is lazy - touching it here would instantiate the input
        // hardware unit for no reason.
        if !wasExternal {
            inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }
        clearConverter()
        tapLock.withLockUnchecked { state in
            state.smoothedLevel = 0
            state.lowInputSince = nil
            state.lowInputRoute = nil
            state.lowInputWarningActive = false
        }
        deactivateAudioSession()
        let warningHandler = callbackLock.withLockUnchecked { $0.onMicWarning }
        DispatchQueue.main.async { warningHandler?(nil) }
    }

    // MARK: - Playback
    //
    // TTS plays through AVAudioPlayer, NOT the capture engine. AVAudioEngine
    // playback proved unshippable against Bluetooth HFP route flaps: config
    // changes flush scheduled buffers, and AVAudioPlayerNode.play() raises
    // uncatchable NSExceptions when the engine stops under it (three
    // distinct SIGABRTs in the field). AVAudioPlayer owns its rendering,
    // survives route changes, and always calls its delegate on completion.

    func playResponse(_ audioData: Data, sampleRate: Int = 24_000) async {
        guard !audioData.isEmpty else {
            onPlaybackComplete?()
            return
        }

        resetResponseStream()
        let safeSampleRate = (8_000...96_000).contains(sampleRate)
            ? sampleRate : 24_000
        let wav = Self.wavContainer(pcm16: audioData, sampleRate: safeSampleRate)
        do {
            let player = try AVAudioPlayer(data: wav)
            player.delegate = self
            clipPlayer?.stop()
            clipPlayer = player
            logger.info("Playing TTS response: \(audioData.count) bytes (\(String(format: "%.1f", player.duration))s)")
            player.play()
        } catch {
            logger.error("AVAudioPlayer failed: \(error.localizedDescription, privacy: .public)")
            onPlaybackComplete?()
        }
    }

    /// Begin a reliable sentence queue. Clips use AVAudioPlayer (which
    /// survives Bluetooth route changes) while natural TTS boundaries keep
    /// the transitions quiet and let sentence one start before the reply is
    /// fully generated.
    func beginResponseStream() {
        clipPlayer?.stop()
        clipPlayer = nil
        responseClipQueue.removeAll(keepingCapacity: true)
        responseStreamActive = true
        responseStreamOpen = true
        responseStreamReady = false
    }

    func enqueueResponseSegment(_ data: Data, sampleRate: Int = 24_000) {
        guard responseStreamActive, !data.isEmpty else { return }
        let safeSampleRate = (8_000...96_000).contains(sampleRate)
            ? sampleRate : 24_000
        responseClipQueue.append(
            QueuedResponseClip(data: data, sampleRate: safeSampleRate)
        )
        playNextResponseSegmentIfPossible()
    }

    /// Route preparation is asynchronous. Queued sentences remain silent
    /// until Adam confirms the playback-only A2DP attempt has completed.
    func startResponseStreamPlayback() {
        guard responseStreamActive else { return }
        responseStreamReady = true
        playNextResponseSegmentIfPossible()
    }

    func finishResponseStream() {
        guard responseStreamActive else {
            onPlaybackComplete?()
            return
        }
        responseStreamOpen = false
        playNextResponseSegmentIfPossible()
    }

    private func playNextResponseSegmentIfPossible() {
        guard responseStreamActive, responseStreamReady, clipPlayer == nil else {
            return
        }
        guard !responseClipQueue.isEmpty else {
            if !responseStreamOpen {
                completeResponseStream()
            }
            return
        }

        let clip = responseClipQueue.removeFirst()
        let wav = Self.wavContainer(
            pcm16: clip.data, sampleRate: clip.sampleRate
        )
        do {
            let player = try AVAudioPlayer(data: wav)
            player.delegate = self
            clipPlayer = player
            logger.info(
                "Playing streamed TTS segment: \(clip.data.count) bytes (\(String(format: "%.1f", player.duration))s)"
            )
            if !player.play() {
                clipPlayer = nil
                playNextResponseSegmentIfPossible()
            }
        } catch {
            logger.error(
                "Streamed TTS segment failed: \(error.localizedDescription, privacy: .public)"
            )
            clipPlayer = nil
            playNextResponseSegmentIfPossible()
        }
    }

    private func completeResponseStream() {
        guard responseStreamActive else { return }
        resetResponseStream()
        onPlaybackComplete?()
    }

    private func resetResponseStream() {
        responseClipQueue.removeAll(keepingCapacity: true)
        responseStreamActive = false
        responseStreamOpen = false
        responseStreamReady = false
    }

    /// Stop the current TTS clip (barge-in). AVAudioPlayer.stop() does not
    /// call the delegate, so completion is fired here.
    func stopPlayback() {
        let hadPlayback = clipPlayer != nil || responseStreamActive
        clipPlayer?.stop()
        clipPlayer = nil
        resetResponseStream()
        guard hadPlayback else { return }
        logger.info("Playback interrupted")
        DispatchQueue.main.async { [weak self] in
            self?.onPlaybackComplete?()
        }
    }

    /// Wrap raw PCM16 mono samples in a WAV container for AVAudioPlayer
    private static func wavContainer(pcm16: Data, sampleRate: Int) -> Data {
        func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

        var wav = Data()
        wav.append("RIFF".data(using: .ascii)!)
        wav.append(le32(UInt32(36 + pcm16.count)))
        wav.append("WAVE".data(using: .ascii)!)
        wav.append("fmt ".data(using: .ascii)!)
        wav.append(le32(16))                              // fmt chunk size
        wav.append(le16(1))                               // PCM
        wav.append(le16(1))                               // mono
        wav.append(le32(UInt32(sampleRate)))
        wav.append(le32(UInt32(sampleRate * 2)))          // byte rate
        wav.append(le16(2))                               // block align
        wav.append(le16(16))                              // bits/sample
        wav.append("data".data(using: .ascii)!)
        wav.append(le32(UInt32(pcm16.count)))
        wav.append(pcm16)
        return wav
    }

    /// Configure a playback-only audio session so the Sound test works
    /// without a capture session running
    func preparePlaybackOnly() throws {
        let session = AVAudioSession.sharedInstance()
        try configureAudioSessionCategory(session, .playback, mode: .default)
        try session.setActive(true)
    }

    /// Switch from the bidirectional HFP call profile to playback-only audio.
    /// iOS can then select the glasses' A2DP route for full-band TTS.
    func prepareHighQualityPlayback() throws {
        let session = AVAudioSession.sharedInstance()
        try configureAudioSessionCategory(session, .playback, mode: .spokenAudio)
        try session.setActive(true)
    }

    /// 1.5 s 440 Hz sine as PCM16 mono 24 kHz - same format as bridge TTS,
    /// so playing it exercises the exact TTS playback path
    static func makeTestTone(duration: Double = 1.5) -> Data {
        let sampleRate = 24000.0
        let frames = Int(duration * sampleRate)
        var samples = [Int16](repeating: 0, count: frames)
        for i in 0..<frames {
            let t = Double(i) / sampleRate
            // Gentle fade in/out to avoid clicks
            let envelope = min(1.0, min(Double(i), Double(frames - i)) / 1200.0)
            samples[i] = Int16(sin(2.0 * .pi * 440.0 * t) * 12000.0 * envelope)
        }
        return samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    // MARK: - Private

    /// System ducking is the supported way for an iOS app to lower another
    /// app's media. If a route or OS version rejects the option, retain the
    /// voice experience by retrying the same category unchanged.
    private func configureAudioSessionCategory(
        _ session: AVAudioSession,
        _ category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions = []
    ) throws {
        guard mediaDuckingEnabled else {
            try session.setCategory(category, mode: mode, options: options)
            return
        }

        var duckingOptions = options
        duckingOptions.insert(.duckOthers)
        do {
            try session.setCategory(
                category,
                mode: mode,
                options: duckingOptions
            )
        } catch {
            logger.warning(
                "System media ducking unavailable; continuing without it: \(error.localizedDescription, privacy: .public)"
            )
            try session.setCategory(category, mode: mode, options: options)
        }
    }

    /// Let other apps restore their media when Adam releases its audio
    /// session. If notification is unavailable, still deactivate normally.
    private func deactivateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        guard mediaDuckingEnabled else {
            try? session.setActive(false)
            return
        }

        do {
            try session.setActive(
                false,
                options: [.notifyOthersOnDeactivation]
            )
        } catch {
            logger.warning(
                "Media restore notification unavailable; deactivating normally: \(error.localizedDescription, privacy: .public)"
            )
            try? session.setActive(false)
        }
    }

    private func requestMicrophonePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await AVAudioApplication.requestRecordPermission()
        @unknown default:
            return false
        }
    }

    /// A route change (e.g. iOS moving input to Bluetooth) stops the engine
    /// and invalidates the tap. Reinstall and restart so capture survives.
    private func observeConfigurationChanges() {
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isCapturing, !self.isInterrupted else { return }
            self.logger.info("Engine configuration changed - reinstalling tap. Route: \(self.currentInputName, privacy: .public)")
            self.inputNode.removeTap(onBus: 0)
            self.installTap()
            if !self.audioEngine.isRunning {
                do {
                    try self.audioEngine.start()
                } catch {
                    self.logger.error("Failed to restart engine: \(error.localizedDescription, privacy: .public)")
                }
            }

            self.onRouteChanged?()
        }
    }

    /// Calls, Siri, alarms, and other system audio can stop the input unit
    /// without producing an engine-configuration notification. Re-negotiate
    /// the requested route and rebuild the whole graph when the interruption
    /// ends so wake-word recognition does not remain silently dead.
    private func observeAudioInterruptions() {
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
        }

        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let interruptionType = AVAudioSession.InterruptionType(rawValue: rawType)
            else { return }

            switch interruptionType {
            case .began:
                guard self.isCapturing else { return }
                self.isInterrupted = true
                self.interruptionRecoveryTask?.cancel()
                self.interruptionRecoveryTask = nil
                if let observer = self.configChangeObserver {
                    NotificationCenter.default.removeObserver(observer)
                    self.configChangeObserver = nil
                }
                self.audioEngine.pause()
                self.logger.info("Audio capture interrupted")
                self.sendDebug("audio interrupted; waiting to resume")

            case .ended:
                guard self.isCapturing else { return }
                self.isInterrupted = false
                self.interruptionRecoveryTask?.cancel()
                let route = self.requestedCaptureRoute
                self.interruptionRecoveryTask = Task { [weak self] in
                    guard let self else { return }
                    let retryDelays: [UInt64] = [300_000_000, 1_000_000_000, 2_000_000_000]

                    for (attempt, delay) in retryDelays.enumerated() {
                        do {
                            try await Task.sleep(nanoseconds: delay)
                            try Task.checkCancellation()
                            guard self.isCapturing, !self.isInterrupted else { return }

                            _ = try await self.startCapture(route: route)
                            try Task.checkCancellation()
                            guard self.isCapturing, !self.isInterrupted else { return }

                            if route == .phoneMic || self.requestedRouteIsActive(route) {
                                self.interruptionRecoveryTask = nil
                                self.logger.info("Requested audio route recovered after interruption")
                                self.sendDebug("requested audio route recovered")
                                self.onRouteChanged?()
                                return
                            }

                            // startCapture deliberately leaves the iPhone mic
                            // live when HFP is absent. Give the requested route
                            // two more chances, then keep that working fallback
                            // and report it honestly through onRouteChanged.
                            if attempt == retryDelays.indices.last {
                                self.interruptionRecoveryTask = nil
                                self.logger.warning("Requested Bluetooth route did not recover; continuing on iPhone microphone")
                                self.sendDebug("Bluetooth route unavailable after interruption; using iPhone mic")
                                self.onRouteChanged?()
                                return
                            }
                        } catch is CancellationError {
                            return
                        } catch {
                            self.logger.warning("Audio interruption recovery attempt \(attempt + 1, privacy: .public) failed: \(String(describing: type(of: error)), privacy: .public)")
                        }
                    }

                    self.logger.error("Audio capture did not recover after interruption")
                    let failure = "Audio was interrupted and could not restart. Start Adam again."
                    let handler = self.onCaptureRecoveryFailed
                    self.interruptionRecoveryTask = nil
                    self.stopCapture()
                    self.sendDebug("audio recovery failed; capture stopped")
                    handler?(failure)
                }

            @unknown default:
                break
            }
        }
    }

    private func requestedRouteIsActive(_ route: CaptureRoute) -> Bool {
        switch route {
        case .glassesMic:
            return isUsingGlassesInput
        case .headsetMic:
            return isUsingBluetoothInput && !isUsingGlassesInput
        case .phoneMic:
            return !isUsingBluetoothInput
        }
    }

    private func installTap() {
        let inputFormat = inputNode.outputFormat(forBus: 0)
        logger.info("Installing tap. Input format: \(inputFormat.sampleRate, privacy: .public) Hz, \(inputFormat.channelCount, privacy: .public) ch")

        let session = AVAudioSession.sharedInstance()
        let inputs = session.currentRoute.inputs
            .map { "\($0.portName) (\($0.portType.rawValue))" }
            .joined(separator: ", ")
        sendDebug("tap installed: route=[\(inputs)] format=\(inputFormat.sampleRate)Hz/\(inputFormat.channelCount)ch gain=\(session.inputGain)")

        // format: nil - the tap follows the node's live format. Passing an
        // explicit format raises NSException (SIGABRT) when the cached
        // format mismatches the hardware mid-route-change (e.g. switching
        // to Bluetooth HFP). The converter is built lazily per buffer
        // format instead.
        inputNode.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: nil
        ) { [weak self] buffer, _ in
            self?.processInputBuffer(buffer)
        }
    }

    private func processInputBuffer(_ buffer: AVAudioPCMBuffer) {
        // Audio-render thread. Every critical section below is a handful of
        // stores; the conversion, the callbacks and the logging all happen
        // with no lock held.
        let now = Date().timeIntervalSince1970
        let entry = tapLock.withLockUnchecked { state -> (converter: AVAudioConverter?, count: Int, level: Bool, debug: Bool) in
            state.bufferCount += 1
            let level = now - state.lastLevelTime > 0.25
            if level { state.lastLevelTime = now }
            let debug = now - state.lastDebugTime > 1.0
            if debug { state.lastDebugTime = now }
            let reusable = state.converterInputFormat == buffer.format
            return (reusable ? state.converter : nil, state.bufferCount, level, debug)
        }
        let adamSettings = adamAudioSettingsLock.withLockUnchecked { $0 }
        let conditioningEnabled = adamSettings.recognitionConditioningEnabled

        // (Re)build the converter whenever the incoming format changes -
        // route switches change the sample rate under our feet. Building one
        // allocates, so it happens outside the critical section. A buffer
        // that already IS the capture format skips the converter entirely.
        let passthrough = isPassthrough(buffer.format)
        var converter = entry.converter
        if !passthrough, converter == nil {
            converter = AVAudioConverter(from: buffer.format, to: captureFormat)
            let format = buffer.format
            tapLock.withLockUnchecked { state in
                state.converter = converter
                state.converterInputFormat = format
            }
        }
        if !passthrough, converter == nil { return }

        let count = entry.count
        if count == 1 || count % 100 == 0 {
            logger.info("Tap delivered buffer #\(count, privacy: .public) (\(buffer.frameLength, privacy: .public) frames)")
        }

        // One snapshot per buffer: the set of callbacks cannot change under
        // the rest of this function.
        let callbacks = callbackLock.withLockUnchecked { $0 }

        // Adam opts into a fresh conditioned copy. The original Hermes target
        // leaves this disabled, so it continues to receive the exact source
        // buffer and all bridge/recording paths remain untouched.
        callbacks.onRawBuffer?(
            conditioningEnabled ? conditionedRecognitionBuffer(buffer) : buffer
        )

        if entry.level {
            let rawLevel = rawFloatRMS(buffer)
            let smoothedLevel: Float
            if conditioningEnabled {
                smoothedLevel = tapLock.withLockUnchecked { state in
                    let next = AdamSpeechSignal.smoothedMeterLevel(
                        previous: state.smoothedLevel,
                        rms: rawLevel
                    )
                    state.smoothedLevel = next
                    return next
                }
            } else {
                // Preserve the original Hermes meter contract unless Adam
                // explicitly opts into the dBFS presentation.
                smoothedLevel = max(0, rawLevel)
            }
            if let onLevel = callbacks.onLevel {
                DispatchQueue.main.async { onLevel(smoothedLevel) }
            }

            if conditioningEnabled {
                let warning = updateLowInputWarning(rawRMS: rawLevel, now: now)
                if warning.changed {
                    let warningHandler = callbacks.onMicWarning
                    DispatchQueue.main.async { warningHandler?(warning.message) }
                }
            }
        }

        let outputBuffer: AVAudioPCMBuffer?
        if passthrough {
            outputBuffer = buffer
        } else if let converter {
            outputBuffer = convertBuffer(buffer, using: converter)
        } else {
            outputBuffer = nil
        }
        guard let outputBuffer else { return }

        guard let channelData = outputBuffer.int16ChannelData else { return }
        let frameLength = Int(outputBuffer.frameLength)
        guard frameLength > 0 else { return }
        let sourceData = Data(
            bytes: channelData[0],
            count: frameLength * MemoryLayout<Int16>.size
        )

        // Straight to the recorder, on this thread, before any VAD gate: a
        // recording of a conversation must contain the quiet half of it.
        // Invoked under its own lock - see `onRecordChunk`.
        recordChunkLock.withLockUnchecked { handler in handler?(sourceData) }

        let rms = computeRMS(channelData[0], frameLength: frameLength)
        let (isVoice, wasSpeechActive, transition) = tapLock.withLockUnchecked {
            state -> (Bool, Bool, VADTransition) in
            guard !state.speechDetectionSuppressed else {
                state.isSpeechActive = false
                state.silenceDuration = 0
                return (false, false, .none)
            }
            let wasSpeechActive = state.isSpeechActive
            let threshold = AdamSpeechSignal.adaptiveSpeechThreshold(
                noiseRMS: state.ambientNoiseRMS
            )
            let isVoice = rms > threshold

            // Learn the local noise floor only while speech is inactive and
            // the current buffer is near it. A slow EMA follows changing room
            // ambience without teaching speech itself as the new baseline.
            if !wasSpeechActive, rms < threshold * 1.35 {
                state.ambientNoiseRMS = (
                    state.ambientNoiseRMS * 0.96 + max(0, rms) * 0.04
                )
            }
            if isVoice {
                state.silenceDuration = 0
                guard !wasSpeechActive else {
                    return (isVoice, wasSpeechActive, .none)
                }
                state.isSpeechActive = true
                return (isVoice, wasSpeechActive, .speechStarted)
            }
            guard wasSpeechActive else {
                return (isVoice, wasSpeechActive, .none)
            }
            state.silenceDuration += Double(frameLength) / captureFormat.sampleRate
            guard state.silenceDuration >= silenceDuration else {
                return (isVoice, wasSpeechActive, .none)
            }
            state.isSpeechActive = false
            state.silenceDuration = 0
            return (isVoice, wasSpeechActive, .silenceStarted)
        }

        let bridgeData = adamSettings.bridgeConditioningEnabled
            ? conditionedBridgePCM16(sourceData, rms: rms)
            : sourceData

        // Periodic level diagnostics: raw float level straight off the mic
        // vs. level after conversion, plus the active input route
        if entry.debug {
            let raw = rawFloatRMS(buffer)
            let route = AVAudioSession.sharedInstance()
                .currentRoute.inputs.first?.portName ?? "none"
            sendDebug(String(
                format: "levels raw=%.4f converted=%.4f route=%@ frames=%d",
                raw, rms, route, buffer.frameLength
            ), to: callbacks.onDebug)
        }

        // Send audio whenever VAD is disabled or speech is in progress (the
        // gate reads the state as it was BEFORE this buffer advanced it).
        // The bridge's legacy audio path has no app-side consumer today, so
        // skip the hop to main entirely when nobody is listening - at ~47
        // buffers a second an empty dispatch is pure overhead.
        if let onAudioChunk = callbacks.onAudioChunk,
           vadDisabled || isVoice || wasSpeechActive {
            DispatchQueue.main.async { onAudioChunk(bridgeData) }
        }

        switch transition {
        case .none:
            break
        case .speechStarted:
            if let onSpeechDetected = callbacks.onSpeechDetected {
                DispatchQueue.main.async { onSpeechDetected() }
            }
        case .silenceStarted:
            if let onSilenceDetected = callbacks.onSilenceDetected {
                DispatchQueue.main.async { onSilenceDetected() }
            }
        }
    }

    // MARK: - Adam recognition conditioning

    private func conditionedBridgePCM16(_ data: Data, rms: Float) -> Data {
        guard !data.isEmpty else { return data }
        var samples = data.withUnsafeBytes { raw -> [Int16] in
            guard let base = raw.bindMemory(to: Int16.self).baseAddress else {
                return []
            }
            return Array(UnsafeBufferPointer(
                start: base, count: raw.count / MemoryLayout<Int16>.size
            ))
        }
        guard !samples.isEmpty else { return data }
        var configuration = AdamSpeechSignal.Configuration.default
        configuration.gain = AdamSpeechSignal.adaptiveGain(rms: rms)
        AdamSpeechSignal.processInt16Samples(
            &samples, configuration: configuration
        )
        return samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Return a conditioned copy for Adam's speech recognizer. The source
    /// buffer is never modified: the same source continues through the
    /// recorder and converted bridge-audio paths below. Any unsupported or
    /// malformed layout falls back to the original buffer so recognition can
    /// continue rather than dropping a capture frame.
    private func conditionedRecognitionBuffer(
        _ buffer: AVAudioPCMBuffer
    ) -> AVAudioPCMBuffer {
        guard let copy = copyPCMBuffer(buffer), conditionPCMBuffer(copy) else {
            return buffer
        }
        return copy
    }

    private func copyPCMBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0, frameLength <= Int(buffer.frameCapacity),
              let copy = AVAudioPCMBuffer(
                  pcmFormat: buffer.format,
                  frameCapacity: buffer.frameLength
              ) else {
            return nil
        }

        copy.frameLength = buffer.frameLength
        // CoreAudio only exposes the mutable collection wrapper on iOS. We
        // cast the list pointer solely to iterate and copy its bytes; the
        // source buffer itself is never mutated.
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: buffer.audioBufferList)
        )
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(
            copy.mutableAudioBufferList
        )
        guard sourceBuffers.count == destinationBuffers.count else { return nil }

        for (source, destination) in zip(sourceBuffers, destinationBuffers) {
            let byteCount = Int(source.mDataByteSize)
            guard byteCount <= Int(destination.mDataByteSize) else { return nil }
            guard byteCount == 0 || (source.mData != nil && destination.mData != nil) else {
                return nil
            }
            if byteCount > 0 {
                memcpy(destination.mData, source.mData, byteCount)
            }
        }
        return copy
    }

    private func conditionPCMBuffer(_ buffer: AVAudioPCMBuffer) -> Bool {
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameLength > 0, channelCount > 0 else { return false }

        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            return conditionFloatPCMBuffer(
                buffer,
                frameLength: frameLength,
                channelCount: channelCount
            )
        case .pcmFormatInt16:
            return conditionInt16PCMBuffer(
                buffer,
                frameLength: frameLength,
                channelCount: channelCount
            )
        default:
            return false
        }
    }

    private func conditionFloatPCMBuffer(
        _ buffer: AVAudioPCMBuffer,
        frameLength: Int,
        channelCount: Int
    ) -> Bool {
        let audioBuffers = UnsafeMutableAudioBufferListPointer(
            buffer.mutableAudioBufferList
        )
        let bytesPerSample = MemoryLayout<Float>.size
        let configuration = AdamSpeechSignal.Configuration.default

        if buffer.format.isInterleaved {
            let expectedSamples = frameLength * channelCount
            guard audioBuffers.count == 1,
                  Int(audioBuffers[0].mDataByteSize) >= expectedSamples * bytesPerSample,
                  let data = audioBuffers[0].mData else { return false }
            let samples = data.assumingMemoryBound(to: Float.self)
            for index in 0..<expectedSamples {
                samples[index] = AdamSpeechSignal.processSample(
                    samples[index],
                    configuration: configuration
                )
            }
            return true
        }

        guard audioBuffers.count == channelCount else { return false }
        for index in 0..<channelCount {
            let audioBuffer = audioBuffers[index]
            guard Int(audioBuffer.mDataByteSize) >= frameLength * bytesPerSample,
                  let data = audioBuffer.mData else { return false }
            let samples = data.assumingMemoryBound(to: Float.self)
            for frame in 0..<frameLength {
                samples[frame] = AdamSpeechSignal.processSample(
                    samples[frame],
                    configuration: configuration
                )
            }
        }
        return true
    }

    private func conditionInt16PCMBuffer(
        _ buffer: AVAudioPCMBuffer,
        frameLength: Int,
        channelCount: Int
    ) -> Bool {
        let audioBuffers = UnsafeMutableAudioBufferListPointer(
            buffer.mutableAudioBufferList
        )
        let bytesPerSample = MemoryLayout<Int16>.size
        let configuration = AdamSpeechSignal.Configuration.default

        if buffer.format.isInterleaved {
            let expectedSamples = frameLength * channelCount
            guard audioBuffers.count == 1,
                  Int(audioBuffers[0].mDataByteSize) >= expectedSamples * bytesPerSample,
                  let data = audioBuffers[0].mData else { return false }
            let samples = data.assumingMemoryBound(to: Int16.self)
            for index in 0..<expectedSamples {
                samples[index] = AdamSpeechSignal.processInt16Sample(
                    samples[index],
                    configuration: configuration
                )
            }
            return true
        }

        guard audioBuffers.count == channelCount else { return false }
        for index in 0..<channelCount {
            let audioBuffer = audioBuffers[index]
            guard Int(audioBuffer.mDataByteSize) >= frameLength * bytesPerSample,
                  let data = audioBuffer.mData else { return false }
            let samples = data.assumingMemoryBound(to: Int16.self)
            for frame in 0..<frameLength {
                samples[frame] = AdamSpeechSignal.processInt16Sample(
                    samples[frame],
                    configuration: configuration
                )
            }
        }
        return true
    }

    private struct LowInputWarningUpdate {
        var changed = false
        var message: String?
    }

    /// Keep low-input state per active route. A route change clears a stale
    /// warning immediately; a new warning appears only after several seconds
    /// of genuinely quiet input.
    private func updateLowInputWarning(
        rawRMS: Float,
        now: TimeInterval
    ) -> LowInputWarningUpdate {
        let route = micWarningRoute()
        return tapLock.withLockUnchecked { state in
            if state.lowInputRoute != route.key {
                let wasActive = state.lowInputWarningActive
                state.lowInputRoute = route.key
                state.lowInputSince = nil
                state.lowInputWarningActive = false
                return LowInputWarningUpdate(
                    changed: wasActive,
                    message: nil
                )
            }

            guard rawRMS.isFinite, rawRMS >= 0 else {
                return LowInputWarningUpdate()
            }

            if rawRMS >= lowInputThreshold || rawRMS < lowInputActivityFloor {
                let wasActive = state.lowInputWarningActive
                state.lowInputSince = nil
                state.lowInputWarningActive = false
                return LowInputWarningUpdate(
                    changed: wasActive,
                    message: nil
                )
            }

            if state.lowInputSince == nil {
                state.lowInputSince = now
                return LowInputWarningUpdate()
            }

            guard !state.lowInputWarningActive,
                  let quietSince = state.lowInputSince,
                  now - quietSince >= lowInputWarningDelay else {
                return LowInputWarningUpdate()
            }

            state.lowInputWarningActive = true
            return LowInputWarningUpdate(changed: true, message: route.message)
        }
    }

    private func micWarningRoute() -> (key: String, message: String) {
        let input = AVAudioSession.sharedInstance().currentRoute.inputs.first
        guard let input else {
            return (
                "none",
                "Microphone input is unavailable. Check the Ray-Ban Bluetooth connection."
            )
        }

        let name = input.portName.trimmingCharacters(in: .whitespacesAndNewlines)
        let isBluetooth = input.portType == .bluetoothHFP || input.portType == .bluetoothA2DP
        if isBluetooth && Self.looksLikeGlasses(input) {
            return (
                "glasses:\(name)",
                "Ray-Ban microphone input is very quiet. Move closer to the glasses or switch to the iPhone microphone."
            )
        }
        if isBluetooth {
            return (
                "bluetooth:\(name)",
                "Bluetooth microphone input is very quiet. Check the headset connection or switch to the iPhone microphone."
            )
        }
        return (
            "phone:\(name)",
            "iPhone microphone input is very quiet. Move closer and speak toward the phone."
        )
    }

    private func applyMaximumInputGainIfPossible() {
        guard maximumInputGainEnabled else { return }
        let session = AVAudioSession.sharedInstance()
        guard session.isInputGainSettable else {
            logger.info("Input gain is not settable on the active route")
            return
        }
        do {
            try session.setInputGain(1.0)
            sendDebug("maximum input gain requested")
        } catch {
            logger.info("Maximum input gain unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    private enum VADTransition {
        case none
        case speechStarted
        case silenceStarted
    }

    /// True when `buffer`'s format can go downstream untouched.
    ///
    /// Everything after conversion reads `int16ChannelData[0]` and
    /// `frameLength`, and for a MONO Int16 buffer that is the same memory
    /// whether the format calls itself interleaved or not - so an exact
    /// format match is not required, only Int16 / same rate / one channel.
    /// That matters for the AiSee kit, whose sink emits 16 kHz Int16 mono
    /// marked `interleaved: true` while `captureFormat` is the same thing
    /// marked non-interleaved: without this the hot path (~50 buffers/s)
    /// would run an AVAudioConverter that does nothing.
    private func isPassthrough(_ format: AVAudioFormat) -> Bool {
        if format == captureFormat { return true }
        return format.commonFormat == captureFormat.commonFormat
            && format.sampleRate == captureFormat.sampleRate
            && format.channelCount == 1
            && captureFormat.channelCount == 1
    }

    private func convertBuffer(
        _ buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter
    ) -> AVAudioPCMBuffer? {
        let frameCapacity = AVAudioFrameCount(
            (Double(buffer.frameLength)
            * (captureFormat.sampleRate / buffer.format.sampleRate))
            .rounded(.up)
        )

        guard frameCapacity > 0, let output = AVAudioPCMBuffer(
            pcmFormat: captureFormat,
            frameCapacity: frameCapacity
        ) else { return nil }

        // Hand the input buffer to the converter exactly once per call;
        // returning it repeatedly makes the converter re-consume stale data.
        var consumed = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        var error: NSError?
        converter.convert(to: output, error: &error, withInputFrom: inputBlock)
        return error == nil ? output : nil
    }

    /// `to:` lets the tap reuse the handler it already snapshotted rather
    /// than re-reading it; callers off the audio thread pass nothing.
    private func sendDebug(_ message: String, to handler: ((String) -> Void)? = nil) {
        logger.info("\(message, privacy: .public)")
        guard let handler = handler ?? onDebug else { return }
        DispatchQueue.main.async { handler(message) }
    }

    /// RMS of the untouched buffer straight off the input, before conversion.
    ///
    /// Engine taps commonly hand over non-interleaved Float32 while external
    /// kits and some HFP routes hand over interleaved or non-interleaved Int16.
    /// Walk the audio-buffer-list layout explicitly so neither format reports
    /// a permanently dead meter.
    private func rawFloatRMS(_ buffer: AVAudioPCMBuffer) -> Float {
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameLength > 0, channelCount > 0 else { return -1 }

        // CoreAudio's iOS SDK does not provide UnsafeAudioBufferListPointer.
        // Use its mutable wrapper for read-only iteration over this list.
        let audioBuffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: buffer.audioBufferList)
        )
        var sum: Float = 0
        var sampleCount = 0

        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            if buffer.format.isInterleaved {
                let expectedSamples = frameLength * channelCount
                guard audioBuffers.count == 1,
                      Int(audioBuffers[0].mDataByteSize)
                          >= expectedSamples * MemoryLayout<Float>.size,
                      let data = audioBuffers[0].mData else { return -1 }
                let samples = data.assumingMemoryBound(to: Float.self)
                for index in 0..<expectedSamples {
                    let sample = samples[index]
                    guard sample.isFinite else { continue }
                    sum += sample * sample
                    sampleCount += 1
                }
            } else {
                guard audioBuffers.count == channelCount else { return -1 }
                for channel in 0..<channelCount {
                    let audioBuffer = audioBuffers[channel]
                    guard Int(audioBuffer.mDataByteSize)
                              >= frameLength * MemoryLayout<Float>.size,
                          let data = audioBuffer.mData else { return -1 }
                    let samples = data.assumingMemoryBound(to: Float.self)
                    for frame in 0..<frameLength {
                        let sample = samples[frame]
                        guard sample.isFinite else { continue }
                        sum += sample * sample
                        sampleCount += 1
                    }
                }
            }

        case .pcmFormatInt16:
            if buffer.format.isInterleaved {
                let expectedSamples = frameLength * channelCount
                guard audioBuffers.count == 1,
                      Int(audioBuffers[0].mDataByteSize)
                          >= expectedSamples * MemoryLayout<Int16>.size,
                      let data = audioBuffers[0].mData else { return -1 }
                let samples = data.assumingMemoryBound(to: Int16.self)
                for index in 0..<expectedSamples {
                    let sample = Float(samples[index]) / 32768
                    sum += sample * sample
                    sampleCount += 1
                }
            } else {
                guard audioBuffers.count == channelCount else { return -1 }
                for channel in 0..<channelCount {
                    let audioBuffer = audioBuffers[channel]
                    guard Int(audioBuffer.mDataByteSize)
                              >= frameLength * MemoryLayout<Int16>.size,
                          let data = audioBuffer.mData else { return -1 }
                    let samples = data.assumingMemoryBound(to: Int16.self)
                    for frame in 0..<frameLength {
                        let sample = Float(samples[frame]) / 32768
                        sum += sample * sample
                        sampleCount += 1
                    }
                }
            }

        default:
            return -1
        }

        guard sampleCount > 0 else { return -1 }
        return sqrt(sum / Float(sampleCount))
    }

    private func computeRMS(_ samples: UnsafePointer<Int16>, frameLength: Int) -> Float {
        var sum: Float = 0
        for i in 0..<frameLength {
            let sample = Float(samples[i]) / 32768.0
            sum += sample * sample
        }
        return sqrt(sum / Float(frameLength))
    }

}

// MARK: - AVAudioPlayerDelegate

extension HermesAudioManager: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.logger.info("TTS playback finished (success=\(flag))")
            self.clipPlayer = nil
            if self.responseStreamActive {
                self.playNextResponseSegmentIfPossible()
            } else {
                self.onPlaybackComplete?()
            }
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.logger.error("TTS decode error: \(error?.localizedDescription ?? "?", privacy: .public)")
            self.clipPlayer = nil
            if self.responseStreamActive {
                self.playNextResponseSegmentIfPossible()
            } else {
                self.onPlaybackComplete?()
            }
        }
    }
}

enum HermesAudioError: LocalizedError {
    case converterFailed
    case microphonePermissionDenied

    var errorDescription: String? {
        switch self {
        case .converterFailed:
            return "Audio converter could not be created."
        case .microphonePermissionDenied:
            return "Microphone access denied. Enable it in Settings → Privacy & Security → Microphone → Hermes Glasses."
        }
    }
}
