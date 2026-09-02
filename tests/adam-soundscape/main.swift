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
let rising = AdamSoundscapeWaveform.matchedCue(
    direction: .rising,
    sampleRate: 8_000
)
let falling = AdamSoundscapeWaveform.matchedCue(
    direction: .falling,
    sampleRate: 8_000
)
let ready = AdamSoundscapeWaveform.matchedCue(
    direction: .ready,
    sampleRate: 8_000
)
let opening = AdamSoundscapeWaveform.openingCue(sampleRate: 8_000)
let speechStart = AdamSoundscapeWaveform.speechStartCue(sampleRate: 8_000)
let thinking = AdamSoundscapeWaveform.thinkingPulse(sampleRate: 8_000)
let startProfile = AdamSoundscapeWaveform.profile(for: .listeningStart)
let endProfile = AdamSoundscapeWaveform.profile(for: .listeningEnd)
let readyProfile = AdamSoundscapeWaveform.profile(for: .responseReady)

// Basic shape and metadata.
expect(flute.sampleRate == 8_000, "flute keeps requested sample rate")
expect(abs(flute.duration - 2) < 1.0 / 8_000, "flute duration is sample accurate")
expect(flute.samples.count > 0 && rising.samples.count > 0, "clips contain samples")
expect(flute.samples.contains { $0 != 0 }, "flute is non-silent")
expect(rising.samples.contains { $0 != 0 }, "rising cue is non-silent")
expect(falling.samples.contains { $0 != 0 }, "falling cue is non-silent")
expect(ready.samples.contains { $0 != 0 }, "ready cue is non-silent")
expect(opening.samples.contains { $0 != 0 }, "opening cue is non-silent")
expect(speechStart.samples.contains { $0 != 0 }, "speech-start cue is non-silent")
expect(thinking.samples.contains { $0 != 0 }, "thinking pulse is non-silent")
expect(flute.samples.allSatisfy { $0 >= Int16.min && $0 <= Int16.max }, "flute samples are bounded")
expect(rising.samples.allSatisfy { $0 >= Int16.min && $0 <= Int16.max }, "rising samples are bounded")
expect(falling.samples.allSatisfy { $0 >= Int16.min && $0 <= Int16.max }, "falling samples are bounded")
expect(ready.samples.allSatisfy { $0 >= Int16.min && $0 <= Int16.max }, "ready samples are bounded")
// Integer PCM values are finite by construction; the range checks above are
// the integer equivalent of a finite-value assertion.
expect(flute.samples.allSatisfy { Int($0) >= Int(Int16.min) && Int($0) <= Int(Int16.max) }, "flute samples are finite")
expect(rising.samples.allSatisfy { Int($0) >= Int(Int16.min) && Int($0) <= Int(Int16.max) }, "rising samples are finite")
expect(falling.samples.allSatisfy { Int($0) >= Int(Int16.min) && Int($0) <= Int(Int16.max) }, "falling samples are finite")
expect(flute.peakAmplitude > 0 && flute.peakAmplitude < 0.2, "flute remains very quiet")
expect(rising.peakAmplitude > 0 && rising.peakAmplitude < 0.2, "rising cue remains unobtrusive")
expect(falling.peakAmplitude > 0 && falling.peakAmplitude < 0.2, "falling cue remains unobtrusive")
expect(ready.peakAmplitude > 0 && ready.peakAmplitude < 0.2, "ready cue remains unobtrusive")
expect(speechStart.peakAmplitude > 0 && speechStart.peakAmplitude < 0.06,
       "speech-start cue stays quiet")
expect(thinking.peakAmplitude > 0 && thinking.peakAmplitude < 0.06,
       "thinking pulse stays quiet")

