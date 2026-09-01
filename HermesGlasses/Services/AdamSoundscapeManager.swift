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
    /// The generated flute is already quiet; this player-level value leaves
    /// headroom for HFP output and keeps the cue below speech volume.
    var ambienceVolume: Float = 0.78
    var openingCueVolume: Float = 0.82
    var dropletVolume: Float = 0.78
    var fadeOutDuration: TimeInterval = 0.16

    static let `default` = AdamSoundscapeConfiguration()

    var normalized: AdamSoundscapeConfiguration {
        var copy = self
        copy.ambienceVolume = Self.volume(copy.ambienceVolume)
        copy.openingCueVolume = Self.volume(copy.openingCueVolume)
        copy.dropletVolume = Self.volume(copy.dropletVolume)
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
        case openingCue
    }

    private let logger = Logger(
        subsystem: "com.flowsxr.hermesglasses",
        category: "adam-soundscape"
    )

    private let configuration: AdamSoundscapeConfiguration
    private let fluteLoopData: Data
    private let openingCueData: Data
    private let dropletData: Data

    private var ambiencePlayer: AVAudioPlayer?
    private var dropletPlayer: AVAudioPlayer?
    private var ambienceFadeTask: Task<Void, Never>?
    private var pendingDropletTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var listeningMode: ListeningMode?

    /// True from `startListening` until `finishListening` or
    /// `stopImmediately`, including the short period after an opening cue has
    /// naturally finished while speech recognition is starting.
    private(set) var isListening = false

    /// True only for the Bluetooth/HFP ambience-loop mode.
    var isLooping: Bool { listeningMode == .loop }

    /// Whether the end cue is currently rendering.
    var isPlayingDroplet: Bool { dropletPlayer?.isPlaying == true }

    init(
        configuration: AdamSoundscapeConfiguration = .default,
        sampleRate: Int = AdamSoundscapeWaveform.defaultSampleRate
    ) {
        self.configuration = configuration.normalized
        self.fluteLoopData = AdamSoundscapeWaveform.fluteLoop(sampleRate: sampleRate).wavData
        self.openingCueData = AdamSoundscapeWaveform.openingCue(sampleRate: sampleRate).wavData
        self.dropletData = AdamSoundscapeWaveform.droplet(sampleRate: sampleRate).wavData
        super.init()
    }

    deinit {
        ambienceFadeTask?.cancel()
        pendingDropletTask?.cancel()
        ambiencePlayer?.stop()
        dropletPlayer?.stop()
    }

    /// Begin a listening cue.
    ///
    /// Bluetooth HFP callers pass `loop: true` to keep the low flute bed
    /// active while the recognizer accepts speech. Phone-mic fallback callers
    /// pass `loop: false`; that mode plays only the brief opening cue so the
    /// generated sound does not get fed back into the phone microphone.
    /// Repeating the same call while active is idempotent.
    func startListening(loop: Bool) {
        let requestedMode: ListeningMode = loop ? .loop : .openingCue
        if isListening, listeningMode == requestedMode {
            return
        }

        // A new listening period owns the route and must not leave an earlier
        // droplet or fade task rendering under speech.
        cancelPendingAudio()
        stopAmbienceImmediately()

        generation &+= 1
        isListening = true
        listeningMode = requestedMode

        let data = loop ? fluteLoopData : openingCueData
        let volume = loop
            ? configuration.ambienceVolume
            : configuration.openingCueVolume
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
    /// droplet is scheduled after that fade so cues never overlap. Calling
    /// this more than once for one period is a no-op, guaranteeing one end
    /// droplet at most.
    func finishListening(playDroplet: Bool = true) {
        guard isListening else { return }

        isListening = false
        listeningMode = nil
        generation &+= 1
        let fadeDuration = fadeAndStopAmbience()
        guard playDroplet else { return }

        pendingDropletTask?.cancel()
        let token = generation
        pendingDropletTask = Task { @MainActor [weak self] in
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
            self.pendingDropletTask = nil
            self.playDroplet()
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
        stopAmbienceImmediately()
        playDroplet()
    }

    /// Stop all sound immediately, including any queued fade/droplet. This is
    /// used before processing or TTS and intentionally emits no end cue.
    func stopImmediately() {
        generation &+= 1
        isListening = false
        listeningMode = nil
        cancelPendingAudio()
        stopAmbienceImmediately()
        dropletPlayer?.stop()
        dropletPlayer = nil
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

    private func playDroplet() {
        // There should be no overlap even if a caller begins a new end cue
        // after a route/session reset. The listening-period guard is what
        // prevents normal duplicate `finishListening` calls.
        dropletPlayer?.stop()
        dropletPlayer = nil
        guard let player = makePlayer(data: dropletData, volume: configuration.dropletVolume) else {
            logger.error("Unable to create Adam droplet player")
            return
        }
        dropletPlayer = player
        player.prepareToPlay()
        guard player.play() else {
            dropletPlayer = nil
            logger.error("Unable to start Adam droplet player")
            return
        }
    }

    /// Fade the active ambience player and return the delay before another
    /// cue may safely begin. A non-playing opening cue is stopped immediately.
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
        pendingDropletTask?.cancel()
        pendingDropletTask = nil
        dropletPlayer?.stop()
        dropletPlayer = nil
    }
}
