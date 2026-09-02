//
// AdamSoundscapeManager.swift
//
// Independent listening feedback for AdamVoice.  AVAudioPlayer instances in
// this class never share HermesAudioManager's TTS player and never reconfigure
// the shared AVAudioSession; they follow the route already selected by the
// capture/session owner.
//

import AVFoundation
import Foundation
import os

/// Runtime tuning for Adam's generated listening cues.
struct AdamSoundscapeConfiguration: Equatable, Sendable {
    /// Generated cues are already quiet; these player-level values leave
    /// headroom for HFP output and keep cues below speech volume.
    var ambienceVolume: Float = 0.78
    var matchedCueVolume: Float = 0.80
    var speechStartCueVolume: Float = 0.45
    var thinkingPulseVolume: Float = 0.55
    var fadeOutDuration: TimeInterval = 0.16

    static let `default` = AdamSoundscapeConfiguration()

    var normalized: AdamSoundscapeConfiguration {
        var copy = self
        copy.ambienceVolume = Self.volume(copy.ambienceVolume)
        copy.matchedCueVolume = Self.volume(copy.matchedCueVolume)
        copy.speechStartCueVolume = Self.volume(copy.speechStartCueVolume)
        copy.thinkingPulseVolume = Self.volume(copy.thinkingPulseVolume)
        copy.fadeOutDuration = copy.fadeOutDuration.isFinite
            ? min(2, max(0, copy.fadeOutDuration))
            : AdamSoundscapeConfiguration.default.fadeOutDuration
        return copy
    }

    private static func volume(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }
}

/// Plays Adam's local listening cues while leaving HermesAudioManager and its
/// response/TTS player untouched.
@MainActor
final class AdamSoundscapeManager: NSObject {
    private enum ListeningMode: Equatable {
        case loop
        case risingCue
    }

    private let logger = Logger(
        subsystem: "com.flowsxr.hermesglasses",
        category: "adam-soundscape"
    )

    private let configuration: AdamSoundscapeConfiguration
    private let fluteLoopData: Data
    private let risingCueData: Data
    private let fallingCueData: Data
    private let readyCueData: Data
    private let speechStartCueData: Data
    private let thinkingPulseData: Data

    private var ambiencePlayer: AVAudioPlayer?
    private var completionCuePlayer: AVAudioPlayer?
    private var signalPlayer: AVAudioPlayer?
    private var ambienceFadeTask: Task<Void, Never>?
    private var pendingCompletionCueTask: Task<Void, Never>?
    private var thinkingPulseTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var pulseGeneration: UInt64 = 0
    private var listeningMode: ListeningMode?

    /// True from `startListening` until `finishListening` or
    /// `stopImmediately`, including the short period after a rising cue has
    /// naturally finished while speech recognition is starting.
    private(set) var isListening = false

    /// True only for the Bluetooth/HFP ambience-loop mode.
    var isLooping: Bool { listeningMode == .loop }

    /// Whether the end cue is currently rendering.
    var isPlayingCompletionCue: Bool { completionCuePlayer?.isPlaying == true }

    init(
        configuration: AdamSoundscapeConfiguration = .default,
        sampleRate: Int = AdamSoundscapeWaveform.defaultSampleRate
    ) {
        self.configuration = configuration.normalized
        self.fluteLoopData = AdamSoundscapeWaveform.fluteLoop(sampleRate: sampleRate).wavData
        self.risingCueData = AdamSoundscapeWaveform.matchedCue(
            for: .listeningStart,
            sampleRate: sampleRate
        ).wavData
        self.fallingCueData = AdamSoundscapeWaveform.matchedCue(
            for: .listeningEnd,
            sampleRate: sampleRate
        ).wavData
        self.readyCueData = AdamSoundscapeWaveform.matchedCue(
            for: .responseReady,
            sampleRate: sampleRate
        ).wavData
        self.speechStartCueData = AdamSoundscapeWaveform.speechStartCue(sampleRate: sampleRate).wavData
        self.thinkingPulseData = AdamSoundscapeWaveform.thinkingPulse(sampleRate: sampleRate).wavData
        super.init()
    }

