//
// AiSeeMicrophone.swift — AiSeeGlassKit
//
// startInputAudioStream → (SDK decode) → PCMResampler(16 kHz) → AiSeePCMSink.
// The SDK removes every stream target when a stream starts or ends, so the
// chain is attached inside onAudioStreamStartedHandler on every start (docs).
// Never call this directly while a still is in flight — the coordinator
// closes the mic first (FINDINGS §1).
//

import AVFoundation
import Foundation

#if canImport(RTKAIDeviceConnection)
import RTKAIDeviceConnection
import RTKAudioStreaming

/// `@unchecked Sendable` is safe because `resampler`, `sink` and `buffers` are
/// only touched inside `lock`: the SDK calls the started-handler and the sink
/// callback on its audio thread while `stop()` runs on the coordinator's actor.
/// `connection` and `log` are immutable.
final class AiSeeMicrophone: @unchecked Sendable {
    private let connection: IntelligenceDeviceConnection
    private let log: AiSeeLog
    private let lock = NSLock()
    // All of the below: `lock`-guarded.
    private var resampler: PCMResampler?
    private var sink: AiSeePCMSink?
    private var buffers = 0

    init(connection: IntelligenceDeviceConnection, log: @escaping AiSeeLog) {
        self.connection = connection
        self.log = log
    }

    private var bufferCount: Int { lock.withLock { buffers } }

    func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async throws {
        lock.withLock { buffers = 0 }
        connection.onAudioStreamStartedHandler = { [weak self] in
            guard let self else { return }
            do {
                let resampler = try PCMResampler(audioFrom: self.connection, resampleTo: AiSeePCM.sampleRate)
                guard let sink = AiSeePCMSink(upstreamFormat: resampler.outDataFormat, onBuffer: { [weak self] buffer in
                    if let self { self.lock.withLock { self.buffers += 1 } }
                    onBuffer(buffer)
                }) else {
                    self.log("mic: unusable resampler output format — no PCM sink attached")
                    return
                }
                resampler.addStreamTarget(sink)
                self.lock.withLock {
                    self.resampler = resampler
                    self.sink = sink
                }
                let f = self.connection.outDataFormat
                self.log("mic: stream started — device \(Int(f.mSampleRate)) Hz ×\(f.mChannelsPerFrame) → 16000 Hz mono")
            } catch {
                self.log("mic: resampler setup failed: \(error)")
            }
        }
        connection.onAudioStreamFinishedHandler = { [weak self] in
            self?.log("mic: stream finished (\(self?.bufferCount ?? 0) buffers)")
        }
        connection.onAudioStreamCancelledHandler = { [weak self] in self?.log("mic: stream cancelled") }
        do {
            try await connection.mediaRoutine.startInputAudioStream(mode: .default)
        } catch {
            log("mic: start failed: \(error)")
            throw AiSeeError.sdk(error)
        }
    }

    /// - Parameter releasingHandlers: clear the connection's three
    ///   `onAudioStream*Handler` properties, which `start()` installed. Pass false
    ///   when another `AiSeeMicrophone` has since installed its own — the
    ///   coordinator does this when it abandons a mic it started (the handlers are
    ///   connection-wide, so clearing them would silence the live one).
    func stop(releasingHandlers: Bool = true) async {
        let t0 = Date()
        do { try await connection.mediaRoutine.stopInputAudioStream() } catch { log("mic: stop error: \(error)") }
        let resampler: PCMResampler? = lock.withLock {
            let current = self.resampler
            self.resampler = nil
            self.sink = nil
            return current
        }
        connection.removeStreamTarget(resampler)
        if releasingHandlers {
            // Don't leave this mic's closures installed on a connection it no longer
            // feeds — the SDK would keep calling them for the next stream.
            connection.onAudioStreamStartedHandler = nil
            connection.onAudioStreamFinishedHandler = nil
            connection.onAudioStreamCancelledHandler = nil
        }
        log("mic: stopped in \(Int(Date().timeIntervalSince(t0) * 1000))ms")
    }
}
#endif
