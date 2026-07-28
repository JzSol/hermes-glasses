//
// ConversationRecorder.swift
//
// Streams a conversation capture's microphone audio to a WAV file so the
// recording, not the live recognizer, is the source of truth.
//
// Why this exists: SFSpeechRecognizer loses conversation. It is a dictation
// model driven one utterance at a time, and `HermesSpeechRecognizer` used to
// tear its request down and rebuild it after every utterance - during which
// `append(_:)` silently dropped every mic buffer, which in a two-way
// conversation is exactly when the other person starts talking. A recording
// has no such window. Whatever the recogniser misses live can be recovered
// from the file afterwards; what is never written down cannot.
//
// Foundation only - no AVFoundation here. The manager hands over PCM16 mono
// 16 kHz Data (already converted for the bridge path) and this type only
// decides where the bytes go.
//

import Foundation
import os

/// Appends PCM16 mono samples to a WAV file, off the audio thread.
///
/// The header is written up front with placeholder sizes and patched on
/// `finish()`, so a crash mid-capture still leaves a file whose audio data is
/// intact - most players will read it, and `repairIfNeeded` fixes the sizes
/// on next launch.
final class ConversationRecorder: @unchecked Sendable {
    private let logger = Logger(
        subsystem: "com.flowsxr.hermesglasses", category: "recorder"
    )

    /// PCM16 mono at the rate `HermesAudioManager.captureFormat` produces.
    /// Changing this without changing that format yields chipmunk audio and
    /// a transcript to match.
    static let sampleRate = 16000
    static let bitsPerSample = 16
    static let channels = 1

    /// Header is fixed-size for PCM: RIFF(12) + fmt(24) + data header(8).
    private static let headerBytes = 44

    /// Serial, so writes never land on the audio thread and never interleave.
    private let queue = DispatchQueue(
        label: "com.flowsxr.hermesglasses.recorder", qos: .utility
    )

    private var handle: FileHandle?
    private var bytesWritten = 0
    private(set) var url: URL?

    // MARK: - Lifecycle

    /// Begin a recording at `url`. Returns false when the file could not be
    /// opened - the caller carries on with a capture that has no audio,
    /// because a missing recording must never cost the transcript or photos.
    @discardableResult
    func start(url: URL) -> Bool {
        finish()
        return queue.sync {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                FileManager.default.createFile(atPath: url.path, contents: nil)
                let handle = try FileHandle(forWritingTo: url)
                try handle.write(contentsOf: Self.header(dataBytes: 0))
                self.handle = handle
                self.url = url
                self.bytesWritten = 0
                logger.info("Recording to \(url.lastPathComponent, privacy: .public)")
                return true
            } catch {
                logger.error("Could not open recording: \(error.localizedDescription, privacy: .public)")
                self.handle = nil
                self.url = nil
                return false
            }
        }
    }

    /// Append one buffer of PCM16 samples.
    ///
    /// Safe to call from the audio thread: it only enqueues. Doing the file
    /// write inline would put disk I/O on the render thread at ~47 buffers a
    /// second, which is how you get dropouts in the thing you are recording.
    func append(_ pcm16: Data) {
        guard !pcm16.isEmpty else { return }
        queue.async { [weak self] in
            guard let self, let handle = self.handle else { return }
            do {
                try handle.write(contentsOf: pcm16)
                self.bytesWritten += pcm16.count
            } catch {
                self.logger.error("Recording write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Close the file and patch the header's sizes. Returns the finished
    /// file, or nil if nothing was ever recorded.
    ///
    /// A recording with no audio in it is deleted rather than left as a
    /// 44-byte file: an empty WAV would be handed to the transcriber, fail
    /// there instead, and look like a transcription bug.
    @discardableResult
    func finish() -> URL? {
        queue.sync {
            guard let handle, let url else { return nil }
            self.handle = nil
            self.url = nil

            do {
                try handle.seek(toOffset: 0)
                try handle.write(contentsOf: Self.header(dataBytes: bytesWritten))
                try handle.close()
            } catch {
                logger.error("Could not finalise recording: \(error.localizedDescription, privacy: .public)")
            }

            guard bytesWritten > 0 else {
                try? FileManager.default.removeItem(at: url)
                logger.info("Recording had no audio - discarded")
                return nil
            }
            logger.info("Recording finished: \(self.duration(ofBytes: self.bytesWritten), privacy: .public)s")
            return url
        }
    }

    /// Abandon the recording and delete the file (capture cancelled).
    ///
    /// Written as a plain sync block rather than `queue.sync { () -> URL? }`:
    /// that shape crashed swift-frontend in ClosureLifetimeFixup on this
    /// toolchain. Keep the closure returning Void.
    func discard() {
        var doomed: URL?
        queue.sync {
            guard let handle = self.handle, let url = self.url else { return }
            try? handle.close()
            self.handle = nil
            self.url = nil
            doomed = url
        }
        guard let doomed else { return }
        try? FileManager.default.removeItem(at: doomed)
    }

    /// Seconds of audio recorded so far, 0 when nothing is being recorded.
    ///
    /// Keyed off the open file, not the byte count: `finish()` needs
    /// `bytesWritten` to patch the header and so never clears it, which left
    /// this reporting the length of the PREVIOUS capture for the whole gap
    /// between recordings.
    var recordedSeconds: TimeInterval {
        queue.sync { handle == nil ? 0 : duration(ofBytes: bytesWritten) }
    }

    private func duration(ofBytes bytes: Int) -> TimeInterval {
        let bytesPerFrame = Self.channels * Self.bitsPerSample / 8
        guard bytesPerFrame > 0 else { return 0 }
        return TimeInterval(bytes / bytesPerFrame) / TimeInterval(Self.sampleRate)
    }

    // MARK: - WAV header

    /// A 44-byte canonical PCM WAV header for `dataBytes` of samples.
    static func header(dataBytes: Int) -> Data {
        func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8

        var header = Data()
        header.append("RIFF".data(using: .ascii)!)
        header.append(le32(UInt32(36 + dataBytes)))
        header.append("WAVE".data(using: .ascii)!)
        header.append("fmt ".data(using: .ascii)!)
        header.append(le32(16))                       // PCM fmt chunk size
        header.append(le16(1))                        // format: PCM
        header.append(le16(UInt16(channels)))
        header.append(le32(UInt32(sampleRate)))
        header.append(le32(UInt32(byteRate)))
        header.append(le16(UInt16(blockAlign)))
        header.append(le16(UInt16(bitsPerSample)))
        header.append("data".data(using: .ascii)!)
        header.append(le32(UInt32(dataBytes)))
        return header
    }

    /// Rewrite the sizes of a WAV whose header still says zero - the shape a
    /// crash mid-capture leaves behind. No-op for a healthy file.
    ///
    /// Returns true when the file holds usable audio afterwards.
    @discardableResult
    static func repairIfNeeded(at url: URL) -> Bool {
        guard let attributes = try? FileManager.default
            .attributesOfItem(atPath: url.path),
              let total = attributes[.size] as? Int,
              total > headerBytes
        else { return false }

        let dataBytes = total - headerBytes
        guard let handle = try? FileHandle(forUpdating: url) else { return false }
        defer { try? handle.close() }

        // Only touch it if the recorded length disagrees with the header -
        // reading four bytes is cheaper than rewriting a file that is fine.
        guard let existing = try? handle.read(upToCount: headerBytes),
              existing.count == headerBytes,
              existing != header(dataBytes: dataBytes)
        else { return true }

        do {
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: header(dataBytes: dataBytes))
            return true
        } catch {
            return false
        }
    }
}