    deinit {
        ambienceFadeTask?.cancel()
        pendingCompletionCueTask?.cancel()
        thinkingPulseTask?.cancel()
        ambiencePlayer?.stop()
        completionCuePlayer?.stop()
        signalPlayer?.stop()
    }

    /// Begin a listening cue.
    ///
    /// Bluetooth HFP callers pass `loop: true` to keep the low ambience bed
    /// active while the recognizer accepts speech. Phone-mic fallback callers
    /// pass `loop: false`; that mode plays only the brief rising cue so the
    /// generated sound does not get fed back into the phone microphone.
    /// Repeating the same call while active is idempotent.
    func startListening(loop: Bool) {
        let requestedMode: ListeningMode = loop ? .loop : .risingCue
        if isListening, listeningMode == requestedMode {
            return
        }

        // A new listening period owns the route and must not leave an earlier
        // completion cue or fade task rendering under speech.
        cancelPendingAudio()
        stopAmbienceImmediately()
        stopThinkingPulse()

        generation &+= 1
        isListening = true
        listeningMode = requestedMode

        let data = loop ? fluteLoopData : risingCueData
        let volume = loop
            ? configuration.ambienceVolume
            : configuration.matchedCueVolume
        guard let player = makePlayer(data: data, volume: volume) else {
            logger.error("Unable to create Adam listening cue player")
            isListening = false
            listeningMode = nil
            return
        }

        player.numberOfLoops = loop ? -1 : 0
        ambiencePlayer = player
        player.prepareToPlay()
        guard player.play() else {
            logger.error("Unable to start Adam listening cue player")
            ambiencePlayer = nil
            isListening = false
            listeningMode = nil
            return
        }
    }

