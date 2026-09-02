//
// AdamSoundscapeWaveform.swift
//
// Pure PCM/WAV generation for Adam's listening cues.  This file deliberately
// imports Foundation only so waveform behaviour can be tested with swiftc
// without constructing AVFoundation players or touching an audio route.
//

import Foundation

/// A generated mono PCM16 clip and the metadata needed to play or inspect it.
/// Samples are normalized before conversion and therefore always remain in
/// the signed 16-bit range.
struct AdamSoundscapeClip: Equatable, Sendable {
    let sampleRate: Int
    let samples: [Int16]

    var duration: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return Double(samples.count) / Double(sampleRate)
    }

    /// Peak sample magnitude as a normalized 0...1 value.
    var peakAmplitude: Float {
        guard let peak = samples.map({ abs(Int($0)) }).max() else { return 0 }
        return Float(peak) / Float(Int16.max)
    }

    /// Raw little-endian PCM16 mono bytes suitable for the WAV writer.
    var pcmData: Data {
        AdamSoundscapeWaveform.pcmData(for: samples)
    }

    /// A self-contained RIFF/WAVE container suitable for AVAudioPlayer.
    var wavData: Data {
        AdamSoundscapeWaveform.wavData(for: samples, sampleRate: sampleRate)
    }
}

/// The two one-shot listening cues are rendered from one deliberately matched
/// additive-synthesis family. The Bluetooth ambience remains a separate,
/// continuous bed. No audio assets or licensed recordings are needed.
enum AdamSoundscapeCueDirection: Equatable, Sendable {
    case rising
    case falling
    case ready

    var opposite: Self {
        switch self {
        case .rising: return .falling
        case .falling: return .rising
        case .ready: return .ready
        }
    }
}

enum AdamSoundscapeCueEvent: Equatable, Sendable {
    case listeningStart
    case listeningEnd
    case responseReady

    var direction: AdamSoundscapeCueDirection {
        switch self {
        case .listeningStart: return .rising
        case .listeningEnd: return .falling
        case .responseReady: return .ready
        }
    }
}

struct AdamSoundscapeCueProfile: Equatable, Sendable {
    let family: String
    let direction: AdamSoundscapeCueDirection
    let duration: TimeInterval
    let attack: TimeInterval
    let release: TimeInterval
}

enum AdamSoundscapeWaveform {
    static let defaultSampleRate = 44_100
    static let fluteLoopDuration: TimeInterval = 8
    static let matchedCueFamily = "adam-listening-cue-v1"
    static let matchedCueDuration: TimeInterval = 0.36
    static let matchedCueAttack: TimeInterval = 0.018
    static let matchedCueRelease: TimeInterval = 0.09
    // Kept as compatibility names for callers that only know the old
    // opening/end API; both now resolve to the matched family duration.
    static let openingCueDuration = matchedCueDuration
    static let dropletDuration = matchedCueDuration
    static let speechStartCueDuration: TimeInterval = 0.075
    static let thinkingPulseDuration: TimeInterval = 0.24

    /// A very quiet, smooth-looping meditative flute-like drone.
    static func fluteLoop(
        sampleRate: Int = defaultSampleRate,
        duration: TimeInterval = fluteLoopDuration
    ) -> AdamSoundscapeClip {
        renderFlute(
            sampleRate: sampleRate,
            duration: duration,
            amplitude: 0.075,
            baseFrequency: 220,
            fadeDuration: 0.65
        )
    }

    /// The rising half of the matched one-shot listening pair.
    static func openingCue(
        sampleRate: Int = defaultSampleRate,
        duration: TimeInterval = openingCueDuration
    ) -> AdamSoundscapeClip {
        matchedCue(
            direction: .rising,
            sampleRate: sampleRate,
            duration: duration
        )
    }

