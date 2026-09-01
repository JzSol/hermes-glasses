// Standalone tests for AdamSpeechSignal. Build with:
//   xcrun swiftc HermesGlasses/Services/AdamSpeechSignal.swift \
//     tests/adam-signal/main.swift -o /tmp/adam-signal-tests && /tmp/adam-signal-tests

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

let defaults = AdamSpeechSignal.Configuration.default

// Gain and noise floor are bounded and sign preserving.
let quiet = AdamSpeechSignal.processSample(0.001, configuration: defaults)
let speech = AdamSpeechSignal.processSample(0.05, configuration: defaults)
let negativeSpeech = AdamSpeechSignal.processSample(-0.05, configuration: defaults)
let peak = AdamSpeechSignal.processSample(1, configuration: defaults)
expect(quiet == 0, "samples below the noise floor become silence")
expect(speech > 0.05, "quiet speech receives bounded gain")
expect(negativeSpeech < -0.05, "gain preserves negative sample polarity")
expect(abs(peak) <= defaults.limiterCeiling, "limiter never exceeds its ceiling")
expect(AdamSpeechSignal.processSample(.nan, configuration: defaults) == 0,
       "non-finite samples become silence")

// Both source sample formats use the same conditioning behavior.
var floatSamples: [Float] = [0.001, 0.05, -0.05, 0.9]
AdamSpeechSignal.processFloatSamples(&floatSamples, configuration: defaults)
expect(floatSamples[0] == 0, "Float32 conditioning applies the noise floor")
expect(floatSamples[1] > 0.05, "Float32 conditioning boosts speech")
expect(floatSamples[2] < -0.05, "Float32 conditioning preserves polarity")
expect(floatSamples.allSatisfy { abs($0) <= defaults.limiterCeiling },
       "Float32 conditioning limits every sample")

var int16Samples: [Int16] = [32, 2_000, -2_000, 30_000]
AdamSpeechSignal.processInt16Samples(&int16Samples, configuration: defaults)
expect(int16Samples[0] == 0, "Int16 conditioning applies the noise floor")
expect(int16Samples[1] > 2_000, "Int16 conditioning boosts speech")
expect(int16Samples[2] < -2_000, "Int16 conditioning preserves polarity")
expect(int16Samples.allSatisfy { abs(Int($0)) <= Int((defaults.limiterCeiling * 32767).rounded()) },
       "Int16 conditioning limits every sample")

// dBFS mapping makes low normal speech visible while true silence remains 0.
expect(AdamSpeechSignal.rms([]) == 0, "empty RMS is silent")
expect(abs(AdamSpeechSignal.rms([0.1, -0.1]) - 0.1) < 0.0001,
       "RMS computes normalized amplitude")
expect(AdamSpeechSignal.meterLevel(rms: 0) == 0,
       "digital silence maps to zero")
expect(AdamSpeechSignal.meterLevel(rms: 0.001) == 0,
       "very low noise maps to zero")
let lowSpeechMeter = AdamSpeechSignal.meterLevel(rms: 0.01)
expect(lowSpeechMeter > 0.1, "low normal speech visibly moves the meter")
expect(AdamSpeechSignal.meterLevel(rms: 1) == 1,
       "full scale reaches the meter ceiling")

let smoothedSpeech = AdamSpeechSignal.smoothedMeterLevel(previous: 0, rms: 0.01)
expect(smoothedSpeech > 0, "smoothed meter attacks above zero for speech")
expect(AdamSpeechSignal.smoothedMeterLevel(previous: smoothedSpeech, rms: 0) == 0,
       "smoothed meter clears immediately on silence")
expect(
    AdamSpeechSignal.smoothedMeterLevel(previous: 0.8, rms: 0.01) < 0.8,
    "smoothed meter releases toward a quieter signal"
)

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
