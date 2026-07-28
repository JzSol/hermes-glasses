//
// HermesSpeechRecognizer.swift
//
// On-device live speech recognition. Feeds mic buffers to Apple's Speech
// framework and reports partial transcripts word-by-word; an utterance is
// finalized after a short pause (or on demand via finalizeNow()), then the
// recognizer restarts for the next utterance.
//

import AVFoundation
import Foundation
import os
import Speech

enum HermesSpeechError: LocalizedError {
    case notAuthorized
    case recognizerUnavailable

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Speech recognition access denied. Enable it in Settings → Privacy & Security → Speech Recognition."
        case .recognizerUnavailable:
            return "Speech recognition is not available on this device."
        }
    }
}

final class HermesSpeechRecognizer: NSObject, @unchecked Sendable {
    // MARK: - Callbacks (delivered on the main queue)

    /// Live partial transcript - fires as words are recognized
    var onPartial: ((String) -> Void)?
    /// Utterance complete (pause or finalizeNow) - trimmed, never empty
    var onFinal: ((String) -> Void)?

    // MARK: - Private

    private let logger = Logger(subsystem: "com.flowsxr.hermesglasses", category: "speech")
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

    /// Every mutable field lives here, behind one lock. Four threads reach
    /// this state: the audio-render thread (`append`), the Speech callback
    /// queue, the detached pause watchdog, and the main actor - and two of
    /// them can enter `emitFinalIfAny()` at the same moment.
    ///
    /// Rule for every helper below: mutate state inside `withLockUnchecked`,
    /// call Speech (or a callback) outside it. `task.cancel()` fires the old
    /// handler, which takes this lock - holding it across the call would
    /// deadlock on the non-recursive unfair lock.
    private struct State {
        var request: SFSpeechAudioBufferRecognitionRequest?
        var task: SFSpeechRecognitionTask?
        /// Incremented on every cycle start; callbacks from cancelled tasks
        /// carry an older generation and are ignored. Without this, each
        /// task.cancel() fires that task's handler with an error, which would
        /// tear down the NEW cycle - cascading until the recognizer is deaf
        /// while the UI still says Listening.
        var cycleGeneration = 0
        var latestPartial: String = ""
        var lastChangeAt: Date = .distantPast
        var pauseWatchdog: Task<Void, Never>?
        var isRunning = false
        var isSuspended = false
    }

    private let lock = OSAllocatedUnfairLock(uncheckedState: State())

    private var isRunning: Bool { lock.withLockUnchecked { $0.isRunning } }

    /// When true, no recognition runs (e.g. while TTS plays). Suspending
    /// discards any half-heard words and tears the cycle down entirely;
    /// unsuspending starts a fresh cycle. This way TTS can't leak into the
    /// next query and no task churns on silence while suspended.
    var isSuspended: Bool {
        get { lock.withLockUnchecked { $0.isSuspended } }
        set { setSuspended(newValue) }
    }

    private enum SuspensionChange {
        case unchanged
        case suspended(wasRunning: Bool)
        case resumed(wasRunning: Bool)
    }

    private func setSuspended(_ newValue: Bool) {
        let change = lock.withLockUnchecked { state -> SuspensionChange in
            guard state.isSuspended != newValue else { return .unchanged }
            state.isSuspended = newValue
            state.latestPartial = ""
            state.lastChangeAt = .distantPast
            return newValue
                ? .suspended(wasRunning: state.isRunning)
                : .resumed(wasRunning: state.isRunning)
        }

        switch change {
        case .unchanged:
            return
        case .suspended(let wasRunning):
            if wasRunning { tearDownCycle() }
            DispatchQueue.main.async { [weak self] in
                self?.onPartial?("")
            }
        case .resumed(let wasRunning):
            if wasRunning { startRecognitionCycle() }
        }
    }

    /// Silence after the last new word before the utterance is final
    private let pauseInterval: TimeInterval = 1.5

    // MARK: - Public API

