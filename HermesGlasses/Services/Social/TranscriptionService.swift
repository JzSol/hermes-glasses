//
// TranscriptionService.swift
//
// Transcribes a finished recording, once, from the file.
//
// This is the counterpart to `ConversationRecorder` and the reason it exists.
// The live recogniser in `HermesSpeechRecognizer` is a command loop: it
// finalises an utterance after 1.5 s of silence and rebuilds its request
// between utterances, which is right for "hey, what's that building" and
// wrong for a conversation. Reading the whole file in one request removes
// three of the four faults at once - no restarts to drop audio, no
// pause-based segmentation, and punctuation, which the incremental path
// never had a whole sentence to infer.
//
// What it does NOT fix is far-field pickup: a phone mic pointed at the
// wearer will still under-hear the person across the table. That is
// acoustic. The recording is kept so a better engine can be run over it
// later without asking anyone to have the conversation again.
//

import Foundation
import Speech
import os

enum TranscriptionError: LocalizedError {
    case notAuthorized
    case recognizerUnavailable
    case empty

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Speech recognition access denied. Enable it in Settings → Privacy & Security → Speech Recognition."
        case .recognizerUnavailable:
            return "Speech recognition is not available on this device."
        case .empty:
            return "Nothing recognisable in the recording."
        }
    }
}

enum TranscriptionService {
    private static let logger = Logger(
        subsystem: "com.flowsxr.hermesglasses", category: "transcription"
    )

    /// Transcribe a recorded WAV into paragraph-per-pause lines.
    ///
    /// On-device by design: this app's promise is that encounters never leave
    /// the phone, and `requiresOnDeviceRecognition` is what keeps a recorded
    /// conversation - the most sensitive thing it stores - off Apple's
    /// servers. Devices that cannot do it on-device get nothing rather than a
    /// silent upload.
    static func transcribe(fileAt url: URL) async throws -> [String] {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw TranscriptionError.notAuthorized
        }
        // Pinned to the same locale as the live recogniser
        // (`HermesSpeechRecognizer`), deliberately: the file transcript
        // REPLACES what the live pass heard, and two engines disagreeing
        // about the language would show up as a transcript that changes
        // dialect halfway through the encounter.
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition
        else {
            throw TranscriptionError.recognizerUnavailable
        }

        // A partially written file (crash mid-capture) still has its audio;
        // only the header's sizes are stale. Fix them rather than refuse.
        _ = ConversationRecorder.repairIfNeeded(at: url)

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true

        let handle = Handle()
        let transcription = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<SFTranscription, Error>) in
                handle.begin(continuation)
                let task = recognizer.recognitionTask(with: request) { result, error in
                    if let result, result.isFinal {
                        handle.finish(.success(result.bestTranscription))
                    } else if let error {
                        handle.finish(.failure(error))
                    }
                }
                handle.track(task)
            }
        } onCancel: {
            handle.cancel()
        }

        let lines = segment(transcription)
        guard !lines.isEmpty else { throw TranscriptionError.empty }
        logger.info("Transcribed \(lines.count, privacy: .public) line(s) from \(url.lastPathComponent, privacy: .public)")
        return lines
    }

    /// The state one file transcription needs shared between three places:
    /// the continuation closure, the Speech callback queue, and the
    /// cancellation handler.
    ///
    /// Two jobs. `resume` must happen exactly once - the handler fires for
    /// partials, the final result AND errors, and can deliver a result and
    /// then an error. And the `SFSpeechRecognitionTask` has to be reachable
    /// from outside the closure: it used to be discarded, so cancelling the
    /// enclosing Swift task left an hour of audio being recognised for an
    /// answer nobody was waiting for any more.
    private final class Handle: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<SFTranscription, Error>?
        private var recognition: SFSpeechRecognitionTask?
        private var isCancelled = false

        func begin(_ continuation: CheckedContinuation<SFTranscription, Error>) {
            lock.lock()
            self.continuation = continuation
            let already = isCancelled
            lock.unlock()
            // Cancellation can land before the continuation exists.
            if already { cancel() }
        }

        func track(_ task: SFSpeechRecognitionTask) {
            lock.lock()
            let already = isCancelled
            if !already { recognition = task }
            lock.unlock()
            if already { task.cancel() }
        }

        func finish(_ outcome: Result<SFTranscription, Error>) {
            lock.lock()
            let pending = continuation
            continuation = nil
            recognition = nil
            lock.unlock()
            pending?.resume(with: outcome)
        }

        /// Abort the Speech task and fail the await. The await is failed here
        /// rather than left to the result handler: cancelling a URL request
        /// is not guaranteed to call it back, and a continuation nobody ever
        /// resumes is a leak that never resolves.
        func cancel() {
            lock.lock()
            isCancelled = true
            let task = recognition
            recognition = nil
            lock.unlock()
            task?.cancel()
            finish(.failure(CancellationError()))
        }
    }

    /// Break one long transcription into readable lines.
    ///
    /// Sentence punctuation is the split point, not silence: `addsPunctuation`
    /// gives real sentence ends, and they survive a speaker trailing off
    /// mid-thought where a pause threshold would cut the sentence in half.
    /// Segment boundaries are a display concern only - the events store what
    /// this returns, one speech event per line, exactly as the live path did.
    static func segment(_ transcription: SFTranscription) -> [String] {
        segment(transcription.formattedString)
    }

    static func segment(_ text: String) -> [String] {
        let terminators: Set<Character> = [".", "?", "!"]
        var lines: [String] = []
        var current = ""
        let characters = Array(text)

        for (index, character) in characters.enumerated() {
            current.append(character)
            guard terminators.contains(character) else { continue }
            // Only break when the sentence actually ends here. A terminator
            // followed by another one is an ellipsis or "?!", and splitting
            // inside it turns "And then... nothing" into three lines, two of
            // which are a single full stop.
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            guard next == nil || next!.isWhitespace else { continue }

            let line = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { lines.append(line) }
            current = ""
        }

        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { lines.append(tail) }
        return lines
    }
}
