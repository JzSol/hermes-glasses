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

        let transcription = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<SFTranscription, Error>) in
            // `resume` must happen exactly once, but the handler fires for
            // partials, the final result AND errors - and can deliver a
            // result and then an error. Guard it.
            let hasResumed = OSAllocatedUnfairLock(initialState: false)
            func finish(_ outcome: Result<SFTranscription, Error>) {
                let first = hasResumed.withLock { resumed -> Bool in
                    guard !resumed else { return false }
                    resumed = true
                    return true
                }
                guard first else { return }
                continuation.resume(with: outcome)
            }

            recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    finish(.success(result.bestTranscription))
                } else if let error {
                    finish(.failure(error))
                }
            }
        }

        let lines = segment(transcription)
        guard !lines.isEmpty else { throw TranscriptionError.empty }
        logger.info("Transcribed \(lines.count, privacy: .public) line(s) from \(url.lastPathComponent, privacy: .public)")
        return lines
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