    /// The falling half of the matched one-shot listening pair.
    static func droplet(
        sampleRate: Int = defaultSampleRate,
        duration: TimeInterval = dropletDuration
    ) -> AdamSoundscapeClip {
        matchedCue(
            direction: .falling,
            sampleRate: sampleRate,
            duration: duration
        )
    }

    static func profile(
        for event: AdamSoundscapeCueEvent
    ) -> AdamSoundscapeCueProfile {
        AdamSoundscapeCueProfile(
            family: matchedCueFamily,
            direction: event.direction,
            duration: matchedCueDuration,
            attack: matchedCueAttack,
            release: matchedCueRelease
        )
    }

    static func matchedCue(
        direction: AdamSoundscapeCueDirection,
        sampleRate: Int = defaultSampleRate,
        duration: TimeInterval = matchedCueDuration
    ) -> AdamSoundscapeClip {
        let rate = normalizedSampleRate(sampleRate)
        let seconds = normalizedDuration(duration, fallback: matchedCueDuration)
        let frameCount = frameCount(duration: seconds, sampleRate: rate)
        let release = min(matchedCueRelease, seconds / 2)
        var samples = [Int16](repeating: 0, count: frameCount)
        var phase = 0.0

        for index in 0..<frameCount {
            let time = Double(index) / Double(rate)
            let progress = frameCount > 1
                ? Double(index) / Double(frameCount - 1)
                : 1
            let directionProgress: Double
            switch direction {
            case .rising:
                directionProgress = progress
            case .falling:
                directionProgress = 1 - progress
            case .ready:
                // A small mid-high-mid turn says “your turn” without being
                // mistaken for either edge of the listening window.
                if progress < 0.5 {
                    directionProgress = 0.32 + progress * 0.88
                } else {
                    directionProgress = 0.76 - (progress - 0.5) * 0.48
                }
            }
            let frequency = matchedMotifFrequency(at: directionProgress)
            phase += 2 * Double.pi * frequency / Double(rate)

            let attack = smoothstep(min(1, time / max(matchedCueAttack, 0.0001)))
            let releaseEnvelope = release > 0 && seconds > 0
                ? smoothstep(min(1, max(0, (1 - progress) / (release / seconds))))
                : 1
            let envelope = attack * releaseEnvelope
            // The same harmonics and envelope are used in both directions;
            // only the phase-continuous pitch path is mirrored.
            let timbre =
                0.78 * sin(phase)
                + 0.17 * sin(2 * phase + 0.13)
                + 0.05 * sin(3 * phase + 0.41)
            samples[index] = pcm16(0.10 * envelope * timbre)
        }

        return AdamSoundscapeClip(sampleRate: rate, samples: samples)
    }

    static func matchedCue(
        for event: AdamSoundscapeCueEvent,
        sampleRate: Int = defaultSampleRate,
        duration: TimeInterval = matchedCueDuration
    ) -> AdamSoundscapeClip {
        matchedCue(
            direction: event.direction,
            sampleRate: sampleRate,
            duration: duration
        )
    }

    /// A very quiet, immediate acknowledgement that command speech started.
    /// Its short attack and release make it read as a tick without masking the
    /// first consonant of the command.
    static func speechStartCue(
        sampleRate: Int = defaultSampleRate,
        duration: TimeInterval = speechStartCueDuration
    ) -> AdamSoundscapeClip {
        renderSignal(
            sampleRate: sampleRate,
            duration: duration,
            amplitude: 0.035,
            frequencies: [1_760, 2_120],
            decay: 8.0,
            attack: 0.002
        )
    }

    /// A soft, rounded pulse for the thinking state. The session controls the
    /// delay and repetition interval; this function only renders the cue.
    static func thinkingPulse(
        sampleRate: Int = defaultSampleRate,
        duration: TimeInterval = thinkingPulseDuration
    ) -> AdamSoundscapeClip {
        renderSignal(
            sampleRate: sampleRate,
            duration: duration,
            amplitude: 0.028,
            frequencies: [330, 495],
            decay: 5.5,
            attack: 0.018
        )
    }

