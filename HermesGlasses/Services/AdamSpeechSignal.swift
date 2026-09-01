//
// AdamSpeechSignal.swift
//
// Pure signal helpers for Adam's wake recognition and bridge-upload paths. The
// production buffer adapter lives in HermesAudioManager because it needs
// AVAudioPCMBuffer; keeping the math here Foundation-only makes it possible
// to exercise the gain, limiter, and meter behavior with plain swiftc tests.
//

import Foundation

/// Bounded, Adam-only conditioning for quiet microphone input.
///
/// The defaults are intentionally conservative. They are applied only to
/// Adam-owned copies sent to wake recognition or the Hermes bridge; recordings
/// and the original Hermes target continue to receive the source samples.
enum AdamSpeechSignal {
    struct Configuration: Equatable, Sendable {
        /// Maximum linear pre-amplification for quiet HFP speech.
        var gain: Float = 3.5
        /// Per-sample noise floor, expressed as normalized PCM amplitude.
        // Ray-Ban HFP speech can contain useful consonants below 0.0025. Keep
        // only true near-digital noise below the floor; server VAD handles
        // sustained room ambience after the utterance is uploaded.
        var noiseFloor: Float = 0.0005
        /// Start of the soft limiter in normalized PCM amplitude.
        var limiterThreshold: Float = 0.86
        /// Absolute output ceiling, below full-scale to leave a little headroom.
        var limiterCeiling: Float = 0.98

        static let `default` = Configuration()
    }

    /// Apply a noise floor, bounded gain, and soft limiter to one normalized
    /// PCM sample. Non-finite values are treated as silence so a malformed
    /// source buffer cannot poison an entire recognition cycle.
    static func processSample(
        _ sample: Float,
        configuration: Configuration = .default
    ) -> Float {
        guard sample.isFinite else { return 0 }

        let gain = max(1, configuration.gain.isFinite ? configuration.gain : 1)
        let floor = max(0, configuration.noiseFloor.isFinite ? configuration.noiseFloor : 0)
        let threshold = min(
            max(0, configuration.limiterThreshold.isFinite ? configuration.limiterThreshold : 0.86),
            0.999
        )
        let ceiling = min(
            max(threshold, configuration.limiterCeiling.isFinite ? configuration.limiterCeiling : 0.98),
            1
        )

        let sign: Float = sample < 0 ? -1 : 1
        let magnitude = abs(sample)
        guard magnitude > floor else { return 0 }

        let amplified = min(magnitude * gain, Float.greatestFiniteMagnitude)
        let limited: Float
        if amplified <= threshold {
            limited = amplified
        } else {
            // Preserve the linear region and compress only the excess. tanh
            // asymptotically approaches the ceiling, avoiding hard clicks.
            let span = max(ceiling - threshold, Float.ulpOfOne)
            let excess = max(0, amplified - threshold) / span
            limited = threshold + span * tanh(excess)
        }

        return sign * min(max(0, limited), ceiling)
    }

    /// In-place conditioning for normalized Float32 samples.
    static func processFloatSamples(
        _ samples: inout [Float],
        configuration: Configuration = .default
    ) {
        for index in samples.indices {
            samples[index] = processSample(samples[index], configuration: configuration)
        }
    }

    /// In-place conditioning for signed PCM16 samples. Conversion goes
    /// through normalized Float32 so Float32 and Int16 paths share identical
    /// noise-floor, gain, and limiter behavior.
    static func processInt16Samples(
        _ samples: inout [Int16],
        configuration: Configuration = .default
    ) {
        for index in samples.indices {
            samples[index] = processInt16Sample(
                samples[index],
                configuration: configuration
            )
        }
    }

    /// Gain needed to bring a quiet utterance toward a healthy Whisper input
    /// level. The bound prevents room noise from being amplified without
    /// limit, while already-loud speech remains unity gain.
    static func adaptiveGain(
        rms: Float,
        targetRMS: Float = 0.10,
        maximum: Float = 6
    ) -> Float {
        guard rms.isFinite, rms > 0,
              targetRMS.isFinite, targetRMS > 0 else { return 1 }
        let ceiling = max(1, maximum.isFinite ? maximum : 1)
        return min(ceiling, max(1, targetRMS / rms))
    }

    /// Speech threshold derived from recent ambient noise. This replaces the
    /// old fixed 0.015 RMS gate that missed quiet Ray-Ban HFP microphones.
    static func adaptiveSpeechThreshold(noiseRMS: Float) -> Float {
        let noise = noiseRMS.isFinite ? max(0, noiseRMS) : 0
        return min(0.02, max(0.0025, noise * 3))
    }

    /// Process one signed PCM16 sample without allocating. This is used by
    /// the real-time AVAudioPCMBuffer adapter.
    static func processInt16Sample(
        _ sample: Int16,
        configuration: Configuration = .default
    ) -> Int16 {
        let normalized = Float(sample) / 32768
        let processed = processSample(normalized, configuration: configuration)
        let scaled = Int((processed * 32767).rounded())
        return Int16(max(-32768, min(32767, scaled)))
    }

    /// Root-mean-square amplitude for normalized Float32 samples.
    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples where sample.isFinite {
            sum += sample * sample
        }
        return sqrt(sum / Float(samples.count))
    }

    /// Convert RMS amplitude to dBFS. Silence is represented as negative
    /// infinity internally, but callers receive a finite 0...1 meter value.
    static func dbFS(rms: Float) -> Float {
        guard rms.isFinite, rms > 0 else { return -.infinity }
        return 20 * log10(rms)
    }

    /// Map RMS amplitude into a UI level. Values at or below the floor are
    /// silent (0), while values at or above the ceiling reach 1. A dB scale
    /// makes ordinary quiet speech visibly move the meter instead of leaving
    /// the linear-RMS progress bar near zero.
    static func meterLevel(
        rms: Float,
        floorDBFS: Float = -60,
        ceilingDBFS: Float = -6
    ) -> Float {
        let floor = min(floorDBFS, ceilingDBFS)
        let ceiling = max(floorDBFS, ceilingDBFS)
        let db = dbFS(rms: rms)
        guard db.isFinite else { return 0 }
        guard ceiling > floor else { return db >= ceiling ? 1 : 0 }
        guard db > floor else { return 0 }
        guard db < ceiling else { return 1 }
        return min(1, max(0, (db - floor) / (ceiling - floor)))
    }

    /// One allocation-free smoothing step for a meter value. Silence snaps to
    /// zero so a stopped microphone cannot leave the UI looking active; speech
    /// attacks quickly and releases more gently to avoid visual jitter.
    static func smoothedMeterLevel(
        previous: Float,
        rms: Float,
        attack: Float = 0.55,
        release: Float = 0.20
    ) -> Float {
        let target = meterLevel(rms: rms)
        guard target > 0 else { return 0 }

        let prior = min(1, max(0, previous.isFinite ? previous : 0))
        let coefficient = min(
            1,
            max(0, (target > prior ? attack : release).isFinite
                ? (target > prior ? attack : release)
                : 0.2)
        )
        return min(1, max(0, prior + (target - prior) * coefficient))
    }
}