    func requestAuthorization() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { status in
                    cont.resume(returning: status == .authorized)
                }
            }
        @unknown default:
            return false
        }
    }

    func start() throws {
        guard let recognizer, recognizer.isAvailable else {
            throw HermesSpeechError.recognizerUnavailable
        }
        let shouldStart = lock.withLockUnchecked { state -> Bool in
            guard !state.isRunning else { return false }
            state.isRunning = true
            return true
        }
        guard shouldStart else { return }
        startRecognitionCycle()
        startPauseWatchdog()
        logger.info("Speech recognition started (onDevice=\(recognizer.supportsOnDeviceRecognition))")
    }

    func stop() {
        let watchdog = lock.withLockUnchecked { state -> Task<Void, Never>? in
            state.isRunning = false
            let running = state.pauseWatchdog
            state.pauseWatchdog = nil
            return running
        }
        watchdog?.cancel()
        tearDownCycle()
    }

    /// Feed a raw mic buffer (any format - Speech converts internally).
    /// Runs on the audio-render thread: the critical section is one branch
    /// and one retain, and `append` itself happens outside it.
    func append(_ buffer: AVAudioPCMBuffer) {
        let request = lock.withLockUnchecked { state -> SFSpeechAudioBufferRecognitionRequest? in
            (state.isRunning && !state.isSuspended) ? state.request : nil
        }
        request?.append(buffer)
    }

    /// Force the current partial to be treated as final immediately
    func finalizeNow() {
        emitFinalIfAny()
    }

    /// Restart the recognition cycle with a fresh request. Required after
    /// an audio route change: the tap's buffer format changes and
    /// SFSpeechAudioBufferRecognitionRequest cannot absorb that mid-request.
    func restartCycle() {
        let running = lock.withLockUnchecked { state -> Bool in
            guard state.isRunning else { return false }
            state.latestPartial = ""
            state.lastChangeAt = .distantPast
            return true
        }
        guard running else { return }
        tearDownCycle()
        // startRecognitionCycle re-checks suspension under the lock
        startRecognitionCycle()
    }

    // MARK: - Private

    private func startRecognitionCycle() {
        guard let recognizer else { return }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true
        }

        // Publish the request and claim a generation before the task exists:
        // `append` must never see a nil request while a cycle is starting.
        let claimed = lock.withLockUnchecked { state -> Int? in
            guard !state.isSuspended else { return nil }
            state.cycleGeneration += 1
            state.request = req
            state.latestPartial = ""
            state.lastChangeAt = .distantPast
            return state.cycleGeneration
        }
        guard let generation = claimed else { return }

        // Outside the lock: recognitionTask can call its handler, which
        // takes the lock.
        let task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self, self.isCurrent(generation) else { return }

            if let result {
                let text = result.bestTranscription.formattedString
                let changed = self.lock.withLockUnchecked { state -> Bool in
                    guard state.isRunning, generation == state.cycleGeneration,
                          text != state.latestPartial else { return false }
                    state.latestPartial = text
                    state.lastChangeAt = Date()
                    return true
                }
                if changed {
                    DispatchQueue.main.async { [weak self] in
                        self?.onPartial?(text)
                    }
                }
                if result.isFinal {
                    self.emitFinalIfAny()
                }
            }

            if error != nil {
                // Recognizer gave up (silence limit, transient failure).
                // Emit anything we have and start a fresh cycle.
                self.logger.info("Recognition cycle #\(generation) ended with error - restarting")
                self.emitFinalIfAny()
            }
        }

        // A newer cycle may have started while the task was being created;
        // it owns `state.task`, and this one is already stale by generation,
        // so cancel it rather than leave a live task nobody can reach.
        let stale = lock.withLockUnchecked { state -> Bool in
            guard generation == state.cycleGeneration else { return true }
            state.task = task
            return false
        }
        if stale { task.cancel() }
    }

    private func isCurrent(_ generation: Int) -> Bool {
        lock.withLockUnchecked { $0.isRunning && generation == $0.cycleGeneration }
    }

    private func tearDownCycle() {
        let (task, request) = lock.withLockUnchecked {
            state -> (SFSpeechRecognitionTask?, SFSpeechAudioBufferRecognitionRequest?) in
            // Invalidate in-flight callbacks BEFORE cancel - cancel fires the
            // old task's handler with an error, which must see itself as stale
            state.cycleGeneration += 1
            let task = state.task
            let request = state.request
            state.task = nil
            state.request = nil
            return (task, request)
        }
        task?.cancel()
        request?.endAudio()
    }

    private func startPauseWatchdog() {
        let previous = lock.withLockUnchecked { state -> Task<Void, Never>? in
            let previous = state.pauseWatchdog
            state.pauseWatchdog = nil
            return previous
        }
        previous?.cancel()

        let watchdog = Task { [weak self] in
            while let self, !Task.isCancelled, self.isRunning {
                try? await Task.sleep(nanoseconds: 250_000_000)
                let due = self.lock.withLockUnchecked { state -> Bool in
                    guard !state.isSuspended, !state.latestPartial.isEmpty else { return false }
                    return Date().timeIntervalSince(state.lastChangeAt) >= self.pauseInterval
                }
                if due { self.emitFinalIfAny() }
            }
        }
        lock.withLockUnchecked { $0.pauseWatchdog = watchdog }
    }

    /// Swap in a fresh request/task WITHOUT ever leaving `request` nil.
    ///
    /// The obvious ordering - tearDownCycle() then startRecognitionCycle() -
    /// opens a window between the two in which `append(_:)` has no request to
    /// write to and silently discards every mic buffer, while the new
    /// SFSpeechRecognitionTask takes hundreds of milliseconds to go live.
    /// Utterances that begin in that window are simply never heard, which in
    /// a two-way conversation is most of the other person's half.
    ///
    /// Starting the replacement first closes the window: `startRecognitionCycle`
    /// bumps `cycleGeneration`, so when the old task is cancelled immediately
    /// afterwards its handler sees a stale generation and is ignored - the
    /// same guard that makes `tearDownCycle` safe.
    private func rotateCycle() {
        let (staleTask, staleRequest) = lock.withLockUnchecked {
            state -> (SFSpeechRecognitionTask?, SFSpeechAudioBufferRecognitionRequest?) in
            (state.task, state.request)
        }
        startRecognitionCycle()
        staleTask?.cancel()
        staleRequest?.endAudio()
    }

    /// The watchdog and the recognition handler both call this, sometimes at
    /// the same instant. Taking the partial and clearing it in ONE critical
    /// section is what makes an utterance emit exactly once: the second
    /// caller finds an empty string and falls out at the guard below.
    private func emitFinalIfAny() {
        let (partial, shouldRotate) = lock.withLockUnchecked { state -> (String, Bool) in
            let partial = state.latestPartial
            state.latestPartial = ""
            state.lastChangeAt = .distantPast
            return (partial, state.isRunning && !state.isSuspended)
        }

        // Restart the cycle so the next utterance starts clean (skipped
        // while suspended - unsuspend starts the next cycle)
        if shouldRotate {
            rotateCycle()
        }

        let text = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        logger.info("Utterance final: \(text, privacy: .public)")
        DispatchQueue.main.async { [weak self] in
            self?.onFinal?(text)
        }
    }
}