    /// Finish the current listening period. Ambience fades out first; the
    /// completion cue is scheduled after that fade so cues never overlap. Calling
    /// this more than once for one period is a no-op, guaranteeing one end
    /// completion cue at most.
    func finishListening(playCompletionCue: Bool = true) {
        guard isListening else { return }

        isListening = false
        listeningMode = nil
        generation &+= 1
        let fadeDuration = fadeAndStopAmbience()
        guard playCompletionCue else { return }

        pendingCompletionCueTask?.cancel()
        let token = generation
        pendingCompletionCueTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if fadeDuration > 0 {
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64(fadeDuration * 1_000_000_000)
                    )
                } catch {
                    return
                }
            }
            guard !Task.isCancelled, self.generation == token else { return }
            self.pendingCompletionCueTask = nil
            self.playCompletionCue()
        }
    }

    /// Play the completion cue for a command that arrived in the same final
    /// transcript as its wake word. There was no open listening period to
    /// finish in that case, but the wearer should still receive the same
    /// recognized-command feedback.
    func playCompletionCue() {
        generation &+= 1
        isListening = false
        listeningMode = nil
        cancelPendingAudio()
        stopThinkingPulse()
        stopAmbienceImmediately()
        playFallingCue()
    }

    /// Play the conversational handoff cue after capture has been restored.
    /// The session owns exactly-once and self-capture guards; this manager
    /// keeps the cue in the same player/family as the listening edge pair.
    func playReadyCue() {
        generation &+= 1
        isListening = false
        listeningMode = nil
        cancelPendingAudio()
        stopThinkingPulse()
        stopAmbienceImmediately()
        playMatchedCue(data: readyCueData, description: "ready")
    }

    /// Mark the instant command speech is detected. This is independent of
    /// the rising listening cue so it cannot delay or replace that cue.
    func playSpeechStartCue() {
        playSignal(
            data: speechStartCueData,
            volume: configuration.speechStartCueVolume
        )
    }

    /// Start the delayed repeating thinking cue. Each scheduled loop owns a
    /// generation token, so a late sleep cannot render after cancellation or a
    /// newer turn has begun.
    func scheduleThinkingPulse(
        startAfter: TimeInterval = 0.9,
        repeatEvery: TimeInterval = 2.8
    ) {
        stopThinkingPulse()
        pulseGeneration &+= 1
        let token = pulseGeneration
        let delay = max(0, startAfter)
        let interval = max(0.1, repeatEvery)
        thinkingPulseTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                while !Task.isCancelled {
                    guard let self, self.pulseGeneration == token else { return }
                    self.playSignal(
                        data: self.thinkingPulseData,
                        volume: self.configuration.thinkingPulseVolume
                    )
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                }
            } catch {
                return
            }
        }
    }

    func stopThinkingPulse() {
        pulseGeneration &+= 1
        thinkingPulseTask?.cancel()
        thinkingPulseTask = nil
        signalPlayer?.stop()
        signalPlayer = nil
    }

    /// Stop all sound immediately, including any queued fade/completion cue. This is
    /// used before processing or TTS and intentionally emits no end cue.
    func stopImmediately() {
        generation &+= 1
        isListening = false
        listeningMode = nil
        cancelPendingAudio()
        stopAmbienceImmediately()
        stopThinkingPulse()
        completionCuePlayer?.stop()
        completionCuePlayer = nil
    }

    // MARK: - Private lifecycle

    private func makePlayer(data: Data, volume: Float) -> AVAudioPlayer? {
        do {
            let player = try AVAudioPlayer(data: data)
            player.volume = volume
            return player
        } catch {
            logger.error("Adam cue decode failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func playFallingCue() {
        // There should be no overlap even if a caller begins a new end cue
        // after a route/session reset. The listening-period guard is what
        // prevents normal duplicate `finishListening` calls.
        playMatchedCue(data: fallingCueData, description: "completion")
    }

    private func playMatchedCue(data: Data, description: String) {
        completionCuePlayer?.stop()
        completionCuePlayer = nil
        guard let player = makePlayer(
            data: data,
            volume: configuration.matchedCueVolume
        ) else {
            logger.error("Unable to create Adam \(description, privacy: .public) cue player")
            return
        }
        completionCuePlayer = player
        player.prepareToPlay()
        guard player.play() else {
            completionCuePlayer = nil
            logger.error("Unable to start Adam \(description, privacy: .public) cue player")
            return
        }
    }

    private func playSignal(data: Data, volume: Float) {
        signalPlayer?.stop()
        signalPlayer = nil
        guard let player = makePlayer(data: data, volume: volume) else {
            logger.error("Unable to create Adam signal player")
            return
        }
        signalPlayer = player
        player.prepareToPlay()
        guard player.play() else {
            signalPlayer = nil
            logger.error("Unable to start Adam signal player")
            return
        }
    }

    /// Fade the active ambience player and return the delay before another
    /// cue may safely begin. A non-playing rising cue is stopped immediately.
    @discardableResult
    private func fadeAndStopAmbience() -> TimeInterval {
        ambienceFadeTask?.cancel()
        ambienceFadeTask = nil
        guard let player = ambiencePlayer else { return 0 }

        guard player.isPlaying, configuration.fadeOutDuration > 0 else {
            player.stop()
            ambiencePlayer = nil
            return 0
        }

        let duration = configuration.fadeOutDuration
        player.setVolume(0, fadeDuration: duration)
        let token = generation
        ambienceFadeTask = Task { @MainActor [weak self, weak player] in
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(duration * 1_000_000_000)
                )
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            player?.stop()
            guard let self, self.generation == token else { return }
            self.ambiencePlayer = nil
            self.ambienceFadeTask = nil
        }
        return duration
    }

    private func stopAmbienceImmediately() {
        ambienceFadeTask?.cancel()
        ambienceFadeTask = nil
        ambiencePlayer?.stop()
        ambiencePlayer = nil
    }

    private func cancelPendingAudio() {
        pendingCompletionCueTask?.cancel()
        pendingCompletionCueTask = nil
        completionCuePlayer?.stop()
        completionCuePlayer = nil
        signalPlayer?.stop()
        signalPlayer = nil
    }
}
