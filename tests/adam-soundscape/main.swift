//
// Standalone tests for AdamSoundscapeWaveform. No XCTest target is required.
// Build + run:
//
//   swiftc HermesGlasses/Services/AdamSoundscapeWaveform.swift \
//     tests/adam-soundscape/main.swift -o /tmp/adam-soundscape-tests && \
//     /tmp/adam-soundscape-tests
//

import Foundation

var failures = 0

func expect(_ condition: Bool, _ label: String) {
    if condition {
        print("PASS \(label)")
    } else {
        failures += 1
        print("FAIL \(label)")
    }
}

func readUInt16LE(_ data: Data, _ offset: Int) -> UInt16 {
    UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
}

func readUInt32LE(_ data: Data, _ offset: Int) -> UInt32 {
    UInt32(data[offset])
        | (UInt32(data[offset + 1]) << 8)
        | (UInt32(data[offset + 2]) << 16)
        | (UInt32(data[offset + 3]) << 24)
}

func ascii(_ data: Data, _ range: Range<Int>) -> String {
    String(decoding: data[range], as: UTF8.self)
}

let flute = AdamSoundscapeWaveform.fluteLoop(sampleRate: 8_000, duration: 2)
let opening = AdamSoundscapeWaveform.openingCue(sampleRate: 8_000)
let droplet = AdamSoundscapeWaveform.droplet(sampleRate: 8_000)
let speechStart = AdamSoundscapeWaveform.speechStartCue(sampleRate: 8_000)
let thinking = AdamSoundscapeWaveform.thinkingPulse(sampleRate: 8_000)

// Basic shape and metadata.
expect(flute.sampleRate == 8_000, "flute keeps requested sample rate")
expect(abs(flute.duration - 2) < 1.0 / 8_000, "flute duration is sample accurate")
expect(flute.samples.count > 0 && droplet.samples.count > 0, "clips contain samples")
expect(flute.samples.contains { $0 != 0 }, "flute is non-silent")
expect(droplet.samples.contains { $0 != 0 }, "droplet is non-silent")
expect(opening.samples.contains { $0 != 0 }, "opening cue is non-silent")
expect(speechStart.samples.contains { $0 != 0 }, "speech-start cue is non-silent")
expect(thinking.samples.contains { $0 != 0 }, "thinking pulse is non-silent")
expect(flute.samples.allSatisfy { $0 >= Int16.min && $0 <= Int16.max }, "flute samples are bounded")
expect(droplet.samples.allSatisfy { $0 >= Int16.min && $0 <= Int16.max }, "droplet samples are bounded")
// Integer PCM values are finite by construction; the range checks above are
// the integer equivalent of a finite-value assertion.
expect(flute.samples.allSatisfy { Int($0) >= Int(Int16.min) && Int($0) <= Int(Int16.max) }, "flute samples are finite")
expect(droplet.samples.allSatisfy { Int($0) >= Int(Int16.min) && Int($0) <= Int(Int16.max) }, "droplet samples are finite")
expect(flute.peakAmplitude > 0 && flute.peakAmplitude < 0.2, "flute remains very quiet")
expect(droplet.peakAmplitude > flute.peakAmplitude, "droplet has a distinct cue level")
expect(speechStart.peakAmplitude > 0 && speechStart.peakAmplitude < 0.06,
       "speech-start cue stays quiet")
expect(thinking.peakAmplitude > 0 && thinking.peakAmplitude < 0.06,
       "thinking pulse stays quiet")

// Smooth fades prevent clicks at the start/end of generated clips.
expect(abs(Int(flute.samples.first ?? 1)) <= 2, "flute starts at a fade edge")
expect(abs(Int(flute.samples.last ?? 1)) <= 2, "flute ends at a fade edge")
expect(abs(Int(opening.samples.first ?? 1)) <= 2, "opening starts at a fade edge")
expect(abs(Int(opening.samples.last ?? 1)) <= 2, "opening ends at a fade edge")
expect(abs(Int(droplet.samples.first ?? 1)) <= 2, "droplet starts at a fade edge")
expect(abs(Int(droplet.samples.last ?? 1)) <= 2, "droplet ends at a fade edge")
expect(abs(Int(speechStart.samples.first ?? 1)) <= 2,
       "speech-start cue starts at a fade edge")
expect(abs(Int(speechStart.samples.last ?? 1)) <= 2,
       "speech-start cue ends at a fade edge")
expect(abs(Int(thinking.samples.first ?? 1)) <= 2,
       "thinking pulse starts at a fade edge")
expect(abs(Int(thinking.samples.last ?? 1)) <= 2,
       "thinking pulse ends at a fade edge")

// Different cue generators must not collapse to one generic tone.
expect(flute.samples != droplet.samples, "flute and droplet shapes differ")
expect(opening.samples != flute.samples, "opening and loop shapes differ")
expect(droplet.samples.count < flute.samples.count, "droplet is shorter than loop")
expect(speechStart.samples != thinking.samples,
       "speech-start and thinking cue shapes differ")
expect(speechStart.duration < thinking.duration,
       "speech-start cue is shorter than thinking pulse")

// RIFF/WAVE header and PCM metadata are canonical and internally consistent.
let wav = flute.wavData
expect(wav.count == 44 + flute.samples.count * 2, "WAV has the expected PCM payload size")
expect(ascii(wav, 0..<4) == "RIFF", "WAV starts with RIFF")
expect(ascii(wav, 8..<12) == "WAVE", "WAV identifies WAVE format")
expect(ascii(wav, 12..<16) == "fmt ", "WAV includes fmt chunk")
expect(readUInt32LE(wav, 4) == UInt32(wav.count - 8), "RIFF size matches file length")
expect(readUInt32LE(wav, 16) == 16, "PCM fmt chunk size is 16")
expect(readUInt16LE(wav, 20) == 1, "WAV uses PCM encoding")
expect(readUInt16LE(wav, 22) == 1, "WAV is mono")
expect(readUInt32LE(wav, 24) == 8_000, "WAV sample rate is preserved")
expect(readUInt16LE(wav, 34) == 16, "WAV uses 16-bit samples")
expect(ascii(wav, 36..<40) == "data", "WAV includes data chunk")
expect(readUInt32LE(wav, 40) == UInt32(flute.samples.count * 2), "WAV data size matches samples")

// Empty input remains a valid, decodable zero-frame PCM container.
let emptyWav = AdamSoundscapeWaveform.wavData(for: [], sampleRate: 16_000)
expect(emptyWav.count == 44, "empty WAV still has a complete header")
expect(ascii(emptyWav, 0..<4) == "RIFF" && ascii(emptyWav, 8..<12) == "WAVE",
       "empty WAV keeps RIFF/WAVE markers")

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