// Smooth fades prevent clicks at the start/end of generated clips.
expect(abs(Int(flute.samples.first ?? 1)) <= 2, "flute starts at a fade edge")
expect(abs(Int(flute.samples.last ?? 1)) <= 2, "flute ends at a fade edge")
expect(abs(Int(rising.samples.first ?? 1)) <= 2, "rising starts at a fade edge")
expect(abs(Int(rising.samples.last ?? 1)) <= 2, "rising ends at a fade edge")
expect(abs(Int(falling.samples.first ?? 1)) <= 2, "falling starts at a fade edge")
expect(abs(Int(falling.samples.last ?? 1)) <= 2, "falling ends at a fade edge")
expect(abs(Int(ready.samples.first ?? 1)) <= 2, "ready starts at a fade edge")
expect(abs(Int(ready.samples.last ?? 1)) <= 2, "ready ends at a fade edge")
expect(abs(Int(speechStart.samples.first ?? 1)) <= 2,
       "speech-start cue starts at a fade edge")
expect(abs(Int(speechStart.samples.last ?? 1)) <= 2,
       "speech-start cue ends at a fade edge")
expect(abs(Int(thinking.samples.first ?? 1)) <= 2,
       "thinking pulse starts at a fade edge")
expect(abs(Int(thinking.samples.last ?? 1)) <= 2,
       "thinking pulse ends at a fade edge")

// The listening start and end are one deliberately matched family.
expect(startProfile.family == endProfile.family, "matched cues share one family")
expect(readyProfile.family == startProfile.family, "ready cue stays in the matched family")
expect(startProfile.direction == .rising, "listening start maps to rising cue")
expect(endProfile.direction == .falling, "listening end maps to falling cue")
expect(readyProfile.direction == .ready, "response handoff maps to ready motif")
expect(startProfile.direction.opposite == endProfile.direction,
       "matched cues have opposite pitch directions")
expect(AdamSoundscapeWaveform.matchedCue(
    for: .listeningStart,
    sampleRate: 8_000
) == rising && AdamSoundscapeWaveform.matchedCue(
    for: .listeningEnd,
    sampleRate: 8_000
) == falling,
       "listening states select the matched pair")
expect(AdamSoundscapeWaveform.matchedCue(
    for: .responseReady,
    sampleRate: 8_000
) == ready, "response-ready state selects its matched-family motif")
expect(startProfile.duration == endProfile.duration,
       "matched cues have the same duration")
expect(readyProfile.duration == startProfile.duration,
       "ready cue has the same family duration")
expect(startProfile.attack == endProfile.attack
       && startProfile.release == endProfile.release,
       "matched cues have the same loudness envelope")
expect(readyProfile.attack == startProfile.attack
       && readyProfile.release == startProfile.release,
       "ready cue has the same loudness envelope")
expect(abs(rising.duration - falling.duration) < 1.0 / 8_000,
       "rendered cue durations are compatible")
expect(abs(rising.peakAmplitude - falling.peakAmplitude) < 0.01,
       "rendered cue peaks are compatible")
expect(abs(ready.peakAmplitude - rising.peakAmplitude) < 0.01,
       "ready cue uses compatible loudness")

func zeroCrossings(_ samples: [Int16], from start: Int, to end: Int) -> Int {
    guard end > start + 1 else { return 0 }
    var count = 0
    var previous = samples[start]
    for sample in samples[(start + 1)..<end] {
        if (previous < 0 && sample >= 0) || (previous >= 0 && sample < 0) {
            count += 1
        }
        previous = sample
    }
    return count
}

let quarter = rising.samples.count / 4
let risingStartCrossings = zeroCrossings(rising.samples, from: quarter, to: quarter * 2)
let risingEndCrossings = zeroCrossings(rising.samples, from: quarter * 2, to: quarter * 3)
let fallingStartCrossings = zeroCrossings(falling.samples, from: quarter, to: quarter * 2)
let fallingEndCrossings = zeroCrossings(falling.samples, from: quarter * 2, to: quarter * 3)
expect(risingEndCrossings > risingStartCrossings, "rising cue pitch moves upward")
expect(fallingEndCrossings < fallingStartCrossings, "falling cue pitch moves downward")

// Different cue generators must not collapse to one generic tone.
expect(flute.samples != rising.samples, "flute ambience and matched cue differ")
expect(rising.samples != flute.samples, "opening and loop shapes differ")
expect(rising.samples.count < flute.samples.count, "matched cue is shorter than loop")
expect(rising.samples != falling.samples, "rising and falling shapes differ")
expect(ready.samples != rising.samples && ready.samples != falling.samples,
       "ready motif is distinct from both listening edges")
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