    /// Encode signed mono PCM16 samples in a canonical RIFF/WAVE container.
    /// The header is kept intentionally simple (PCM format, one channel) so
    /// AVAudioPlayer can decode the data on every supported iOS route.
    static func wavData(for samples: [Int16], sampleRate: Int) -> Data {
        let rate = normalizedSampleRate(sampleRate)
        let pcm = pcmData(for: samples)
        let riffSize = UInt32(min(UInt64(UInt32.max), UInt64(36) + UInt64(pcm.count)))
        let dataSize = UInt32(min(UInt64(UInt32.max), UInt64(pcm.count)))

        var wav = Data(capacity: min(Int(UInt32.max), 44 + pcm.count))
        wav.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // RIFF
        wav.append(littleEndianBytes(riffSize))
        wav.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // WAVE
        wav.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // fmt
        wav.append(littleEndianBytes(UInt32(16))) // PCM fmt chunk size
        wav.append(littleEndianBytes(UInt16(1))) // PCM
        wav.append(littleEndianBytes(UInt16(1))) // mono
        wav.append(littleEndianBytes(UInt32(rate)))
        wav.append(littleEndianBytes(UInt32(min(UInt64(UInt32.max), UInt64(rate) * 2))))
        wav.append(littleEndianBytes(UInt16(2))) // block align
        wav.append(littleEndianBytes(UInt16(16))) // bits/sample
        wav.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // data
        wav.append(littleEndianBytes(dataSize))
        wav.append(pcm)
        return wav
    }

    /// Convert normalized samples to signed little-endian PCM16 bytes.
    static func pcmData(for samples: [Int16]) -> Data {
        var data = Data(capacity: samples.count * MemoryLayout<Int16>.size)
        for sample in samples {
            var littleEndian = sample.littleEndian
            withUnsafeBytes(of: &littleEndian) { bytes in
                data.append(contentsOf: bytes)
            }
        }
        return data
    }

    // MARK: - Private rendering helpers

    private static func renderFlute(
        sampleRate: Int,
        duration: TimeInterval,
        amplitude: Double,
        baseFrequency: Double,
        fadeDuration: TimeInterval
    ) -> AdamSoundscapeClip {
        let rate = normalizedSampleRate(sampleRate)
        let seconds = normalizedDuration(duration, fallback: fluteLoopDuration)
        let frameCount = frameCount(duration: seconds, sampleRate: rate)
        let fade = min(max(0, fadeDuration), seconds / 2)
        var samples = [Int16](repeating: 0, count: frameCount)
        var fundamentalPhase = 0.0
        var fifthPhase = 0.0

        for index in 0..<frameCount {
            let time = Double(index) / Double(rate)
            let progress = frameCount > 1
                ? Double(index) / Double(frameCount - 1)
                : 1

            // Integrating the frequency keeps vibrato phase-continuous and
            // avoids stepping the carrier each sample.
            let vibrato = 2.6 * sin(2 * Double.pi * 4.25 * time)
            let slowBend = 2.2 * sin(2 * Double.pi * 0.075 * time)
            let fundamentalFrequency = max(20, baseFrequency + vibrato + slowBend)
            let fifthFrequency = max(20, baseFrequency * 1.5 + vibrato * 0.45)
            fundamentalPhase += 2 * Double.pi * fundamentalFrequency / Double(rate)
            fifthPhase += 2 * Double.pi * fifthFrequency / Double(rate)

            let fadeIn = fade > 0 ? min(1, time / fade) : 1
            let fadeOut = fade > 0 && seconds > 0
                ? min(1, max(0, (1 - progress) / (fade / seconds)))
                : 1
            // Smoothstep removes a sharp slope at either loop boundary.
            let edge = smoothstep(min(fadeIn, fadeOut))
            let breath =
                0.050 * sin(2 * Double.pi * 31 * time + 0.2)
                + 0.028 * sin(2 * Double.pi * 47 * time + 1.1)
            let tremolo = 0.91 + 0.09 * sin(2 * Double.pi * 0.18 * time + 0.4)
            let tone =
                0.78 * sin(fundamentalPhase)
                + 0.22 * sin(fundamentalPhase * 2 + 0.13)
                + 0.095 * sin(fundamentalPhase * 3 + 0.41)
                + 0.13 * sin(fifthPhase + 0.8)
                + breath
            let value = amplitude * edge * tremolo * tone
            samples[index] = pcm16(value)

        }

        return AdamSoundscapeClip(sampleRate: rate, samples: samples)
    }

    private static func renderSignal(
        sampleRate: Int,
        duration: TimeInterval,
        amplitude: Double,
        frequencies: [Double],
        decay: Double,
        attack: Double
    ) -> AdamSoundscapeClip {
        let rate = normalizedSampleRate(sampleRate)
        let seconds = normalizedDuration(duration, fallback: 0.1)
        let frameCount = frameCount(duration: seconds, sampleRate: rate)
        var samples = [Int16](repeating: 0, count: frameCount)
        var phases = [Double](repeating: 0, count: frequencies.count)

        for index in 0..<frameCount {
            let time = Double(index) / Double(rate)
            let progress = frameCount > 1
                ? Double(index) / Double(frameCount - 1)
                : 1
            let attackEnvelope = min(1, time / max(attack, 0.0001))
            let releaseEnvelope = max(0, 1 - progress)
            let envelope = attackEnvelope * releaseEnvelope * exp(-decay * time)
            var signal = 0.0
            for (offset, frequency) in frequencies.enumerated() {
                phases[offset] += 2 * Double.pi * frequency / Double(rate)
                signal += sin(phases[offset]) / Double(max(1, frequencies.count))
            }
            samples[index] = pcm16(amplitude * envelope * signal)
        }
        return AdamSoundscapeClip(sampleRate: rate, samples: samples)
    }

    private static func matchedMotifFrequency(at progress: Double) -> Double {
        let notes = [392.0, 523.25, 659.25]
        let clamped = min(1, max(0, progress))
        let scaled = clamped * Double(notes.count - 1)
        let lowerIndex = min(notes.count - 2, Int(scaled.rounded(.down)))
        let localProgress = smoothstep(scaled - Double(lowerIndex))
        return notes[lowerIndex]
            + (notes[lowerIndex + 1] - notes[lowerIndex]) * localProgress
    }

    private static func smoothstep(_ value: Double) -> Double {
        let clamped = min(1, max(0, value))
        return clamped * clamped * (3 - 2 * clamped)
    }

    private static func pcm16(_ normalized: Double) -> Int16 {
        guard normalized.isFinite else { return 0 }
        let bounded = min(1, max(-1, normalized))
        return Int16((bounded * Double(Int16.max)).rounded())
    }

    private static func normalizedSampleRate(_ sampleRate: Int) -> Int {
        guard sampleRate > 0 else { return defaultSampleRate }
        return min(sampleRate, Int(UInt32.max))
    }

    private static func normalizedDuration(
        _ duration: TimeInterval,
        fallback: TimeInterval
    ) -> TimeInterval {
        guard duration.isFinite, duration > 0 else { return fallback }
        // A malformed caller should not be able to produce an allocation that
        // wraps the frame count. Normal callers use sub-second to eight-second
        // clips, so this generous cap does not alter the intended cues.
        return min(duration, 60 * 60)
    }

    private static func frameCount(duration: TimeInterval, sampleRate: Int) -> Int {
        let value = duration * Double(sampleRate)
        guard value.isFinite, value > 0 else { return 1 }
        return max(1, min(Int.max / MemoryLayout<Int16>.size, Int(value.rounded())))
    }

    private static func littleEndianBytes<T: FixedWidthInteger>(_ value: T) -> Data {
        var littleEndian = value.littleEndian
        return withUnsafeBytes(of: &littleEndian) { Data($0) }
    }
}
